import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { MaterialTheme } from './MaterialTheme';
import { ALL_TOKEN_GROUPS, FAVORITE_TOKEN_GROUP, TokenConfig, otpType, TokenGroup, TokenGroupState,
  TokenGroupStore, TokenStore, GenericDataSource, dialogSystemMaterial, showSnackBar, SnackBarNotifyType } from 'common';
import { TokenGroupNameDialog } from '../dialogs/TokenGroupNameDialog';

/** 分类和分组共用一个滚动区；新建入口始终可达。 */
@ComponentV2
export struct TokenGroupSidePanel {
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Param tokens: TokenConfig[] = [];
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local editing: boolean = false;
  @Local busy: boolean = false;
  @Event onSelect: (id: string) => void = () => {};
  @Event onAdd: () => void = () => {};
  private scroller: Scroller = new Scroller();
  private groupDataSource: GenericDataSource<TokenGroup> = new GenericDataSource<TokenGroup>([]);

  aboutToAppear(): void {
    this.syncGroupDataSource();
  }

  @Monitor('state.groups')
  syncGroupDataSource(): void {
    this.groupDataSource.updateData(this.state.groups);
  }

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
  NameDialogBuilder(group: TokenGroup, onClose: () => void) {
    TokenGroupNameDialog({ groupId: group.id, initialName: group.name, initialColor: group.color, onClose: onClose })
  }

  private rename(group: TokenGroup): void {
    const promptAction = this.getUIContext().getPromptAction();
    let dialogId: number | undefined = undefined;
    const onClose = (): void => {
      if (dialogId !== undefined) {
        promptAction.closeCustomDialog(dialogId);
        dialogId = undefined;
      }
    };
    promptAction.openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => this.NameDialogBuilder(group, onClose),
      autoCancel: false,
      alignment: DialogAlignment.Center
    }).then((id: number) => {
      dialogId = id;
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
  ItemContent(id: string, label: ResourceStr, icon: Resource, isGroup: boolean,
    color: ResourceColor = $r('sys.color.icon_emphasize')) {
    Row({ space: 16 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([isGroup ? color : $r('sys.color.icon_secondary')])
      Text(label)
        .fontSize(18)
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(this.state.selectedId === id ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (!isGroup || !this.editing) {
        Text(this.count(id).toString())
          .fontSize(16)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .flexShrink(0)
      }
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
        // 分组保存时替换对象；名称或颜色变化后重建行，避免复用旧显示和菜单回调。
        LazyForEach(this.groupDataSource, (group: TokenGroup) => {
          ListItem() {
            Row() {
              Button({ type: ButtonType.Normal }) {
                this.ItemContent(group.id, group.name, $r('sys.symbol.folder'), true,
                  group.color ?? $r('sys.color.icon_emphasize'))
              }
              .layoutWeight(1)
              .backgroundColor(Color.Transparent)
              .enabled(!this.busy)
              .accessibilitySelected(this.state.selectedId === group.id)
              .onClick(() => {
                if (!this.editing) {
                  this.onSelect(group.id);
                }
              })
              .bindContextMenu(() => this.GroupMenu(group), ResponseType.LongPress)
              if (this.editing) {
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(22)
                    .fontColor([$r('sys.color.icon_secondary')])
                }
                .id('token_group_delete_' + group.id)
                .width(44).height(48)
                .backgroundColor(Color.Transparent)
                .accessibilityText($r('app.string.token_group_delete'))
                .enabled(!this.busy)
                .onClick(() => this.deleteGroup(group))
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.square_and_pencil'))
                    .fontSize(22)
                    .fontColor([$r('sys.color.icon_secondary')])
                }
                .id('token_group_rename_' + group.id)
                .width(44).height(48)
                .backgroundColor(Color.Transparent)
                .accessibilityText($r('app.string.token_group_rename'))
                .enabled(!this.busy)
                .onClick(() => this.rename(group))
              }
            }
            .width('100%')
            .borderRadius(20)
            .clip(true)
            .backgroundColor(this.state.selectedId === group.id ?
              $r('sys.color.comp_emphasize_secondary') : Color.Transparent)
          }
        }, (group: TokenGroup) => JSON.stringify([group.id, group.name, group.color]))
      }
      .id('token_group_sidebar_list')
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
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
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .backgroundColor(Color.Transparent)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: MaterialTheme.hdsMaterialLevel()
        }
      }
    })
  }
}
