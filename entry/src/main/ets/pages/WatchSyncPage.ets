import { wearEngine } from '@kit.WearEngine';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PageScaffold } from '../components/PageScaffold';
import { SettingItem } from '../components/SettingItem';
import { SubItemDivider } from '../components/SubItemDivider';
import { TokenStore, TokenConfig, WearEngineClient } from 'common';
import { TokenIcon } from 'uikit';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppWindowInfo, CommonConstants } from 'common';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { MaterialSurface } from '../components/MaterialSurface';
import { MaterialTheme, MaterialThickness } from '../components/MaterialTheme';
import { SETTING_PAGE_INSET } from '../components/SettingStyle';

const TAG = 'WatchSyncPage';
const DOMAIN = 0xFF02;

/**
 * 手表同步页面: 通过 Wear Engine 应用间消息通信(P2P)下发令牌与设置到手表.
 * 背景: 分布式 KV 同步受安全等级限制(S4 无法与低安全手表同步);
 * P2P 基于华为运动健康既有配对连接(华为账号信任链), 从已连接设备列表选择目标手表.
 */
@Entry
@ComponentV2
export struct WatchSyncPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  /** 已连接穿戴设备列表(华为运动健康配对连接) */
  @Local devices: Array<wearEngine.Device> = [];
  @Local refreshingDevices: boolean = false;
  /** 当前选中的目标设备 randomId */
  @Local selectedDeviceRandomId: string = '';
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
    TokenStore.getInstance().initTokenStore().then(() => {
      return TokenStore.getInstance().getTokens();
    }).then((tokens: TokenConfig[]) => {
      this.tokens = tokens;
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, `load tokens failed: ${err.message}`);
    });
    this.refreshDevices();
  }

  aboutToDisappear(): void {
  }

  /** 刷新已连接设备列表 */
  private async refreshDevices(): Promise<void> {
    this.refreshingDevices = true;
    // 先请求用户授权(受限权限验证; P2P 本身无需, 但为授权链路铺路)
    WearEngineClient.getInstance().ensureAuthorized().then((authorized: boolean) => {
      hilog.info(DOMAIN, TAG, `ensureAuthorized: ${authorized}`);
    });
    try {
      this.devices = await WearEngineClient.getInstance().getConnectedDevices();
      hilog.info(DOMAIN, TAG, `connected devices: ${this.devices.length}`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `getConnectedDevices failed: ${e.message}`);
      this.devices = [];
    }
    this.refreshingDevices = false;
  }

  /** 设备显示名: 名称 → 型号 → randomId 兜底 */
  private deviceDisplayName(device: wearEngine.Device): string {
    if (device.name !== undefined && device.name !== '') {
      return device.name;
    }
    if (device.model !== undefined && device.model !== '') {
      return device.model;
    }
    return device.randomId;
  }

  /** 选择目标设备并拉起手表端应用 */
  private selectDevice(device: wearEngine.Device): void {
    this.selectedDeviceRandomId = device.randomId;
    // 发送前拉起手表端应用(两端应用需同时处于启动状态)
    WearEngineClient.getInstance().startRemoteApp(device.randomId).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, `startRemoteApp failed(可忽略): ${err.message}`);
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

  private transfer(): void {
    if (this.selectedDeviceRandomId === '') {
      showSnackBar($r('app.string.watch_sync_not_connected_warn'), SnackBarNotifyType.WARNING);
      return;
    }
    if (this.selectedUuids.length === 0) {
      showSnackBar($r('app.string.watch_sync_no_tokens'), SnackBarNotifyType.WARNING);
      return;
    }
    this.transferring = true;
    const selected: TokenConfig[] = this.tokens.filter((t: TokenConfig) => this.selectedUuids.includes(t.TokenUUID));
    WearEngineClient.getInstance().sendTokens(this.selectedDeviceRandomId, selected).then(() => {
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
    if (this.selectedDeviceRandomId === '') {
      showSnackBar($r('app.string.watch_sync_not_connected_warn'), SnackBarNotifyType.WARNING);
      return;
    }
    this.transferring = true;
    WearEngineClient.getInstance().sendSettings(this.selectedDeviceRandomId).then(() => {
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

              // 目标设备区
              ListItem() {
                SettingItem({ title: $r('app.string.watch_sync_connect_section') }) {
                  Row() {
                    Text(this.devices.length > 0
                      ? $r('app.string.watch_sync_connected')
                      : $r('app.string.watch_sync_not_connected'))
                      .fontSize($r('sys.float.ohos_id_text_size_body2'))
                      .fontColor($r('sys.color.font_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    // 刷新设备列表按钮: MaterialSurface 光感材质
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
                        .enabled(!this.refreshingDevices)
                        .onClick(() => {
                          this.refreshDevices();
                        })
                    }
                  }
                  .padding(10)

                  SubItemDivider()

                  if (this.devices.length === 0) {
                    Row() {
                      Text(this.refreshingDevices
                        ? $r('app.string.watch_sync_scanning')
                        : $r('app.string.watch_sync_no_device_hint'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_secondary'))
                        .layoutWeight(1)
                    }
                    .padding(10)
                  }
                  // 已连接设备: 点击选择为目标
                  ForEach(this.devices, (device: wearEngine.Device, index: number) => {
                    Row() {
                      Text(this.deviceDisplayName(device))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.font_primary'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.selectedDeviceRandomId === device.randomId) {
                        Text($r('app.string.watch_sync_connected'))
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                      } else {
                        // 选择按钮: MaterialSurface 光感材质
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
                              this.selectDevice(device);
                            })
                        }
                      }
                    }
                    .padding(10)
                    .onClick(() => {
                      this.selectDevice(device);
                    })

                    // 行间分隔线: 最后一个 item 之后不加
                    if (index < this.devices.length - 1) {
                      SubItemDivider()
                    }
                  }, (device: wearEngine.Device) => device.randomId)
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

              // 传输按钮: MaterialSurface 光感材质
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
                    .enabled(!this.transferring && this.selectedDeviceRandomId !== '')
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
                    .enabled(!this.transferring && this.selectedDeviceRandomId !== '')
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
