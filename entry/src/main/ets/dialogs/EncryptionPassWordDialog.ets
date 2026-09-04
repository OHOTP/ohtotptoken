import { CustomContentDialogV2 } from '@kit.ArkUI';

@Preview
@ComponentV2
export struct EncryptionPassWordDialog {
  @Param title: ResourceStr = $r('app.string.dialog_backup_password');
  @Param showConfirmPassword: boolean = false;
  @Event cancel: () => void = () => {};
  @Event confirm: (text: string) => void = () => {};

  @Local private textValue: string = '';
  @Local private confirmTextValue: string = '';
  @Local private passwordMismatch: boolean = false;
  @Local private passwordEmpty: boolean = false;

  private resetInput(): void {
    this.textValue = '';
    this.confirmTextValue = '';
    this.passwordMismatch = false;
    this.passwordEmpty = false;
  }

  private close(): void {
    this.getDialogController()?.close();
  }

  @Builder
  contentBuilder(): void {
    Column() {
      TextInput({ placeholder: $r('app.string.dialog_backup_password_placeholder'), text: this.textValue })
        .height(40)
        .maxLength(32)
        .type(InputType.Password)
        .showPasswordIcon(true)
        .onChange((value: string) => {
          this.textValue = value;
          this.passwordMismatch = false;
          this.passwordEmpty = false;
        })

      if (this.showConfirmPassword) {
        TextInput({
          placeholder: $r('app.string.dialog_backup_password_confirm_placeholder'),
          text: this.confirmTextValue
        })
          .height(40)
          .margin({ top: 12 })
          .maxLength(32)
          .type(InputType.Password)
          .showPasswordIcon(true)
          .showError(this.passwordEmpty ? $r('app.string.dialog_backup_password_empty') :
            this.passwordMismatch ? $r('app.string.dialog_backup_password_mismatch') : undefined)
          .onChange((value: string) => {
            this.confirmTextValue = value;
            this.passwordMismatch = false;
            this.passwordEmpty = false;
          })
      }

      // 保留自定义按钮，确保校验失败时弹窗不会被系统按钮自动关闭。
      Row() {
        Button($r('app.string.setting_backup_cancel'))
          .type(ButtonType.ROUNDED_RECTANGLE)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .height($r('sys.float.ohos_id_button_height'))
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.font_emphasize'))
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Medium)
          .onClick(() => {
            this.cancel();
            this.resetInput();
            this.close();
          })
        Divider()
          .vertical(true)
          .height(24)
          .strokeWidth(2)
          .color($r('sys.color.ohos_id_color_list_separator'))
          .margin({ left: 3, right: 3 })
        Button($r('app.string.setting_backup_confirm'))
          .type(ButtonType.ROUNDED_RECTANGLE)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .height($r('sys.float.ohos_id_button_height'))
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.font_emphasize'))
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Medium)
          .onClick(() => {
            if (this.showConfirmPassword && this.textValue.length === 0) {
              this.passwordEmpty = true;
              return;
            }
            if (this.showConfirmPassword && this.textValue !== this.confirmTextValue) {
              this.passwordMismatch = true;
              return;
            }
            const password = this.textValue;
            this.resetInput();
            this.confirm(password);
            this.close();
          })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .width('100%')
  }

  build() {
    CustomContentDialogV2({
      primaryTitle: this.title,
      contentBuilder: () => {
        this.contentBuilder();
      }
    })
  }
}
