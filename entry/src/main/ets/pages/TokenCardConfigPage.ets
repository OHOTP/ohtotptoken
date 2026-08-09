import { TokenConfig, otpType } from 'common';
import { TokenStore } from 'common';
import { TokenCardStore, CardConfig } from 'common';
import { formProvider, formBindingData } from '@kit.FormKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { AppWindowInfo, CommonConstants } from 'common';
import { PageScaffold } from '../components/PageScaffold';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialTheme, MaterialThickness } from '../components/MaterialTheme';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { MaterialPolicy } from '../utils/MaterialPolicy';
import { TokenIcon } from 'uikit';

@Entry
@ComponentV2
export struct TokenCardConfigPage {
  pathStack: NavPathStack = new NavPathStack();
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local selectedUUIDs: string[] = [];
  @Local formId: string = '';
  @Local formName: string = 'tokenCard_1x2';
  @Local maxSelect: number = 1;

  /** 亮暗模式判定: 浅灰按钮背景在亮色下用深色文字, 暗色下用白色文字 */
  @Computed
  get is_dark_mode() {
    return this.window.ColorMode == ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  aboutToAppear(): void {
    this.formName = AppStorage.get<string>('card_config_formName') ?? 'tokenCard_1x2';
    this.formId = AppStorage.get<string>('card_config_formId') ?? '';
    AppStorage.setOrCreate('card_config_formId', '');
    this.maxSelect = this.formName === 'tokenCard_2x2' ? 2 : 1;

    const tkStore = TokenStore.getInstance();
    tkStore.initTokenStore().then(() => {
      tkStore.getTokens().then((tokens: TokenConfig[]) => {
        this.tokens = tokens;
      });
    });

    const cardStore = TokenCardStore.getInstance();
    cardStore.getCardConfig(this.formId).then((config: CardConfig | null) => {
      if (config) {
        this.selectedUUIDs = [...config.tokenUUIDs];
      }
    });
  }

  build() {
    HdsNavDestination() {
      // 页面背景与主 app 一致(实体 window_background, 亮 #eeeeee / 暗 #222)
      PageScaffold({ bgColor: $r('app.color.window_background') }) {
        // 顶对齐: 浮层 wrap 高度贴顶, 不撑满避免拦截列表触摸
        Stack({ alignContent: Alignment.Top }) {
          // 令牌列表: 撑满整个页面(顶部/底部经偏移让滚动内容从安全区穿过)
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
            List({ space: 4 }) {
              ForEach(this.tokens, (token: TokenConfig) => {
                ListItem() {
                  this.TokenItemBuilder(token)
                }
              }, (token: TokenConfig) => token.TokenUUID)
            }
            .width('100%')
            .height('100%')
            // 顶部偏移 = 浮层总高度(状态栏 + 导航栏 52 + 提示行), 首项不被浮层遮挡
            .contentStartOffset(this.window.AvoidTopHeight + 96)
            // 上下撑满: 滚动内容从安全区(状态栏/导航条)穿过, 沉浸滚动
            .contentEndOffset(this.window.AvoidBottomHeight)
            .scrollBar(BarState.Off)
          }

          // 顶部浮层: 自绘导航栏(返回+标题+确认按钮) + 选择提示
          // 沉浸光感渐变模糊: ImmersiveMaterial 材质(系统材质自带模糊/光感/边缘渐变)
          Column() {
            MaterialSurface({
              thickness: MaterialThickness.THIN,
              lightEffect: true,
              radius: 0,
              solidColor: MaterialTheme.surfaceBackground($r('app.color.window_background')),
              fillWidth: true
            }) {
              Column() {
                // 顶部安全区避让: 自绘导航栏需自行避开状态栏
                Column()
                  .height(this.window.AvoidTopHeight)

                // 导航栏: 返回按钮 + 页面标题 + 右侧确认按钮
                Row() {
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r('sys.symbol.chevron_left'))
                      .fontSize(20)
                      .fontWeight(FontWeight.Medium)
                      .fontColor([$r('sys.color.icon_primary')])
                  }
                  .width(36)
                  .height(36)
                  .backgroundColor(Color.Transparent)
                  .stateEffect(false)
                  .onClick(() => {
                    this.pathStack.pop();
                  })

                  Text($r('app.string.card_config_title'))
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .margin({ left: 8 })
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)

                  // 确认按钮(圆圈对勾): 选中令牌后才可用
                  MaterialSurface({
                    thickness: MaterialThickness.THIN,
                    lightEffect: true,
                    interactive: true,
                    materialColor: $r('app.color.button_blue'),
                    radius: 18,
                    solidColor: Color.Transparent,
                    fillWidth: false
                  }) {
                    Button({ type: ButtonType.Circle }) {
                      SymbolGlyph($r('sys.symbol.checkmark_circle'))
                        .fontSize(20)
                        .fontWeight(FontWeight.Medium)
                        .fontColor([Color.White])
                    }
                    .width(36)
                    .height(36)
                    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.button_blue')))
                    .stateEffect(false)
                    .enabled(this.selectedUUIDs.length > 0)
                    .onClick(() => {
                      this.saveAndRefresh();
                    })
                  }
                }
                .width('100%')
                .height(52)
                .padding({ left: 12, right: 16 })
                .alignItems(VerticalAlign.Center)

                // 选择提示行
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
                .padding({ left: 16, right: 16, top: 4, bottom: 8 })
              }
            }
          }
          // 浮层: 内容自适应高度(仅覆盖顶部区域, 下方列表可正常触摸)
          .width('100%')

        }
        .width('100%')
        .height('100%')
      }
    }
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
      // 标题栏避让系统安全区(状态栏): 对齐 TokenSortPage 等正常页面配置
      avoidLayoutSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.card_config_title'),
        },
      }
    })
    // 隐藏系统标题栏: 导航栏由页面自绘(返回+标题+确认按钮)
    .hideTitleBar(true)
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
      this.getUIContext().getPromptAction().showToast({ message: 'formId为空，无法更新卡片' });
      this.pathStack.pop();
      return;
    }

    try {
      const formData = await cardStore.generateCardData(this.formId, cardConfig);
      hilog.info(0, 'TokenCardConfig', `formData: ${JSON.stringify(formData)}`);
      const formBindingDataObj = formBindingData.createFormBindingData(formData);
      await formProvider.updateForm(this.formId, formBindingDataObj);
      hilog.info(0, 'TokenCardConfig', `updateForm success, formId: ${this.formId}`);
      this.getUIContext().getPromptAction().showToast({ message: '卡片更新成功' });
    } catch (err) {
      const errMsg = (err as BusinessError).message;
      hilog.error(0, 'TokenCardConfig', `updateForm error: ${errMsg}`);
      this.getUIContext().getPromptAction().showToast({ message: `卡片更新失败: ${errMsg}` });
    }

    this.pathStack.pop();
  }
}
