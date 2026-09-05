import { TokenGroup, TokenGroupState, TokenGroupStore, TokenStore, dialogSystemMaterial,
  showSnackBar, SnackBarNotifyType } from 'common';
import { HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { MaterialTheme } from '../components/MaterialTheme';
import { TokenGroupNameDialog } from '../dialogs/TokenGroupNameDialog';

@ComponentV2
export struct TokenGroupPage {
  @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onExitFullScreen: () => void = () => {};
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Local busy: boolean = false;
  private scroller: Scroller = new Scroller();

  private async run(action: () => Promise<void>): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await action();
    } catch (_) {
      showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR);
    } finally {
      this.busy = false;
    }
  }

  @LocalBuilder
  NameDialogBuilder(groupId: string, name: string) {
    TokenGroupNameDialog({ groupId: groupId, initialName: name })
  }

  private openNameDialog(groupId: string = '', name: string = ''): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => this.NameDialogBuilder(groupId, name),
      autoCancel: false,
      alignment: DialogAlignment.Center
    }).catch(() => {
      showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR);
    });
  }

  private deleteGroup(group: TokenGroup): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.token_group_delete'),
      subtitle: group.name,
      message: $r('app.string.token_group_delete_message'),
      primaryButton: {
        value: $r('app.string.dialog_btn_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.dialog_btn_delete'),
        fontColor: Color.Red,
        action: () => {
          this.run(async () => {
            await TokenStore.getInstance().deleteGroup(group.id);
          });
        }
      }
    });
  }

  @Builder
  GroupMenu(group: TokenGroup, index: number) {
    Menu() {
      MenuItem({ content: $r('app.string.token_group_rename') })
        .onClick(() => this.openNameDialog(group.id, group.name))
      MenuItem({ content: $r('app.string.token_group_up') })
        .enabled(index > 0)
        .onClick(() => this.run(() => TokenGroupStore.getInstance().move(group.id, -1)))
      MenuItem({ content: $r('app.string.token_group_down') })
        .enabled(index < this.state.groups.length - 1)
        .onClick(() => this.run(() => TokenGroupStore.getInstance().move(group.id, 1)))
      MenuItem({ content: $r('app.string.token_group_delete') })
        .contentFontColor(Color.Red)
        .onClick(() => this.deleteGroup(group))
    }
    .systemMaterial(dialogSystemMaterial())
  }

  build() {
    HdsNavDestination() {
      List({ space: 16, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 12 }) {
            Button($r('app.string.token_group_new'))
              .constraintSize({ minHeight: 48 })
              .width('100%')
              .enabled(!this.busy)
              .onClick(() => this.openNameDialog())
            Text($r('app.string.token_group_hint'))
              .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          }
          .padding(16)
        }
        ForEach(this.state.groups, (group: TokenGroup, index: number) => {
          ListItem() {
            Row({ space: 12 }) {
              Text(group.name)
                .fontSize(16).fontColor($r('sys.color.font_primary'))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Button({ type: ButtonType.Circle }) {
                SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
                  .fontSize(22).fontColor([$r('sys.color.icon_primary')])
              }
              .width(44).height(44)
              .backgroundColor(Color.Transparent)
              .accessibilityText(group.name)
              .enabled(!this.busy)
              .bindMenu((): void => this.GroupMenu(group, index))
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
        }, (group: TokenGroup) => group.id)
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Off)
      .contentEndOffset(32)
    }
    .backgroundColor($r('app.color.window_background'))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      enableComponentSafeArea: true,
      avoidLayoutSafeArea: true,
      content: { title: { mainTitle: $r('app.string.token_group_manage') } },
      style: {
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    .bindToScrollable([this.scroller])
    .onWillDisappear(() => this.onExitFullScreen())
  }
}
