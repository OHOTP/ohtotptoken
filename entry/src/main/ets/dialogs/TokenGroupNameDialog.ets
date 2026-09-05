import { CustomContentDialogV2 } from '@kit.ArkUI';
import { TokenGroupStore } from 'common';

@ComponentV2
export struct TokenGroupNameDialog {
  @Param groupId: string = '';
  @Param initialName: string = '';
  @Event onClose: () => void = () => {};
  @Local name: string = '';
  @Local busy: boolean = false;
  @Local error: ResourceStr | undefined = undefined;

  aboutToAppear(): void {
    this.name = this.initialName;
  }

  private async save(): Promise<void> {
    if (this.busy) {
      return;
    }
    const store = TokenGroupStore.getInstance();
    if (!store.isValidName(this.name, this.groupId)) {
      this.error = $r('app.string.token_group_invalid');
      return;
    }
    this.busy = true;
    try {
      await store.renameOrCreate(this.name, this.groupId);
      this.onClose();
    } catch (_) {
      this.error = $r('app.string.token_group_error');
    } finally {
      this.busy = false;
    }
  }

  @Builder
  ContentBuilder() {
    Column() {
      TextInput({ text: this.name, placeholder: $r('app.string.token_group_name') })
        .id('token_group_name_input')
        .height(40)
        .maxLength(24)
        .enabled(!this.busy)
        .defaultFocus(true)
        .enterKeyType(EnterKeyType.Done)
        .accessibilityText($r('app.string.token_group_name'))
        .showError(this.error)
        .onChange((value: string) => { this.name = value; this.error = undefined; })
        .onSubmit(() => { this.save(); })
      // 使用内容区按钮：校验/保存失败时不能自动关闭 DialogV2。
      Row() {
        Button($r('app.string.dialog_btn_cancel'))
          .id('token_group_name_cancel')
          .type(ButtonType.ROUNDED_RECTANGLE)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .height($r('sys.float.ohos_id_button_height'))
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.font_emphasize'))
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Medium)
          .enabled(!this.busy)
          .onClick(() => this.onClose())
        Divider()
          .vertical(true)
          .height(24)
          .strokeWidth(2)
          .color($r('sys.color.ohos_id_color_list_separator'))
          .margin({ left: 3, right: 3 })
        Button(this.groupId === '' ? $r('app.string.token_group_new') : $r('app.string.token_group_save'))
          .id('token_group_name_save')
          .type(ButtonType.ROUNDED_RECTANGLE)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .height($r('sys.float.ohos_id_button_height'))
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.font_emphasize'))
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Medium)
          .enabled(!this.busy && this.name.trim().length > 0)
          .onClick(() => { this.save(); })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .width('100%')
  }

  build() {
    CustomContentDialogV2({
      primaryTitle: this.groupId === '' ? $r('app.string.token_group_new') : $r('app.string.token_group_rename'),
      contentBuilder: () => this.ContentBuilder()
    })
  }
}
