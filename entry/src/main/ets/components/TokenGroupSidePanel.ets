import { HdsSideMenu, HdsSideMenuMainItem } from '@kit.UIDesignKit';
import { ALL_TOKEN_GROUPS, TokenGroup, TokenGroupState, TokenGroupStore } from 'common';

/** 固定入口使用原生菜单；动态分组使用 List，避免 HdsSideMenu 的五项限制。 */
@ComponentV2
export struct TokenGroupSidePanel {
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Event onSelect: (id: string) => void = () => {};
  @Event onManage: () => void = () => {};
  @Event onAdd: () => void = () => {};
  private fixedItems: HdsSideMenuMainItem[] = [
    new HdsSideMenuMainItem({ label: $r('app.string.token_group_all') }),
    new HdsSideMenuMainItem({ label: $r('app.string.token_group_ungrouped') })
  ];

  build() {
    Column({ space: 8 }) {
      // 为外层固定的开关按钮留出顶部区域；抽屉内不重复创建关闭按钮。
      Row().height(56).width('100%')
      HdsSideMenu({
        items: this.fixedItems,
        selectedIndex: this.state.selectedId === ALL_TOKEN_GROUPS ? 0 : this.state.selectedId === '' ? 1 : -1,
        $selectedIndex: (index: number) => {
          if (index === 0 || index === 1) {
            this.onSelect(index === 0 ? ALL_TOKEN_GROUPS : '');
          }
        }
      })
      List({ space: 4 }) {
        ForEach(this.state.groups, (group: TokenGroup) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Text(group.name)
                .fontSize(16)
                .fontWeight(this.state.selectedId === group.id ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.state.selectedId === group.id ?
                  $r('sys.color.font_emphasize') : $r('sys.color.font_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .borderRadius(16)
            .backgroundColor(this.state.selectedId === group.id ?
              $r('sys.color.comp_emphasize_secondary') : Color.Transparent)
            .accessibilityText(group.name)
            .accessibilitySelected(this.state.selectedId === group.id)
            .onClick(() => this.onSelect(group.id))
          }
        }, (group: TokenGroup) => group.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      Button($r('app.string.token_group_new'), { type: ButtonType.Normal })
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .borderRadius(16)
        .fontColor($r('sys.color.font_emphasize'))
        .backgroundColor(Color.Transparent)
        .onClick(() => this.onAdd())
      Button($r('app.string.token_group_manage'), { type: ButtonType.Normal })
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .borderRadius(16)
        .fontColor($r('sys.color.font_emphasize'))
        .backgroundColor(Color.Transparent)
        .onClick(() => this.onManage())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }
}
