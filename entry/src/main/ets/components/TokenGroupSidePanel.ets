import { HdsNavigation, HdsNavigationTitleMode, hdsMaterial } from '@kit.UIDesignKit';
import { MaterialTheme } from './MaterialTheme';
import { ALL_TOKEN_GROUPS, FAVORITE_TOKEN_GROUP, TokenConfig, otpType, TokenGroup, TokenGroupState,
  TokenGroupStore, TokenStore, dialogSystemMaterial, showSnackBar, SnackBarNotifyType } from 'common';
import { TokenGroupNameDialog } from '../dialogs/TokenGroupNameDialog';

/** 分类和分组共用一个滚动区；新建入口始终可达。 */
@ComponentV2
export struct TokenGroupSidePanel {
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Param tokens: TokenConfig[] = [];
  @Local editing: boolean = false;
  @Local busy: boolean = false;
  @Event onSelect: (id: string) => void = () => {};
  @Event onAdd: () => void = () => {};
  @Event onClose: () => void = () => {};
  private scroller: Scroller = new Scroller();

  private count(id: string): number {
    if (id === ALL_TOKEN_GROUPS) {
      return this.tokens.length;
    }
    return this.tokens.filter(token => {
      if (id === FAVORITE_TOKEN_GROUP) {
        return token.TokenType !== otpType.NFC_external && token.TokenFavorite === true;
      }
      const groupId = token.TokenType === otpType.NFC_external ? '' : (token.TokenGroupId ?? '');
      const knownId = this.state.groups.some(group => group.id === groupId) ? groupId : '';
      return knownId === id;
    }).length;
  }

  @LocalBuilder
  NameDialogBuilder(group: TokenGroup) {
    TokenGroupNameDialog({ groupId: group.id, initialName: group.name })
  }

  private rename(group: TokenGroup): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => this.NameDialogBuilder(group),
      autoCancel: false,
      alignment: DialogAlignment.Center
    }).catch(() => showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR));
  }

  private deleteGroup(group: TokenGroup): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.token_group_delete'),
      subtitle: group.name,
      message: $r('app.string.token_group_delete_message'),
      primaryButton: { value: $r('app.string.dialog_btn_cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.dialog_btn_delete'),
        fontColor: Color.Red,
        action: async () => {
          if (this.busy) {
            return;
          }
          this.busy = true;
          try {
            await TokenStore.getInstance().deleteGroup(group.id);
          } catch (_) {
            showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR);
          } finally {
            this.busy = false;
          }
        }
      }
    });
  }

  @Builder
  GroupMenu(group: TokenGroup) {
    Menu() {
      MenuItem({ content: $r('app.string.token_group_rename') })
        .onClick(() => this.rename(group))
      MenuItem({ content: $r('app.string.token_group_delete') })
        .contentFontColor(Color.Red)
        .onClick(() => this.deleteGroup(group))
    }
    .systemMaterial(dialogSystemMaterial())
  }

  @LocalBuilder
  ItemContent(id: string, label: ResourceStr, icon: Resource, isGroup: boolean) {
    Row({ space: 16 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([isGroup ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_secondary')])
      Text(label)
        .fontSize(18)
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(this.state.selectedId === id ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.count(id).toString())
        .fontSize(16)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .flexShrink(0)
    }
    .width('100%')
    .constraintSize({ minHeight: 60 })
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
  }

  @LocalBuilder
  FixedItem(id: string, label: ResourceStr, icon: Resource) {
    Button({ type: ButtonType.Normal }) {
      this.ItemContent(id, label, icon, false)
    }
    .width('100%')
    .borderRadius(20)
    .backgroundColor(this.state.selectedId === id ? $r('sys.color.comp_emphasize_secondary') : Color.Transparent)
    .accessibilitySelected(this.state.selectedId === id)
    .onClick(() => this.onSelect(id))
  }

  @LocalBuilder
  GroupListBuilder() {
    Column() {
      List({ scroller: this.scroller }) {
        ListItem() {
          this.FixedItem(ALL_TOKEN_GROUPS, $r('app.string.token_group_all'), $r('sys.symbol.doc_text'))
        }
        ListItem() {
          this.FixedItem(FAVORITE_TOKEN_GROUP, $r('app.string.token_group_favorites'), $r('sys.symbol.star'))
        }
        ListItem() {
          this.FixedItem('', $r('app.string.token_group_ungrouped'), $r('sys.symbol.folder'))
        }
        ListItem() {
          Row() {
            Text($r('app.string.token_group_label'))
              .fontSize(16)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Button(this.editing ? $r('app.string.token_group_done') : $r('app.string.token_group_edit'))
              .id('token_group_edit')
              .fontSize(16)
              .fontColor($r('sys.color.font_emphasize'))
              .backgroundColor(Color.Transparent)
              .constraintSize({ minWidth: 48, minHeight: 48 })
              .padding({ left: 8, right: 0 })
              .enabled(this.state.groups.length > 0 && !this.busy)
              .onClick(() => this.editing = !this.editing)
          }
          .height(64)
          .padding({ left: 12, right: 12, top: 16 })
        }
        ForEach(this.state.groups, (group: TokenGroup) => {
          ListItem() {
            Row() {
              Button({ type: ButtonType.Normal }) {
                this.ItemContent(group.id, group.name, $r('sys.symbol.folder'), true)
              }
              .layoutWeight(1)
              .backgroundColor(Color.Transparent)
              .enabled(!this.busy)
              .accessibilitySelected(this.state.selectedId === group.id)
              .onClick(() => this.editing ? this.rename(group) : this.onSelect(group.id))
              .bindContextMenu(() => this.GroupMenu(group), ResponseType.LongPress)
              if (this.editing) {
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
                    .fontSize(22)
                    .fontColor([$r('sys.color.icon_secondary')])
                }
                .width(48).height(48)
                .backgroundColor(Color.Transparent)
                .accessibilityText($r('app.string.token_group_manage'))
                .enabled(!this.busy)
                .bindMenu((): void => this.GroupMenu(group))
              }
            }
            .width('100%')
            .borderRadius(20)
            .clip(true)
            .backgroundColor(this.state.selectedId === group.id ?
              $r('sys.color.comp_emphasize_secondary') : Color.Transparent)
          }
        }, (group: TokenGroup) => group.id)
      }
      .id('token_group_sidebar_list')
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .contentEndOffset(8)
      Button({ type: ButtonType.Normal }) {
        Text($r('app.string.token_group_new'))
          .fontSize(18)
          .fontColor($r('sys.color.font_emphasize'))
          .width('100%')
      }
      .id('token_group_new')
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding(12)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.onAdd())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 8, top: 12 })
  }

  build() {
    HdsNavigation() {
      this.GroupListBuilder()
    }
    .width('100%')
    .height('100%')
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .backgroundColor(Color.Transparent)
    .titleBar({
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary'),
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            }
          }
        },
        scrollEffectOpts: { enableScrollEffect: false },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: MaterialTheme.hdsMaterialLevel()
        }
      },
      content: {
        backIcon: {
          icon: $r('sys.symbol.open_sidebar'),
          label: $r('app.string.token_group_close_sidebar'),
          componentId: 'token_group_sidebar_close',
          action: () => this.onClose()
        }
      }
    })
  }
}
