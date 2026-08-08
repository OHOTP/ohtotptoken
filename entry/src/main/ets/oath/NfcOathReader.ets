import { bundleManager, common } from '@kit.AbilityKit';
import { nfcController, tag } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { OathError, OathReadResult, OathSession } from './OathApplet';
import { NfcTagTransport } from './TagTransport';
import { Logger } from 'common';

let logger = Logger;

/**
 * 前台读卡编排选项：弹窗（NFCReadDialog）提供回调与当前密码。
 */
export interface NfcReadOptions {
  /** 弹窗提供当前密码（可为空串） */
  getPassword: () => string;
  /** 已锁定但未填密码：弹窗震动+红框+改文案，保持打开 */
  onPasswordRequired: () => void;
  /** VALIDATE 失败（密码错误）：弹窗震动+红框+改文案，保持打开 */
  onAuthFailed: () => void;
  /** 其他失败（非 OATH 卡片/传输中断/无令牌等）：弹窗提示，保持打开 */
  onReadFailed: (err: OathError) => void;
  /** 读取成功：弹窗由父级关闭 */
  onSuccess: (result: OathReadResult) => void;
}

/**
 * NFC 能力检查结果。
 */
export enum NfcSupportStatus {
  /** 能力可用 */
  OK,
  /** 系统能力不支持（真·不支持） */
  UNSUPPORTED,
  /** 硬件不可用 */
  HARDWARE_MISSING,
  /** NFC 开关未打开（可恢复） */
  SWITCH_OFF
}

/**
 * NFC 前台读卡编排（单例）：
 * readerMode 注册/注销、tag 发现、IsoDep 连接、OathSession 全流程（SELECT → 按需 VALIDATE → CALCULATE ALL）。
 */
export class NfcOathReader {
  private static instance: NfcOathReader;
  private opts: NfcReadOptions | null = null;
  private registered: boolean = false;
  /** 处理中标志，防止卡片连续触发发现回调导致重入 */
  private processing: boolean = false;
  private elementName: bundleManager.ElementName | null = null;
  private readerModeCb: (err: BusinessError, tagInfo: tag.TagInfo) => void = () => {};

  private constructor() {
  }

  public static getInstance(): NfcOathReader {
    if (!NfcOathReader.instance) {
      NfcOathReader.instance = new NfcOathReader();
    }
    return NfcOathReader.instance;
  }

  /**
   * NFC 能力检查：系统能力（SystemCapability.Communication.NFC.Tag）+ 硬件可用 + NFC 开关打开。
   * 返回具体失败原因，便于调用方区分提示文案。
   */
  public isNfcSupported(): NfcSupportStatus {
    if (!canIUse('SystemCapability.Communication.NFC.Tag')) {
      logger.warn('NFC Tag syscap not supported');
      return NfcSupportStatus.UNSUPPORTED;
    }
    try {
      if (!nfcController.isNfcAvailable()) {
        logger.warn('NFC not available');
        return NfcSupportStatus.HARDWARE_MISSING;
      }
      if (!nfcController.isNfcOpen()) {
        logger.warn('NFC not open');
        return NfcSupportStatus.SWITCH_OFF;
      }
    } catch (e) {
      logger.error(`nfc check error: ${(e as BusinessError).message}`);
      return NfcSupportStatus.UNSUPPORTED;
    }
    return NfcSupportStatus.OK;
  }

  /**
   * 开始前台读卡监听（ISO_DEP + NFC_A）。
   * NFC 能力不满足时直接回调 onReadFailed。
   */
  public startRead(opts: NfcReadOptions): void {
    this.opts = opts;
    if (this.isNfcSupported() !== NfcSupportStatus.OK) {
      opts.onReadFailed(new OathError('TRANSPORT', 'NFC is not supported or not open'));
      return;
    }
    if (this.registered) {
      return;
    }
    const appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    const elementName: bundleManager.ElementName = {
      bundleName: appCtx.abilityInfo.bundleName,
      moduleName: appCtx.abilityInfo.moduleName,
      abilityName: appCtx.abilityInfo.name
    };
    this.elementName = elementName;
    this.readerModeCb = (err: BusinessError, tagInfo: tag.TagInfo): void => {
      this.onTagDiscovered(err, tagInfo);
    };
    try {
      tag.on('readerMode', elementName, [tag.ISO_DEP, tag.NFC_A], this.readerModeCb);
      this.registered = true;
      logger.info('readerMode registered');
    } catch (e) {
      logger.error(`tag.on readerMode failed: ${(e as BusinessError).message}`);
      opts.onReadFailed(new OathError('TRANSPORT', `readerMode register failed: ${(e as BusinessError).message}`));
    }
  }

  /** 停止前台读卡监听（弹窗关闭时调用） */
  public stopRead(): void {
    if (this.registered && this.elementName !== null) {
      try {
        tag.off('readerMode', this.elementName, this.readerModeCb);
      } catch (e) {
        logger.error(`tag.off readerMode failed: ${(e as BusinessError).message}`);
      }
      this.registered = false;
      logger.info('readerMode unregistered');
    }
    this.opts = null;
  }

  private async onTagDiscovered(err: BusinessError, tagInfo: tag.TagInfo): Promise<void> {
    if (err) {
      logger.error(`readerMode error: ${err.message}`);
      this.dispatchReadFailed(new OathError('TRANSPORT', `readerMode error: ${err.message}`));
      return;
    }
    if (this.processing || tagInfo === null || tagInfo === undefined) {
      return;
    }
    this.processing = true;
    let session: OathSession | null = null;
    try {
      const isoDep = this.findIsoDep(tagInfo);
      if (isoDep === null) {
        this.dispatchReadFailed(new OathError('TRANSPORT', 'tag does not support IsoDep'));
        return;
      }
      const transport = new NfcTagTransport(isoDep);
      await transport.connect();
      if (!transport.isConnected()) {
        throw new OathError('TRANSPORT', 'IsoDep connect failed');
      }
      session = new OathSession(transport);
      await session.select();
      // 已锁定：密码为空 → 提示输入密码并中止；非空 → VALIDATE，失败 → 提示密码错误并中止
      if (session.locked) {
        const password = this.opts?.getPassword() ?? '';
        if (password === '') {
          this.opts?.onPasswordRequired();
          return;
        }
        try {
          await session.validate(password);
        } catch (e) {
          if (e instanceof OathError && e.kind === 'WRONG_PASSWORD') {
            this.opts?.onAuthFailed();
            return;
          }
          throw this.toOathError(e);
        }
      }
      const timestamp = Math.floor(Date.now() / 1000);
      const credentials = await session.calculateAll(timestamp);
      if (credentials.length === 0) {
        this.dispatchReadFailed(new OathError('NO_TOKENS', 'no available tokens on this card'));
        return;
      }
      const result: OathReadResult = { credentials: credentials, timestamp: timestamp };
      logger.info(`read success credentials=${credentials.length}`);
      this.opts?.onSuccess(result);
    } catch (e) {
      this.dispatchReadFailed(this.toOathError(e));
    } finally {
      if (session !== null) {
        try {
          await session.close();
        } catch (e) {
          // 忽略关闭异常
        }
      }
      this.processing = false;
    }
  }

  private findIsoDep(tagInfo: tag.TagInfo): tag.IsoDepTag | null {
    for (const tech of tagInfo.technology) {
      if (tech === tag.ISO_DEP) {
        return tag.getIsoDep(tagInfo);
      }
    }
    return null;
  }

  private dispatchReadFailed(err: OathError): void {
    logger.error(`read failed kind=${err.kind} sw=${err.sw !== undefined ? err.sw.toString(16) : 'none'} msg=${err.message}`);
    this.opts?.onReadFailed(err);
  }

  private toOathError(e: Object): OathError {
    if (e instanceof OathError) {
      return e;
    }
    const err = e as BusinessError;
    return new OathError('TRANSPORT', err?.message ?? 'unknown transport error');
  }
}
