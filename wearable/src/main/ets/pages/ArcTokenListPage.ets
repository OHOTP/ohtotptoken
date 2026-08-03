import { QRCodeDialog } from 'uikit';
import { TokenPreference, EVENT_NAMES, dialogSystemMaterial } from 'common';
import { TokenConfig, TokenIconPacks } from 'common';
import { TokenStore } from 'common';
import { convertToken2URI } from 'common';
import { AppStorageV2, ArcList, ArcListItem,
  ArcButton,
  ArcButtonOptions,
  ArcButtonStyleMode,
  LengthMetrics,
  LengthUnit} from "@kit.ArkUI";
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppWindowInfo } from 'common';
import { ArcTokenItem } from "../components/ArcTokenItem";

let tkStore = TokenStore.getInstance();

@Entry
@ComponentV2
export struct ArcTokenListPage {
  @Local CurrentTokens: TokenConfig[] = [];
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;

  @Local bottomOptions: ArcButtonOptions = new ArcButtonOptions({});
  @Local loading: boolean = false;

  private listScroller: Scroller = new Scroller();
  private dialog_qrcode?: CustomDialogController;

  aboutToAppear(): void {
    // token 数据变更(增删改/同步完成)时全量刷新列表
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.on(EVENT_NAMES.TOKEN_CHANGED, () => this.onTokenChanged());
    }
    this.onTokenChanged();

    this.bottomOptions = new ArcButtonOptions({
      label: 'Sync',
      styleMode: ArcButtonStyleMode.EMPHASIZED_LIGHT,
      fontSize: new LengthMetrics(15, LengthUnit.FP),
      shadowEnabled: true,
      onClick: () => {
        this.loading = true;

        TokenStore.getInstance().DataSync().then(() => {
          this.loading = false;
        });
      }
    })
  }

  async onTokenChanged(): Promise<void> {
    this.CurrentTokens = await tkStore.getTokens();
  }

  async updateTokenConfig(conf: TokenConfig, toast: boolean = false): Promise<boolean> {
    try {
      if (!conf.TokenIconPath) {
        const iconPath = TokenIconPacks.getIconByIssuer(conf.TokenIssuer);
        if (iconPath !== '') {
          conf.TokenIconPath = iconPath;
        }
      }
      const isNew = !this.CurrentTokens.some(t => t.TokenUUID === conf.TokenUUID);
      await tkStore.updateToken(conf);
      if (isNew) {
        this.CurrentTokens = [...(await tkStore.getTokens())];
      }
      return true;
    } catch (e) {
      hilog.error(0, 'ArcTokenListPage', `updateTokenConfig failed: ${e}`);
      return false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.CurrentTokens.length === 0) {
        Column() {
          Text($r('app.string.app_wearable_guide_msg'))
            .textAlign(TextAlign.Center)
            .fontSize(20)
            .width('100%')
          if (this.loading) {
            LoadingProgress()
              .color(Color.White)
              .width(80).height(80)
          }
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)

        ArcButton({ options: this.bottomOptions })
      }
      ArcList({ initialIndex: 0, scroller: this.listScroller }) {
        ForEach(this.CurrentTokens,
          (token: TokenConfig, index: number) => {
            ArcListItem() {
              ArcTokenItem({
                Config: token,
                Update: async (conf_new): Promise<boolean> => {
                  return await this.updateTokenConfig(conf_new, false);
                }
              })
            }
            .padding({ left: 10, right: 10 })
            .swipeAction({
              start: {
                builder: () => {
                  this.TokenItemStart(token, index)
                }
              },
              end: {
                builder: () => {
                  this.TokenItemEnd(token)
                },
              }
            })
          }, (item: TokenConfig) => {
            return JSON.stringify(item)
          })
      }
      .layoutWeight(1)
      .width('100%')
      .height('100%')
      .space(LengthMetrics.vp(10))
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  TokenItemStart(conf: TokenConfig, index: number) {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.qrcode'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Orange)
      .padding(10)
      .onClick(() => {
        this.dialog_qrcode = new CustomDialogController({
          systemMaterial: dialogSystemMaterial(),
          builder: QRCodeDialog({
            content: convertToken2URI(conf),
            winSize: this.window.Size
          })
        });
        this.dialog_qrcode.open();
      })
    }
    .margin({ right: 10 })
    .width(50)
  }

  @Builder
  TokenItemEnd(conf: TokenConfig) {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.trash_fill'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Red)
      .padding(10)
      .onClick(async () => {
        this.getUIContext().showAlertDialog({
          title: $r('app.string.alert_remove_title', conf.TokenIssuer),
          subtitle: conf.TokenName,
          message: $r('app.string.alert_remove_confirm_msg'),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          primaryButton: {
            defaultFocus: false,
            value: $r('app.string.dialog_btn_cancel'),
            action: () => {
              return
            }
          },
          secondaryButton: {
            value: $r('app.string.dialog_btn_delete'),
            fontColor: Color.Red,
            action: async () => {
              tkStore.deleteToken(conf.TokenUUID);
            }
          }
        })
      })
    }
  }
}
