import { ble } from '@kit.ConnectivityKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PageScaffold } from '../components/PageScaffold';
import { SettingItem } from '../components/SettingItem';
import { SubItemDivider } from '../components/SubItemDivider';
import { TokenStore, TokenConfig, BleTokenClient, getDeviceDisplayName } from 'common';
import { TokenIcon } from 'uikit';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { CommonConstants, PermissionManager, AppWindowInfo } from 'common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialTheme, MaterialThickness } from '../components/MaterialTheme';
import { SETTING_PAGE_INSET } from '../components/SettingStyle';

const TAG = 'WatchSyncPage';
const DOMAIN = 0xFF02;

/**
 * 手表同步页面: 通过 BLE 扫描连接手表, 从当前令牌列表选择若干令牌传输到手表.
 * 背景: 分布式 KV 同步受安全等级限制(S4 无法与低安全手表同步), 改由蓝牙手动传输.
 */
@Entry
@ComponentV2
export struct WatchSyncPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local scanning: boolean = false;
  @Local devices: Array<ble.ScanResult> = [];
  @Local connected: boolean = false;
  @Local connectedDeviceId: string = '';
  @Local bonded: boolean = false;
  @Local tokens: TokenConfig[] = [];
  @Local selectedUuids: string[] = [];
  @Local transferring: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  /** 亮暗模式判定: 浅灰按钮背景在亮色下用深色文字, 暗色下用白色文字 */
  @Computed
  get is_dark_mode() {
    return this.window.ColorMode == ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 确保蓝牙权限已授予(user_grant, 已授予则不会弹窗)
    PermissionManager.getInstance().reqPermissionsFromUser(
      AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext);
    BleTokenClient.getInstance().setOnDevicesChanged((devices: Array<ble.ScanResult>) => {
      this.devices = devices;
      this.scanning = false;
    });
    BleTokenClient.getInstance().setOnConnectionChanged((deviceId: string, isConnected: boolean) => {
      this.connected = isConnected;
      this.connectedDeviceId = isConnected ? deviceId : '';
    });
    // 配对状态: 连接后系统自动发起配对, bonded 后才能传输 secret 载荷
    BleTokenClient.getInstance().setOnPairChanged((deviceId: string, isBonded: boolean) => {
      this.bonded = isBonded;
      if (!isBonded && this.connected) {
        showSnackBar($r('app.string.watch_sync_pair_failed'), SnackBarNotifyType.WARNING);
      }
    });
    TokenStore.getInstance().initTokenStore().then(() => {
      return TokenStore.getInstance().getTokens();
    }).then((tokens: TokenConfig[]) => {
      this.tokens = tokens;
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, `load tokens failed: ${err.message}`);
    });
  }

  aboutToDisappear(): void {
    BleTokenClient.getInstance().stopScan();
    BleTokenClient.getInstance().disconnect();
  }

  private scan(): void {
    this.scanning = true;
    BleTokenClient.getInstance().startScan();
  }

  private connectDevice(device: ble.ScanResult): void {
    BleTokenClient.getInstance().connect(device.deviceId);
  }

  /**
   * 按目标选中态幂等设置(双重检查当前状态, 避免重复/反向设置).
   *
   * 幂等语义是打破"select 赋值 → onChange 反馈环"的关键: 即使 select 重新
   * 绑定触发 onChange, 回调值不变 → 状态不变 → 渲染收敛; 翻转语义(toggle)
   * 在反馈环中永不收敛会卡死(真机实测).
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

  private transfer(): void {
    if (!this.connected) {
      showSnackBar($r('app.string.watch_sync_not_connected_warn'), SnackBarNotifyType.WARNING);
      return;
    }
    if (!this.bonded) {
      // 未完成系统 BLE 配对: 提示配对中, 等待系统配对流程
      showSnackBar($r('app.string.watch_sync_pairing'), SnackBarNotifyType.WARNING);
      return;
    }
    if (this.selectedUuids.length === 0) {
      showSnackBar($r('app.string.watch_sync_no_tokens'), SnackBarNotifyType.WARNING);
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

  /** 同步手机端外观/安全设置到手表(WATCH_SYNC_PREF_KEYS 白名单) */
  private syncSettings(): void {
    if (!this.connected) {
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

              // 连接手表区
              ListItem() {
                SettingItem({ title: $r('app.string.watch_sync_connect_section') }) {
                  Row() {
                    Text(this.connected
                      ? $r('app.string.watch_sync_connected')
                      : $r('app.string.watch_sync_not_connected'))
                      .fontSize($r('sys.float.ohos_id_text_size_body2'))
                      .fontColor($r('sys.color.font_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    // 扫描按钮: MaterialSurface 光感材质(沉浸档透明透出材质, 其余档语义色)
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
                        .enabled(!this.scanning)
                        .onClick(() => {
                          this.scan();
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
                  // 已连接但未完成配对: 提示等待配对确认
                  if (this.connected && !this.bonded) {
                    Row() {
                      Text($r('app.string.watch_sync_pairing'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_secondary'))
                        .layoutWeight(1)
                    }
                    .padding(10)

                    SubItemDivider()
                  }
                  // 扫描到的手表设备: 显示设备名(广播名/响应包名/系统名逐级兜底), 点击连接
                  ForEach(this.devices, (device: ble.ScanResult, index: number) => {
                    Row() {
                      Text(getDeviceDisplayName(device))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_primary'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.connected && this.connectedDeviceId === device.deviceId) {
                        Text($r('app.string.watch_sync_connected'))
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                      } else {
                        // 连接按钮: MaterialSurface 光感材质(沉浸档透明透出材质, 其余档语义色)
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
                    .padding(10)
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

              // 传输按钮: MaterialSurface 光感材质(沉浸档透明透出材质, 其余档语义色)
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
                    .enabled(!this.transferring && this.connected && this.bonded)
                    .onClick(() => {
                      this.transfer();
                    })
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

              // 同步设置按钮: 将手机端外观/安全设置(白名单)下发到手表
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
                    .enabled(!this.transferring && this.connected && this.bonded)
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
          mainTitle: $r('app.string.watch_sync_title'),
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
