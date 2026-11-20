import { QRCodeDialog } from 'uikit';
import { nowUnixSeconds, TokenPreference, EVENT_NAMES } from 'common';
import { TokenConfig, TokenIconPacks } from 'common';
import { TokenStore, WearEngineServer, BleTokenServer, BleSyncStatus, WearEngineClient, BluetoothPermissionResult, convertToken2URI, AppPreference, PREF_KEYS } from 'common';
import { AppStorageV2, ArcList, ArcListItem, LengthMetrics } from "@kit.ArkUI";
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppWindowInfo } from 'common';
import { ArcTokenItem } from "../components/ArcTokenItem";
import { startReceiveChannels } from '../utils/ReceiveChannels';

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
  /** 隐私政策是否已同意：未同意时整页只显示隐私政策确认面板 */
  @Local privacyAgreed: boolean = false;
  /** 接收通道启动中：避免重复点击重复申请/重复启动 */
  @Local receiveBusy: boolean = false;

  private listScroller: Scroller = new Scroller();
  /** 隐私政策正文滚动容器：首次布局后强制回到顶部，避免从中间开始显示 */
  private privacyScroller: Scroller = new Scroller();
  /** 每秒时间戳广播定时器 ID(aboutToDisappear 清理) */
  private timestampIntervalId: number = -1;
  /** 页面可见性: 不可见时暂停广播以省电, 回前台时 force 刷新一次 */
  private appIsShow: boolean = true;
  /** TOKEN_CHANGED 事件处理器引用(aboutToDisappear 注销) */
  private onTokenChangedHandler: () => void = () => {};
  /** bleStatus 3 秒复位定时器 ID(aboutToDisappear 清理) */
  private bleStatusTimerId: number = -1;

  aboutToAppear(): void {
    // token 数据变更(增删改/同步完成)时全量刷新列表
    if (this.appCtx.eventHub != undefined) {
      this.onTokenChangedHandler = () => this.onTokenChanged();
      this.appCtx.eventHub.on(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    }
    // BLE 接收完成回调: 刷新列表 + 显示接收提示 3 秒后复位
    WearEngineServer.getInstance().setOnTokensSaved(async (count: number) => {
      await this.onTokenChanged();
      this.showBleStatus($r('app.string.app_wearable_ble_received'));
    });
    // 设置应用完成回调: 显示设置已同步提示 3 秒后复位
    WearEngineServer.getInstance().setOnSettingsApplied(() => {
      this.showBleStatus($r('app.string.app_wearable_ble_settings_done'));
    });
    // BLE 通道接收状态(接收中/成功/失败): 与 P2P 回调共用 bleStatus 状态区,
    // 语义为最后事件胜出(showBleStatus 重置 3 秒复位计时); 列表刷新由 onTokensSaved 驱动
    BleTokenServer.getInstance().setOnTokensSaved(async (count: number) => {
      await this.onTokenChanged();
    });
    BleTokenServer.getInstance().setOnSettingsApplied(() => {
      this.showBleStatus($r('app.string.app_wearable_ble_settings_done'));
    });
    BleTokenServer.getInstance().setOnSyncStatus((status: BleSyncStatus) => {
      if (status === BleSyncStatus.RECEIVING) {
        this.showBleStatus($r('app.string.app_wearable_ble_receiving'));
      } else if (status === BleSyncStatus.SUCCESS) {
        this.showBleStatus($r('app.string.app_wearable_ble_received'));
      } else {
        this.showBleStatus($r('app.string.app_wearable_ble_failed'));
      }
    });
    // 合规(审核 7.17/7.19)：启动阶段不得申请权限或弹框。
    // 已授权时的接收通道由 EntryAbility 静默拉起；未授权则等用户主动点击「从手机接收令牌」。
    this.privacyAgreed = AppPreference.getPreference(PREF_KEYS.PRIVACY_POLICY_AGREED) === true;
    if (!this.privacyAgreed) {
      // 圆屏首帧 Scroll 可能停在底部：布局完成后强制回顶一次
      setTimeout(() => {
        this.privacyScroller.scrollEdge(Edge.Top);
      }, 100);
    }
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
    if (this.bleStatusTimerId !== -1) {
      clearTimeout(this.bleStatusTimerId);
      this.bleStatusTimerId = -1;
    }
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.off(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    }
    // 注销 WearEngineServer/BleTokenServer 单例回调, 避免页面销毁后仍被触达
    WearEngineServer.getInstance().setOnTokensSaved(undefined);
    WearEngineServer.getInstance().setOnSettingsApplied(undefined);
    BleTokenServer.getInstance().setOnTokensSaved(undefined);
    BleTokenServer.getInstance().setOnSettingsApplied(undefined);
    BleTokenServer.getInstance().setOnSyncStatus(undefined);
  }

  /** 让令牌列表默认获得焦点（表冠事件按焦点分发，ArcList 获焦后表冠才能滚动） */
  private requestListFocus(): void {
    // 等首帧布局完成后再请求焦点，否则节点还未挂载
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('token_list');
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(e.code, 'ArcTokenListPage', `requestFocus failed: ${e.message}`);
      }
    }, 120);
  }

  /** 同意隐私政策：持久化后进入主界面（此后启动不再弹窗） */
  acceptPrivacy(): void {
    AppPreference.setPreference(PREF_KEYS.PRIVACY_POLICY_AGREED, true);
    this.privacyAgreed = true;
    this.requestListFocus();
  }

  /** 不同意隐私政策：退出应用，本次运行不进入任何功能页面 */
  declinePrivacy(): void {
    const ctx: common.UIAbilityContext | undefined = this.appCtx;
    if (ctx != undefined) {
      ctx.terminateSelf().catch((err: BusinessError) => {
        hilog.error(err.code, 'ArcTokenListPage', `terminateSelf failed: ${err.message}`);
      });
    }
  }

  /**
   * 用户主动点击「从手机接收令牌」：此时才申请蓝牙权限并启动接收通道。
   *
   * 合规要求权限必须绑定用户主动触发的功能；拒绝后不得在启动/自动刷新等
   * 非用户场景再次弹窗，因此本方法只由按钮点击调用。
   */
  async enableReceive(): Promise<void> {
    if (this.receiveBusy) {
      return;
    }
    this.receiveBusy = true;
    try {
      const result: BluetoothPermissionResult =
        await WearEngineClient.getInstance().requestBluetoothPermission();
      if (result !== BluetoothPermissionResult.GRANTED) {
        this.showBleStatus($r('app.string.watch_receive_permission_denied'));
        return;
      }
      await startReceiveChannels(this.appCtx);
      this.showBleStatus($r('app.string.app_wearable_ble_waiting'));
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, 'ArcTokenListPage', `enableReceive failed: ${e.message}`);
      this.showBleStatus($r('app.string.watch_receive_permission_denied'));
    } finally {
      this.receiveBusy = false;
    }
  }

  /** 隐私政策确认面板：首次启动（未同意）时覆盖整页 */
  @Builder
  PrivacyPanel() {
    Column({ space: 8 }) {
      Text($r('app.string.watch_privacy_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffe0e0e0')
        .textAlign(TextAlign.Center)
        .width('100%')
      Text($r('app.string.watch_privacy_intro'))
        .fontSize(12)
        .fontColor('#ffb0b0b0')
        .textAlign(TextAlign.Center)
        .width('100%')
      Scroll(this.privacyScroller) {
        Text($r('app.string.watch_privacy_body'))
          .fontSize(11)
          .lineHeight(16)
          .fontColor('#ffd0d0d0')
          .width('100%')
          // 圆屏首帧可能保留错误滚动位置，出现时强制回到顶部
          .onAppear(() => {
            this.privacyScroller.scrollEdge(Edge.Top);
          })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 表冠同样依赖焦点：隐私正文出现时让 Scroll 默认获焦
      .focusable(true)
      .focusOnTouch(true)
      .defaultFocus(true)
      Row({ space: 8 }) {
        Button($r('app.string.watch_privacy_disagree'))
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .fontColor('#ffe0e0e0')
          .backgroundColor('#33ffffff')
          .onClick(() => this.declinePrivacy())
        Button($r('app.string.watch_privacy_agree'))
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .onClick(() => this.acceptPrivacy())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({
      left: this.roundInset(),
      right: this.roundInset(),
      top: Math.round(this.roundInset() * 0.7),
      bottom: this.roundInset()
    })
    .backgroundColor('#ff000000')
  }

  /**
   * 圆形表盘安全内边距：按屏宽 15% 计算（不同圆屏尺寸/密度都适用），
   * 避免文字与按钮被圆形边缘裁掉。
   */
  private roundInset(): number {
    const widthPx: number = this.window.Size !== undefined ? this.window.Size.width : 0;
    const widthVp: number = widthPx > 0 ? this.getUIContext().px2vp(widthPx) : 233;
    return Math.round(widthVp * 0.15);
  }

  /** 显示同步状态提示, 3 秒后复位(重复触发时重置计时) */  showBleStatus(status: Resource): void {
    this.bleStatus = status;
    if (this.bleStatusTimerId !== -1) {
      clearTimeout(this.bleStatusTimerId);
    }
    this.bleStatusTimerId = setTimeout(() => {
      this.bleStatus = undefined;
      this.bleStatusTimerId = -1;
    }, 3000);
  }

  onPageShow(): void {
    this.appIsShow = true;
    // 回到前台立即强制刷新一次(后台期间可能错过 TOTP 周期边界)
    this.updateTimestamp(true);
    // 页面可见后把焦点交还令牌列表，保证表冠可用
    if (this.privacyAgreed) {
      this.requestListFocus();
    }
  }

  onPageHide(): void {
    this.appIsShow = false;
  }

  /** 广播当前时间戳(秒)到全局事件总线 */
  updateTimestamp(force: boolean): void {
    const timestamp = nowUnixSeconds();
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
    if (!this.privacyAgreed) {
      // 首次启动：先确认隐私政策；未同意不进入主界面（审核 7.5 隐私政策告知）
      this.PrivacyPanel()
    } else {
      this.MainContent()
    }
  }

  @Builder
  MainContent() {
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
          // 用户主动触发：仅在点击时申请蓝牙权限并启动接收通道（审核 7.17）
          Button($r('app.string.watch_receive_action'))
            .height(40)
            .fontSize(14)
            .margin({ top: 14 })
            .enabled(!this.receiveBusy)
            .onClick(() => this.enableReceive())
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .padding({ left: this.roundInset(), right: this.roundInset() })
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
      // 表冠适配：表冠事件按焦点分发，ArcList 自带表冠滚动，需默认获焦
      .id('token_list')
      .focusable(true)
      .focusOnTouch(true)
      .defaultFocus(true)

      // 已有令牌时的重新同步入口：同样只在用户点击时申请权限（审核 7.17）
      if (this.CurrentTokens.length > 0) {
        Column() {
          Blank()
          // 同步/权限结果提示：没有空态文案区时也要能看到反馈
          if (this.bleStatus !== undefined) {
            Text(this.bleStatus)
              .fontSize(12)
              .fontColor('#ffe0e0e0')
              .textAlign(TextAlign.Center)
              .maxLines(2)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor('#99000000')
              .borderRadius(12)
              .margin({
                left: this.roundInset(),
                right: this.roundInset(),
                bottom: 6
              })
          }
          Row() {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(18)
                .fontColor([Color.White])
            }
            .width(36)
            .height(36)
            .backgroundColor('#33ffffff')
            .enabled(!this.receiveBusy)
            .accessibilityText($r('app.string.watch_receive_action'))
            .onClick(() => this.enableReceive())
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .padding({ right: this.roundInset(), bottom: this.roundInset() })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    // 与启动窗口背景保持一致，避免冷启动出现白屏转场
    .backgroundColor('#ff000000')
  }

  @Builder
  QRCodeDialogBuilder(conf: TokenConfig): void {
    QRCodeDialog({
      content: convertToken2URI(conf),
      winSize: this.window.Size
    })
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
          //title: $r('app.string.alert_remove_title', conf.TokenIssuer),
          //subtitle: conf.TokenName,
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
