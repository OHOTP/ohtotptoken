import { ble } from '@kit.ConnectivityKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { PageScaffold } from '../components/PageScaffold';
import { SettingItem } from '../components/SettingItem';
import { SubItemDivider } from '../components/SubItemDivider';
import { TokenStore, TokenConfig, BleTokenClient, getDeviceDisplayName, BluetoothPermissionResult, WearEngineClient } from 'common';
import { TokenIcon } from 'uikit';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppWindowInfo, CommonConstants } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialTheme, MaterialThickness } from '../components/MaterialTheme';
import { SETTING_PAGE_INSET } from '../components/SettingStyle';

const TAG = 'BleWatchSyncPage';
const DOMAIN = 0xFF02;
/**
 * GATT 建连超时保护(ms): 手表端应用未运行/广播未启动时连接事件可能长期不来,
 * 超时后提示"手表端未就绪"并复位页面状态, 允许立即重试.
 */
const CONNECT_TIMEOUT_MS = 8000;

/**
 * 手表同步(BLE)验证页: 通过 BLE GATT 通道下发令牌与设置到手表.
 * 与 P2P 页(WatchSyncPage)相互独立: 设备发现走页面可见期 BLE 扫描(按服务 UUID 过滤,
 * 离开页面即停), 点击设备建连(系统 BLE 配对 + GATT), 传输经分帧写入 + 5 秒操作超时保护.
 */
@Entry
@ComponentV2
export struct BleWatchSyncPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  /** 扫描发现的广播设备(按 deviceId 去重) */
  @Local devices: Array<ble.ScanResult> = [];
  /** 扫描进行中(由 start/stop 显式管理, 不随单条广播到达翻转) */
  @Local scanning: boolean = false;
  /** 当前连接中的设备 ID(建连尝试期间非空) */
  @Local connectingDeviceId: string = '';
  @Local connectedDeviceId: string = '';
  /** 当前设备系统 BLE 配对状态(bonded 后才允许传输 secret 载荷) */
  @Local bonded: boolean = false;
  /** 配对流程已失败(区分"配对中"与"配对失败可重试"两种提示) */
  @Local pairFailed: boolean = false;
  @Local tokens: TokenConfig[] = [];
  @Local selectedUuids: string[] = [];
  @Local transferring: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  /** 亮暗模式判定: 浅灰按钮背景在亮色下用深色文字, 暗色下用白色文字 */
  @Computed
  get is_dark_mode() {
    return this.window.ColorMode == ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 已建连目标设备(按钮可用态判定) */
  @Computed
  get has_connected_device(): boolean {
    return this.connectedDeviceId !== '';
  }

  private scroller: Scroller = new Scroller();
  /** 建连超时定时器 ID(建连完成/失败与 aboutToDisappear 清理) */
  private connectTimeoutId: number = -1;

  aboutToAppear(): void {
    TokenStore.getInstance().initTokenStore().then(() => {
      return TokenStore.getInstance().getTokens();
    }).then((tokens: TokenConfig[]) => {
      this.tokens = tokens;
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, `load tokens failed: ${err.message}`);
    });
    this.registerClientCallbacks();
  }

  /** 注册 BleTokenClient 单例回调(页面销毁时逐一传 undefined 注销) */
  private registerClientCallbacks(): void {
    BleTokenClient.getInstance().setOnDevicesChanged((devices: Array<ble.ScanResult>) => {
      this.devices = devices;
    });
    BleTokenClient.getInstance().setOnConnectionChanged((deviceId: string, connected: boolean) => {
      this.clearConnectTimeout();
      if (connected) {
        this.connectedDeviceId = deviceId;
        this.connectingDeviceId = '';
      } else if (this.connectingDeviceId === deviceId) {
        // 建连尝试中收到断开(含对端无响应被协议层拒绝): 立即失败, 不等超时
        this.connectingDeviceId = '';
        showSnackBar($r('app.string.watch_sync_watch_not_ready'), SnackBarNotifyType.WARNING);
      }
      if (this.connectedDeviceId === deviceId && !connected) {
        this.connectedDeviceId = '';
        this.bonded = false;
        this.pairFailed = false;
      }
    });
    // 配对状态: 连接后系统拉起配对流程, bonded 后才能传输 secret 载荷
    BleTokenClient.getInstance().setOnPairChanged((deviceId: string, isBonded: boolean) => {
      if (deviceId === this.connectedDeviceId || deviceId === this.connectingDeviceId) {
        this.bonded = isBonded;
        if (isBonded) {
          this.pairFailed = false;
        }
      }
    });
    // 配对流程失败(用户取消/系统拒绝): 提示并进入"可重试"状态
    BleTokenClient.getInstance().setOnPairFailed((deviceId: string) => {
      if (deviceId === this.connectedDeviceId || deviceId === this.connectingDeviceId) {
        this.bonded = false;
        this.pairFailed = true;
        showSnackBar($r('app.string.watch_sync_pair_failed'), SnackBarNotifyType.WARNING);
      }
    });
  }

  /**
   * 页面可见期入口: 先查后申请 ACCESS_BLUETOOTH(受限=系统蓝牙开关未开, 引导开蓝牙),
   * 授权成功后开始扫描. 挂载在 HdsNavDestination 的 onShown 事件(权限弹窗需 UI 就绪后展示).
   */
  private requestPermissionAndStartScan(): void {
    WearEngineClient.getInstance().requestBluetoothPermission().then((result: BluetoothPermissionResult) => {
      if (result === BluetoothPermissionResult.GRANTED) {
        this.startScan();
      } else if (result === BluetoothPermissionResult.RESTRICTED) {
        hilog.warn(DOMAIN, TAG, 'ACCESS_BLUETOOTH restricted, guide user to enable bluetooth');
        showSnackBar($r('app.string.watch_sync_bluetooth_restricted'), SnackBarNotifyType.WARNING);
      } else {
        hilog.warn(DOMAIN, TAG, 'ACCESS_BLUETOOTH not granted, skip scan');
        showSnackBar($r('app.string.watch_sync_bluetooth_permission_denied'), SnackBarNotifyType.WARNING);
      }
    });
  }

  /** 开始扫描(按服务 UUID 过滤; 重新扫描前清空陈旧广播结果; 启动失败复位扫描态) */
  private startScan(): void {
    BleTokenClient.getInstance().clearFoundDevices();
    this.scanning = BleTokenClient.getInstance().startScan();
  }

  /** 手动刷新: 重启扫描(页面可见期扫描常开, 重启以发现新广播) */
  private refreshScan(): void {
    BleTokenClient.getInstance().stopScan();
    this.startScan();
  }

  /** 停止扫描(页面不可见/销毁时调用, 控制扫描功耗) */
  private stopScan(): void {
    BleTokenClient.getInstance().stopScan();
    this.scanning = false;
  }

  aboutToDisappear(): void {
    this.clearConnectTimeout();
    this.stopScan();
    BleTokenClient.getInstance().disconnect();
    // 注销单例回调, 避免页面销毁后仍被触达
    BleTokenClient.getInstance().setOnDevicesChanged(undefined);
    BleTokenClient.getInstance().setOnConnectionChanged(undefined);
    BleTokenClient.getInstance().setOnPairChanged(undefined);
    BleTokenClient.getInstance().setOnPairFailed(undefined);
  }

  private clearConnectTimeout(): void {
    if (this.connectTimeoutId !== -1) {
      clearTimeout(this.connectTimeoutId);
      this.connectTimeoutId = -1;
    }
  }

  /** 设备显示名(广播名 → 响应包自定义名 → 系统已知名 → deviceId 兜底) */
  private deviceDisplayName(device: ble.ScanResult): string {
    return getDeviceDisplayName(device);
  }

  /**
   * 点击设备建连: 连接与配对结果经回调反馈; 手表端未就绪时由断开回调或
   * 超时保护兜底提示, 两种路径均复位状态允许立即重试.
   */
  private connectDevice(device: ble.ScanResult): void {
    if (this.connectingDeviceId !== '' || this.connectedDeviceId !== '') {
      return;
    }
    this.connectingDeviceId = device.deviceId;
    this.bonded = false;
    this.pairFailed = false;
    BleTokenClient.getInstance().connect(device.deviceId);
    this.connectTimeoutId = setTimeout(() => {
      this.connectTimeoutId = -1;
      if (this.connectingDeviceId === device.deviceId && this.connectedDeviceId === '') {
        this.connectingDeviceId = '';
        BleTokenClient.getInstance().disconnect();
        showSnackBar($r('app.string.watch_sync_watch_not_ready'), SnackBarNotifyType.WARNING);
      }
    }, CONNECT_TIMEOUT_MS);
  }

  /** 配对失败后重试配对(对已连接设备重新发起系统配对流程) */
  private retryPairing(): void {
    if (!this.has_connected_device) {
      return;
    }
    BleTokenClient.getInstance().retryPairing(this.connectedDeviceId).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, `retryPairing failed: ${err.message}`);
      showSnackBar($r('app.string.watch_sync_pair_failed'), SnackBarNotifyType.WARNING);
    });
  }

  /**
   * 按目标选中态幂等设置(双重检查当前状态, 避免重复/反向设置).
   */
  private setTokenSelected(uuid: string, selected: boolean): void {
    const has = this.selectedUuids.includes(uuid);
    if (selected && !has) {
      this.selectedUuids = [...this.selectedUuids, uuid];
    } else if (!selected && has) {
      this.selectedUuids = this.selectedUuids.filter((u: string) => u !== uuid);
    }
  }

  /** 行点击切换: 目标态 = 当前选中态的翻转 */
  private toggleToken(uuid: string): void {
    this.setTokenSelected(uuid, !this.selectedUuids.includes(uuid));
  }

  /** 传输前置校验: 重入/未连接/未配对/未选令牌时给出对应提示 */
  private checkTransferReady(): boolean {
    if (this.transferring) {
      // 进行中守卫: 同帧双击/事件重入会并发两路 GATT 分帧交叉写入, 导致接收端解密失败
      return false;
    }
    if (!this.has_connected_device) {
      showSnackBar($r('app.string.watch_sync_not_connected_warn'), SnackBarNotifyType.WARNING);
      return false;
    }
    if (!this.bonded) {
      // 未完成系统 BLE 配对: 提示配对中, 等待系统配对流程
      showSnackBar($r('app.string.watch_sync_pairing'), SnackBarNotifyType.WARNING);
      return false;
    }
    if (this.selectedUuids.length === 0) {
      showSnackBar($r('app.string.watch_sync_no_tokens'), SnackBarNotifyType.WARNING);
      return false;
    }
    return true;
  }

  /** 传输选中令牌: GATT 分帧写入, 结果为真实入库反馈(手表端处理失败即失败, 可立即重试) */
  private transfer(): void {
    if (!this.checkTransferReady()) {
      return;
    }
    this.transferring = true;
    const selected: TokenConfig[] = this.tokens.filter((t: TokenConfig) => this.selectedUuids.includes(t.TokenUUID));
    BleTokenClient.getInstance().sendTokens(selected).then(() => {
      this.transferring = false;
      showSnackBar($r('app.string.watch_sync_transfer_done'), SnackBarNotifyType.SUCCESS);
    }).catch((err: Error) => {
      this.transferring = false;
      hilog.error(DOMAIN, TAG, `transfer failed: ${err.message}`);
      showSnackBar($r('app.string.watch_sync_transfer_failed'), SnackBarNotifyType.WARNING);
    });
  }

  /** 同步手机端外观/安全设置到手表(WEAR_SYNC_PREF_KEYS 白名单) */
  private syncSettings(): void {
    if (this.transferring) {
      return;
    }
    if (!this.has_connected_device) {
      showSnackBar($r('app.string.watch_sync_not_connected_warn'), SnackBarNotifyType.WARNING);
      return;
    }
    if (!this.bonded) {
      showSnackBar($r('app.string.watch_sync_pairing'), SnackBarNotifyType.WARNING);
      return;
    }
    this.transferring = true;
    BleTokenClient.getInstance().sendSettings().then(() => {
      this.transferring = false;
      showSnackBar($r('app.string.watch_sync_settings_done'), SnackBarNotifyType.SUCCESS);
    }).catch((err: Error) => {
      this.transferring = false;
      hilog.error(DOMAIN, TAG, `sync settings failed: ${err.message}`);
      showSnackBar($r('app.string.watch_sync_transfer_failed'), SnackBarNotifyType.WARNING);
    });
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        RelativeContainer() {
          Stack() {
            List({ space: 10, scroller: this.scroller }) {
              // 顶部避让
              ListItem()
                .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)

              // 目标设备区: 页面可见期扫描发现广播设备, 点击建连
              ListItem() {
                SettingItem({ title: $r('app.string.watch_sync_connect_section') }) {
                  Row() {
                    Text(this.has_connected_device
                      ? $r('app.string.watch_sync_connected')
                      : $r('app.string.watch_sync_not_connected'))
                      .fontSize($r('sys.float.ohos_id_text_size_body2'))
                      .fontColor($r('sys.color.font_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    // 刷新扫描按钮: MaterialSurface 光感材质(重启扫描以发现新广播)
                    MaterialSurface({
                      thickness: MaterialThickness.THIN,
                      lightEffect: true,
                      interactive: true,
                      materialColor: $r('app.color.button_light_gray'),
                      radius: 8,
                      solidColor: Color.Transparent,
                      fillWidth: false
                    }) {
                      Button($r('app.string.watch_sync_scan'))
                        .fontSize(14)
                        .height(32)
                        .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.button_light_gray')))
                        .fontColor(this.is_dark_mode ? Color.White : Color.Black)
                        .stateEffect(false)
                        .onClick(() => {
                          this.refreshScan();
                        })
                    }
                  }
                  .padding(10)

                  SubItemDivider()

                  if (this.devices.length === 0) {
                    Row() {
                      Text(this.scanning
                        ? $r('app.string.watch_sync_scanning')
                        : $r('app.string.watch_sync_scan_hint'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_secondary'))
                        .layoutWeight(1)
                    }
                    .padding(10)
                  }
                  // 已连接但未完成配对: 提示等待配对确认; 配对失败时点击可重试
                  if (this.has_connected_device && !this.bonded) {
                    Row() {
                      Text(this.pairFailed
                        ? $r('app.string.watch_sync_pair_failed')
                        : $r('app.string.watch_sync_pairing'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor(this.pairFailed ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                        .layoutWeight(1)
                    }
                    .padding(10)
                    .onClick(() => {
                      if (this.pairFailed) {
                        this.retryPairing();
                      }
                    })

                    SubItemDivider()
                  }
                  // 扫描到的手表设备: 点击建连, 建连中禁用避免重复点击
                  ForEach(this.devices, (device: ble.ScanResult, index: number) => {
                    Row() {
                      Text(this.deviceDisplayName(device))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_primary'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.connectedDeviceId === device.deviceId) {
                        Text($r('app.string.watch_sync_connected'))
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                      } else if (this.connectingDeviceId === device.deviceId) {
                        Text($r('app.string.watch_sync_connecting'))
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                      } else {
                        // 连接按钮: MaterialSurface 光感材质
                        MaterialSurface({
                          thickness: MaterialThickness.THIN,
                          lightEffect: true,
                          interactive: true,
                          materialColor: $r('app.color.button_light_gray'),
                          radius: 8,
                          solidColor: Color.Transparent,
                          fillWidth: false
                        }) {
                          Button($r('app.string.watch_sync_connect'))
                            .fontSize(14)
                            .height(32)
                            .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.button_light_gray')))
                            .fontColor(this.is_dark_mode ? Color.White : Color.Black)
                            .stateEffect(false)
                            .enabled(this.connectingDeviceId === '' && !this.has_connected_device)
                            .onClick(() => {
                              this.connectDevice(device);
                            })
                        }
                      }
                    }
                    .padding(10)
                    .onClick(() => {
                      this.connectDevice(device);
                    })

                    // 行间分隔线: 最后一个 item 之后不加
                    if (index < this.devices.length - 1) {
                      SubItemDivider()
                    }
                  }, (device: ble.ScanResult) => device.deviceId)
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

              // 令牌选择区
              ListItem() {
                SettingItem({ title: $r('app.string.watch_sync_token_list') }) {
                  if (this.tokens.length === 0) {
                    Row() {
                      Text($r('app.string.watch_sync_no_token_hint'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_secondary'))
                    }
                    .padding(10)
                  }
                  ForEach(this.tokens, (token: TokenConfig, index: number) => {
                    Row({ space: 10 }) {
                      // 令牌图标 + host name, 便于识别
                      TokenIcon({ issuer: token.TokenIssuer, icon_path: token.TokenIconPath })
                        .width(32)
                        .height(32)
                      Column() {
                        Text(token.TokenName)
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(token.TokenIssuer)
                          .fontSize(12)
                          .fontColor($r('sys.color.font_secondary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      // 受控选中 + 幂等同步: select 绑定驱动选中态, onChange 按回调值
                      // 幂等设置(双重检查当前状态)——即使 select 重绑触发 onChange 反馈,
                      // 回调值不变则状态不变, 渲染收敛不卡死(翻转语义会无限循环)
                      Checkbox()
                        .select(this.selectedUuids.includes(token.TokenUUID))
                        .shape(CheckBoxShape.ROUNDED_SQUARE)
                        .onChange((checked: boolean) => {
                          this.setTokenSelected(token.TokenUUID, checked);
                        })
                    }
                    // 加大左右内边距: 图标背景与列表边缘保持间距(对齐手机端列表项 16vp 标准)
                    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                    .onClick(() => {
                      this.toggleToken(token.TokenUUID);
                    })

                    // 行间分隔线: 最后一个 item 之后不加
                    if (index < this.tokens.length - 1) {
                      SubItemDivider()
                    }
                  }, (token: TokenConfig) => token.TokenUUID)
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

              // 传输按钮: 未连接设备时禁用
              ListItem() {
                MaterialSurface({
                  thickness: MaterialThickness.THIN,
                  lightEffect: true,
                  interactive: true,
                  materialColor: $r('app.color.button_light_gray'),
                  radius: 10,
                  solidColor: Color.Transparent,
                  fillWidth: true
                }) {
                  Button($r('app.string.watch_sync_transfer'))
                    .width('100%')
                    .height(44)
                    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.button_light_gray')))
                    .fontColor(this.is_dark_mode ? Color.White : Color.Black)
                    .stateEffect(false)
                    .enabled(!this.transferring && this.has_connected_device)
                    .onClick(() => {
                      this.transfer();
                    })
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

              // 同步设置按钮: 将手机端外观/安全设置(白名单)经 BLE 下发到手表
              ListItem() {
                MaterialSurface({
                  thickness: MaterialThickness.THIN,
                  lightEffect: true,
                  interactive: true,
                  materialColor: $r('app.color.button_light_gray'),
                  radius: 10,
                  solidColor: Color.Transparent,
                  fillWidth: true
                }) {
                  Button($r('app.string.watch_sync_settings'))
                    .width('100%')
                    .height(44)
                    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.button_light_gray')))
                    .fontColor(this.is_dark_mode ? Color.White : Color.Black)
                    .stateEffect(false)
                    .enabled(!this.transferring && this.has_connected_device)
                    .onClick(() => {
                      this.syncSettings();
                    })
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .scrollBar(BarState.Off)
            .backgroundColor($r('app.color.window_background'))
            // 沉浸式底部避让: 内容可滚动进入安全区, 滚动到底时最后一项抬升至导航条之上
            .contentEndOffset(this.window.AvoidBottomHeight)
            .width('100%')
            .height('100%')
          }
        }
      }
    }
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
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
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.watch_sync_title_ble'),
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
    .onShown(() => {
      this.requestPermissionAndStartScan();
    })
    .onHidden(() => {
      // 页面不可见即停扫描(功耗控制); 连接保留, 返回页面后扫描自动恢复
      this.stopScan();
    })
  }
}
