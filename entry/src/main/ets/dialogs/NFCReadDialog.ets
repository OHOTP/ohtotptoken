import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NfcOathReader } from '../oath/NfcOathReader';
import { OathError, OathReadResult } from '../oath/OathApplet';
import { Logger } from 'common';

let logger = Logger;

/**
 * NFC 读取弹窗：大号 NFC 图案 + 提示文案 + 密码输入框。
 *
 * 弹窗打开期间启动前台读卡监听（aboutToAppear → startRead），
 * 关闭时停止监听（aboutToDisappear → stopRead）。
 * 密码未填/密码错误：震动 + 红框 + 文案切换，弹窗保持打开；读取成功由父级关闭。
 */
@CustomDialog
export struct NFCReadDialog {
  controller?: CustomDialogController;
  onSuccess: (result: OathReadResult) => void = () => {};

  @State password: string = '';
  @State promptText: Resource = $r('app.string.nfc_read_prompt_default');
  @State passwordError: boolean = false;
  @StorageLink('background_blur_flag') backgroundBlurFlag: boolean = false;

  aboutToAppear(): void {
    NfcOathReader.getInstance().startRead({
      getPassword: (): string => {
        return this.password;
      },
      onPasswordRequired: (): void => {
        this.showPasswordFeedback();
      },
      onAuthFailed: (): void => {
        this.showPasswordFeedback();
      },
      onReadFailed: (err: OathError): void => {
        this.handleReadFailed(err);
      },
      onSuccess: (result: OathReadResult): void => {
        this.onSuccess(result);
      }
    });
  }

  aboutToDisappear(): void {
    NfcOathReader.getInstance().stopRead();
  }

  /** 密码未填/密码错误统一反馈：震动一次 + 红框 + 切换文案（保持弹窗打开） */
  private showPasswordFeedback(): void {
    vibrator.startVibration({ type: 'time', duration: 300 }, { usage: 'touch' })
      .catch((e: BusinessError) => {
        logger.error(`vibrate failed: ${e.message}`);
      });
    this.passwordError = true;
    this.promptText = $r('app.string.nfc_read_prompt_password');
  }

  /** 其他读取失败：提示失败文案，保持弹窗打开等待重新靠近 */
  private handleReadFailed(err: OathError): void {
    logger.error(`read failed kind=${err.kind} msg=${err.message}`);
    if (err.kind === 'NO_TOKENS') {
      this.promptText = $r('app.string.nfc_read_no_tokens');
    } else {
      this.promptText = $r('app.string.nfc_read_failed');
    }
  }

  build() {
    Column({ space: 16 }) {
      Image('rawfile://icons/token_image_nfc.svg')
        .width(160)
        .height(160)
        .objectFit(ImageFit.Contain)
      Text(this.promptText)
        .fontSize(16)
        .fontColor($r('app.color.str_main'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      TextInput({
        placeholder: $r('app.string.nfc_read_password_placeholder'),
        text: this.password
      })
        .type(InputType.Password)
        .showPasswordIcon(true)
        .height(52)
        .width('100%')
        .borderRadius(8)
        .borderWidth(this.passwordError ? 2 : 1)
        .borderColor(this.passwordError ? Color.Red : Color.Transparent)
        .onChange((value: string) => {
          this.password = value;
          // 密码输入变化时复位红框与文案为默认
          this.passwordError = false;
          this.promptText = $r('app.string.nfc_read_prompt_default');
        })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 24 })
    .borderRadius(10)
    .foregroundBlurStyle(this.backgroundBlurFlag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}
