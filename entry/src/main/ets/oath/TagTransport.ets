import { tag } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * OATH Applet 传输抽象接口（FR-014）
 *
 * 将 OATH 协议层与具体传输实现（NFC IsoDep / 未来 USB）解耦，
 * 协议层（OathApplet.ets）只依赖本接口，不直接接触 NFC API。
 *
 * transmit 返回含状态字（最后两字节，如 0x9000）的完整响应字节数组。
 */
export interface TagTransport {
  connect(): Promise<void>;
  transmit(apdu: number[]): Promise<number[]>;
  close(): Promise<void>;
  isConnected(): boolean;
}

/**
 * NFC IsoDep 传输实现：包装 tag.IsoDepTag。
 *
 * IsoDepTag 的 connect/close 为同步接口，此处包装为 Promise 以匹配 TagTransport。
 */
export class NfcTagTransport implements TagTransport {
  private isoDep: tag.IsoDepTag;

  constructor(isoDep: tag.IsoDepTag) {
    this.isoDep = isoDep;
  }

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        this.isoDep.connect();
        resolve();
      } catch (e) {
        reject(e as BusinessError);
      }
    });
  }

  transmit(apdu: number[]): Promise<number[]> {
    return this.isoDep.transmit(apdu);
  }

  close(): Promise<void> {
    return new Promise<void>((resolve) => {
      try {
        if (this.isoDep.isConnected()) {
          // API 9+ 断开连接接口为 resetConnection（close 不存在）
          this.isoDep.resetConnection();
        }
      } catch (e) {
        // 忽略关闭异常，不阻塞调用方
      }
      resolve();
    });
  }

  isConnected(): boolean {
    return this.isoDep.isConnected();
  }
}
