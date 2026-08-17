import { IconPicker } from '../components/IconPicker';

/** 兼容旧配置流程的图标选择弹窗外壳。 */
@Preview
@CustomDialog
export struct SelectIconDialog {
  @Prop @Require issuer: string = '';
  @Prop currentIconPath: string = '';
  controller?: CustomDialogController;
  cancel?: () => void;
  confirm: (new_conf: string) => void = () => {};

  build() {
    IconPicker({
      issuer: this.issuer,
      currentIconPath: this.currentIconPath,
      showCancelButton: true,
      cancel: () => {
        this.cancel?.();
        this.controller?.close();
      },
      confirm: (path: string) => {
        this.confirm(path);
        this.controller?.close();
      }
    })
  }
}