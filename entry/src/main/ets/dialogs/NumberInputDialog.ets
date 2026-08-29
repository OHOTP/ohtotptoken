@Preview
@CustomDialog
export struct NumberInputDialog {
  controller?: CustomDialogController;
  confirm: (counter: number) => void = () => {};

  @State Counter: number = 0;
  @StorageLink('background_blur_flag') backgroundBlurFlag: boolean = false;

  build() {
    Row({space: 10}) {
      Blank()
      TextInput({ placeholder: this.Counter.toString() })
        .width('70%')
        .onChange((value) => {
          this.Counter = parseInt(value) ?? 0;
        })
      Blank()
        .width('5%')
      Button($r('app.string.dialog_btn_confirm'))
        .onClick(() => {
          if (this.controller != undefined) {
            this.confirm(this.Counter)
            this.controller.close()
          }
        })
        .width('25%')
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.SpaceBetween)
    .width('100%')
    .padding({ left: 10, right: 10 })
    .foregroundBlurStyle(this.backgroundBlurFlag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}