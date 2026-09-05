import { CustomContentDialogV2 } from '@kit.ArkUI';
import { TokenGroupStore } from 'common';

@ComponentV2
export struct TokenGroupNameDialog {
  @Param groupId: string = '';
  @Param initialName: string = '';
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
      this.getDialogController()?.close();
    } catch (_) {
      this.error = $r('app.string.token_group_error');
    } finally {
      this.busy = false;
    }
  }

  @Builder
  ContentBuilder() {
    Column({ space: 16 }) {
      TextInput({ text: this.name, placeholder: $r('app.string.token_group_name') })
        .maxLength(24)
        .enabled(!this.busy)
        .defaultFocus(true)
        .enterKeyType(EnterKeyType.Done)
        .accessibilityText($r('app.string.token_group_name'))
        .showError(this.error)
        .onChange((value: string) => { this.name = value; this.error = undefined; })
        .onSubmit(() => { this.save(); })
      // 使用内容区按钮：校验/保存失败时不能自动关闭 DialogV2。
      Row({ space: 8 }) {
        Button($r('app.string.dialog_btn_cancel'))
          .layoutWeight(1)
          .height(48)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.font_emphasize'))
          .enabled(!this.busy)
          .onClick(() => this.getDialogController()?.close())
        Button(this.groupId === '' ? $r('app.string.token_group_new') : $r('app.string.token_group_save'))
          .layoutWeight(1)
          .height(48)
          .enabled(!this.busy && this.name.trim().length > 0)
          .onClick(() => { this.save(); })
      }
      .width('100%')
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
