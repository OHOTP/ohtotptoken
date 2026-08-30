import { TokenItem } from "../components/TokenItem";
import { MaterialTheme } from '../components/MaterialTheme';
import { MaterialPolicy } from '../utils/MaterialPolicy';

import { AppPreference, TokenPreference, EVENT_NAMES } from 'common';
import { TokenConfig } from 'common';
import { TokenStore } from 'common';
import { GenericDataSource } from 'common';
import { AppWindowInfo } from 'common';
import { PageScaffold } from "../components/PageScaffold";
import { AppStorageV2, ListItemModifier } from "@kit.ArkUI";
import { common } from "@kit.AbilityKit";
import { CommonConstants } from 'common';
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  HdsListItem,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from "@kit.UIDesignKit";

let tkStore = TokenStore.getInstance();

/** 排序页系统列表项的实体表面，与主令牌列表使用相同的边距和圆角。 */
class SortTokenListItemModifier extends ListItemModifier {
  constructor(left: number, right: number, radius: number, backgroundColor: ResourceColor) {
    super();
    this.margin({ left: left, right: right });
    this.borderRadius(radius);
    this.clip(true);
    this.backgroundColor(backgroundColor);
  }
}

@Preview
@ComponentV2
export struct TokenSortPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onExitFullScreen: () => void = () => {};
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfig> = new GenericDataSource([]);

  private sortListScroller: Scroller = new Scroller();

  // 使用 AppStorage 获取 context
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTokenChangedHandler: () => void = () => {};

  aboutToAppear(): void {
    this.onTokenChangedHandler = () => this.loadTokens();
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.loadTokens();
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
  }

  private async loadTokens(): Promise<void> {
    this.tokens = await tkStore.getTokens();
    this.dataSource.updateData(this.tokens);
  }

  @Builder
  SortTokenItemBuilder(token: TokenConfig) {
    TokenItem({
      Config: token,
      sortMode: true,
      hdsCardMode: true,
      Update: async (conf_new): Promise<boolean> => {
        try {
          await tkStore.updateToken(conf_new);
          return true;
        } catch (e) {
          hilog.error(0, 'TokenSortPage', `Update failed: ${e}`);
          return false;
        }
      }
    })
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        List({ space: this.token_preference.app_appearance_item_space, scroller: this.sortListScroller }) {
          LazyForEach(this.dataSource, (token: TokenConfig, index: number) => {
            HdsListItem({
              customItemBuilder: (): void => { this.SortTokenItemBuilder(token) },
              listItemModifier: new SortTokenListItemModifier(
                this.token_preference.app_appearance_token_list_item_prefix_padding,
                this.token_preference.app_appearance_token_list_item_suffix_padding,
                this.token_preference.app_appearance_item_radius,
                MaterialTheme.isTokenItemMaterialEffective() ? Color.Transparent : $r('app.color.item_bg'))
            })
          }, (item: TokenConfig) => {
            return item.TokenUUID
          })
            .onMove((from: number, to: number) => {
              setTimeout(() => tkStore.updateTokenRank(from, to), 500);
            })

        }
        .clip(false)
        .alignListItem(ListItemAlign.Center)
        .lanes(this.window.IsPc ?
          { minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width } : 1)
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .contentStartOffset(this.window.AvoidTopHeight + CommonConstants.AVOID_TOP_BASE_HEIGHT)
        .contentEndOffset(this.window.AvoidBottomHeight)
      }
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType,
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.token_sort_page_title'),
        },
      }
    })
    .bindToScrollable([this.sortListScroller])
    .onWillDisappear(() => this.onExitFullScreen())
  }
}
