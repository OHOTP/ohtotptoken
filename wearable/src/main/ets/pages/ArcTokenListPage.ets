import { TokenPreference, EVENT_NAMES } from 'common';
import { TokenConfig, TokenIconPacks } from 'common';
import { TokenStore, WearEngineServer } from 'common';
import { systemDateTime } from '@kit.BasicServicesKit';
import { AppStorageV2, ArcList, ArcListItem, LengthMetrics } from "@kit.ArkUI";
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

  /** BLE 接收状态提示文案(空态/接收完成时显示, 手表小屏用文本不用 Toast) */
  @Local bleStatus: Resource | undefined = undefined;

  private listScroller: Scroller = new Scroller();
  /** 每秒时间戳广播定时器 ID(aboutToDisappear 清理) */
  private timestampIntervalId: number = -1;
  /** 页面可见性: 不可见时暂停广播以省电, 回前台时 force 刷新一次 */
  private appIsShow: boolean = true;

  aboutToAppear(): void {
    // token 数据变更(增删改/同步完成)时全量刷新列表
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.on(EVENT_NAMES.TOKEN_CHANGED, () => this.onTokenChanged());
    }
    // BLE 接收完成回调: 刷新列表 + 显示接收提示 3 秒后复位
    WearEngineServer.getInstance().setOnTokensSaved(async (count: number) => {
      await this.onTokenChanged();
      this.bleStatus = $r('app.string.app_wearable_ble_received');
      setTimeout(() => {
        this.bleStatus = undefined;
      }, 3000);
    });
    // 设置应用完成回调: 显示设置已同步提示 3 秒后复位
    WearEngineServer.getInstance().setOnSettingsApplied(() => {
      this.bleStatus = $r('app.string.app_wearable_ble_settings_done');
      setTimeout(() => {
        this.bleStatus = undefined;
      }, 3000);
    });
    this.onTokenChanged();

    // 每秒广播时间戳事件, 驱动各 TOTP 令牌按周期刷新(参考手机端 Index 实现:
    // ArcTokenItem 订阅 TIMESTAMP_CHANGED, 周期边界或 force 时重算验证码)
    this.timestampIntervalId = setInterval(() => {
      if (this.appCtx.eventHub != undefined && this.appIsShow) {
        this.updateTimestamp(false);
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timestampIntervalId !== -1) {
      clearInterval(this.timestampIntervalId);
      this.timestampIntervalId = -1;
    }
  }

  onPageShow(): void {
    this.appIsShow = true;
    // 回到前台立即强制刷新一次(后台期间可能错过 TOTP 周期边界)
    this.updateTimestamp(true);
  }

  onPageHide(): void {
    this.appIsShow = false;
  }

  /** 广播当前时间戳(秒)到全局事件总线 */
  updateTimestamp(force: boolean): void {
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, force);
    }
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
          // BLE 接收状态: 等待手机端同步 / 已接收令牌正在刷新
          Text(this.bleStatus !== undefined ? this.bleStatus : $r('app.string.app_wearable_ble_waiting'))
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .width('100%')
            .margin({ top: 8 })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
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
              // 仅保留左滑删除操作, 右滑二维码入口已移除(手表端令牌无本地二维码展示需求)
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
      .margin({ left: 5 })
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
