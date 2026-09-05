import { dialogSystemMaterial } from 'common';
import { MaterialTheme } from '../components/MaterialTheme';
import { TokenConfig } from 'common';
import { TokenStore } from 'common';
import { GenericDataSource } from 'common';
import { TokenCardStore, CardConfig } from 'common';
import { formProvider, formBindingData } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { AppWindowInfo } from 'common';
import { PageScaffold } from '../components/PageScaffold';
import {
  hdsMaterial,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { TokenIcon } from 'uikit';

@Entry
@ComponentV2
export struct TokenCardConfigPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  pathStack: NavPathStack = new NavPathStack();
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfig> = new GenericDataSource([]);
  @Local selectedUUIDs: string[] = [];
  @Local formId: string = '';
  @Local formName: string = 'tokenCard_1x2';
  @Local maxSelect: number = 1;
  private tokenListScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.formName = AppStorage.get<string>('card_config_formName') ?? 'tokenCard_1x2';
    this.formId = AppStorage.get<string>('card_config_formId') ?? '';
    AppStorage.setOrCreate('card_config_formId', '');
    this.maxSelect = this.formName === 'tokenCard_2x2' ? 2 : 1;

    const tkStore = TokenStore.getInstance();
    tkStore.initTokenStore().then(() => {
      tkStore.getTokens().then((tokens: TokenConfig[]) => {
        this.tokens = tokens;
        this.dataSource.updateData(tokens);
      });
    });

    const cardStore = TokenCardStore.getInstance();
    cardStore.getCardConfig(this.formId).then((config: CardConfig | null) => {
      if (config) {
        this.selectedUUIDs = [...config.tokenUUIDs];
        // 进入配置页即刷新卡片: 系统重启后卡片可能仍显示初始空态
        // (系统缓存 onAddForm 快照), 立即用最新配置纠正, 无需等待定时更新
        this.refreshCardNow(config);
      }
    });
  }

  /** 用现有配置立即刷新桌面卡片(进入配置页时兜底纠正空态) */
  private async refreshCardNow(config: CardConfig): Promise<void> {
    if (!this.formId) {
      return;
    }
    try {
      const cardStore = TokenCardStore.getInstance();
      const formData = await cardStore.generateCardData(this.formId, config);
      const bindingData = formBindingData.createFormBindingData(formData);
      await formProvider.updateForm(this.formId, bindingData);
      hilog.info(0, 'TokenCardConfig', `refreshCardNow success, formId: ${this.formId}`);
    } catch (err) {
      const errMsg = (err as BusinessError).message;
      hilog.error(0, 'TokenCardConfig', `refreshCardNow error: ${errMsg}`);
    }
  }

  @Builder
  SelectionHintBuilder() {
    Row() {
      Text($r('app.string.card_config_select_hint', this.maxSelect))
        .fontSize(16)
        .fontColor($r('app.color.str_main'))
        .fontWeight(FontWeight.Medium)
      Blank()
      Text($r('app.string.card_config_selected', this.selectedUUIDs.length, this.maxSelect))
        .fontSize(12)
        .fontColor($r('app.color.str_gray'))
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    HdsNavDestination() {
      PageScaffold({ bgColor: $r('app.color.window_background') }) {
        if (this.tokens.length === 0) {
          Column() {
            Text($r('app.string.card_config_no_token'))
              .fontSize(14)
              .fontColor($r('app.color.str_gray'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 4, scroller: this.tokenListScroller }) {
            LazyForEach(this.dataSource, (token: TokenConfig) => {
              ListItem() {
                this.TokenItemBuilder(token)
              }
            }, (token: TokenConfig) => token.TokenUUID)
          }
          .width('100%')
          .height('100%')
          .clip(false)
          .cachedCount({ minCount: 5, maxCount: 10 }, true)
          .contentEndOffset(this.window.AvoidBottomHeight)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          // 带 bottomBuilder 的标题栏直接启用光感，等级由系统自适应，不走应用能力降档。
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.card_config_title'),
        },
        menu: {
          value: [{
            content: {
              label: $r('app.string.card_config_confirm'),
              icon: $r('sys.symbol.checkmark_circle'),
              isEnabled: this.selectedUUIDs.length > 0,
              action: () => {
                this.saveAndRefresh();
              }
            }
          }]
        },
        bottomBuilder: {
          builder: (): void => this.SelectionHintBuilder(),
          height: 44
        }
      }
    })
    .bindToScrollable([this.tokenListScroller])
    .onReady((context: NavDestinationContext) => {
      this.pathStack = context.pathStack;
    })
  }

  @Builder
  TokenItemBuilder(token: TokenConfig) {
    // 令牌行: 实体背景(滚动列表逐项 systemMaterial 会材质层偏移,
    // 与手机端 TokenItem 默认行为一致), 选中态高亮
    Column() {
      Row() {
        TokenIcon({ issuer: token.TokenIssuer, icon_path: token.TokenIconPath })
          .width(32)
          .height(32)

        Column() {
          Text(token.TokenIssuer || token.TokenName)
            .fontSize(14)
            .fontColor($r('app.color.str_main'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (token.TokenIssuer && token.TokenName) {
            Text(token.TokenName)
              .fontSize(12)
              .fontColor($r('app.color.str_gray'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.selectedUUIDs.includes(token.TokenUUID)) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(22)
            .fontColor([$r('app.color.card_selected_icon')])
        } else {
          SymbolGlyph($r('sys.symbol.circle'))
            .fontSize(22)
            .fontColor([$r('app.color.card_unselected_icon')])
        }
      }
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .backgroundColor(this.selectedUUIDs.includes(token.TokenUUID)
        ? $r('app.color.card_item_bg') : $r('app.color.item_bg'))
      .onClick(() => {
        const idx = this.selectedUUIDs.indexOf(token.TokenUUID);
        if (idx >= 0) {
          this.selectedUUIDs.splice(idx, 1);
        } else if (this.selectedUUIDs.length < this.maxSelect) {
          this.selectedUUIDs.push(token.TokenUUID);
        }
      })
    }
    .width('100%')
    .padding({ left: 15, right: 15 })
  }

  private async saveAndRefresh(): Promise<void> {
    const cardConfig: CardConfig = {
      formId: this.formId,
      formName: this.formName,
      tokenUUIDs: [...this.selectedUUIDs],
    };

    const cardStore = TokenCardStore.getInstance();
    await cardStore.saveCardConfig(cardConfig);

    if (!this.formId) {
      hilog.error(0, 'TokenCardConfig', 'formId is empty, cannot update card');
      this.getUIContext().getPromptAction().showToast({
        systemMaterial: dialogSystemMaterial(), message: 'formId为空，无法更新卡片' });
      this.pathStack.pop();
      return;
    }

    try {
      const formData = await cardStore.generateCardData(this.formId, cardConfig);
      hilog.info(0, 'TokenCardConfig', `formData: ${JSON.stringify(formData)}`);
      const formBindingDataObj = formBindingData.createFormBindingData(formData);
      await formProvider.updateForm(this.formId, formBindingDataObj);
      hilog.info(0, 'TokenCardConfig', `updateForm success, formId: ${this.formId}`);
      this.getUIContext().getPromptAction().showToast({
        systemMaterial: dialogSystemMaterial(), message: '卡片更新成功' });
    } catch (err) {
      const errMsg = (err as BusinessError).message;
      hilog.error(0, 'TokenCardConfig', `updateForm error: ${errMsg}`);
      this.getUIContext().getPromptAction().showToast({
        systemMaterial: dialogSystemMaterial(), message: `卡片更新失败: ${errMsg}` });
    }

    this.pathStack.pop();
  }
}
