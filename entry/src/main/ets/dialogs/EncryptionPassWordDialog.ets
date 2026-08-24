@Preview
@CustomDialog
@Component
export struct EncryptionPassWordDialog {
  title: Resource = $r('app.string.dialog_backup_password');
  showConfirmPassword: boolean = false;
  private textValue: string = '';
  private confirmTextValue: string = '';
  private inputValue: string = '';
  @State private passwordMismatch: boolean = false;
  @State private passwordEmpty: boolean = false;
  controller?: CustomDialogController;
  cancel: () => void = () => {
  };
  confirm: (text: string) => void = (text: string) => {
  };

  private resetInput(): void {
    this.textValue = '';
    this.confirmTextValue = '';
    this.passwordMismatch = false;
    this.passwordEmpty = false;
  }

  build() {
    Column() {
      // 标题：对齐系统 AlertDialog 标题（ohos_id_text_size_dialog_tittle / Bold / 主文本色 / 居中）
      Text(this.title)
        .fontSize($r('sys.float.ohos_id_text_size_dialog_tittle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width('100%')
        .padding({ left: 24, right: 24, top: 24 })

      TextInput({ placeholder: $r('app.string.dialog_backup_password_placeholder'), text: this.textValue })
        .height(40)
        .margin({ left: 24, right: 24, top: 16 })
        .maxLength(32)
        .type(InputType.Password)
        .showPasswordIcon(true)
        .onChange((value: string) => {
          this.textValue = value
          this.passwordMismatch = false
          this.passwordEmpty = false
        })

      if (this.showConfirmPassword) {
        TextInput({
          placeholder: $r('app.string.dialog_backup_password_confirm_placeholder'),
          text: this.confirmTextValue
        })
          .height(40)
          .margin({ left: 24, right: 24, top: 12 })
          .maxLength(32)
          .type(InputType.Password)
          .showPasswordIcon(true)
          .showError(this.passwordEmpty ? $r('app.string.dialog_backup_password_empty') :
            this.passwordMismatch ? $r('app.string.dialog_backup_password_mismatch') : undefined)
          .onChange((value: string) => {
            this.confirmTextValue = value
            this.passwordMismatch = false
            this.passwordEmpty = false
          })
      }

      // 按钮区：对齐系统 AlertDialog（40vp 胶囊文本按钮 + 竖分隔线，行内边距 16/8/16）
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
            if (this.controller != undefined) {
              this.cancel()
              this.resetInput()
              this.controller.close()
            }
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
            if (this.controller != undefined) {
              if (this.showConfirmPassword && this.textValue.length === 0) {
                this.passwordEmpty = true
                return
              }
              if (this.showConfirmPassword && this.textValue !== this.confirmTextValue) {
                this.passwordMismatch = true
                return
              }
              this.inputValue = this.textValue
              this.resetInput()
              this.confirm(this.inputValue)
              this.controller.close()
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    }
  }
}
