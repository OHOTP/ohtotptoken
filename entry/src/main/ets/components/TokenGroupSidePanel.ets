import { HdsNavigation, HdsNavigationTitleMode, HdsSideMenu, HdsSideMenuMainItem, hdsMaterial } from '@kit.UIDesignKit';
import { MaterialTheme } from './MaterialTheme';
import { ALL_TOKEN_GROUPS, TokenGroup, TokenGroupState, TokenGroupStore } from 'common';

/** 固定入口使用原生菜单；动态分组使用 List，避免 HdsSideMenu 的五项限制。 */
@ComponentV2
export struct TokenGroupSidePanel {
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Event onSelect: (id: string) => void = () => {};
  @Event onManage: () => void = () => {};
  @Event onAdd: () => void = () => {};
  @Event onClose: () => void = () => {};
  private fixedItems: HdsSideMenuMainItem[] = [
    new HdsSideMenuMainItem({ label: $r('app.string.token_group_all') }),
    new HdsSideMenuMainItem({ label: $r('app.string.token_group_ungrouped') })
  ];

  @LocalBuilder
  GroupListBuilder() {
    Column({ space: 8 }) {
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
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  build() {
    // 使用真实标题栏承载操作，避免在普通侧栏内容区设置不生效的 systemMaterial。
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
      // 系统安全区由 AppShell 处理；组件级安全区仍需开启，让列表避开标题栏。
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary'),
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            },
            menuStyle: {
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
        },
        menu: {
          value: [
            {
              content: {
                icon: $r('sys.symbol.plus'),
                label: $r('app.string.token_group_new'),
                componentId: 'token_group_new',
                action: () => this.onAdd()
              }
            },
            {
              content: {
                icon: $r('sys.symbol.folder'),
                label: $r('app.string.token_group_manage'),
                componentId: 'token_group_manage',
                action: () => this.onManage()
              }
            }
          ]
        }
      }
    })
  }
}
