import { SubItemToggle } from '../../components/SubItemToggle'

import { AppStorageV2 } from '@kit.ArkUI';
import { AppPreference, SettingValue, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from 'common';
import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { AppWindowInfo } from 'common';
import { common } from '@kit.AbilityKit';
import { PermissionManager } from 'common';
import { throttle } from 'common';
import { ShowDataSyncDetailsPage } from '../ShowDataSyncDetailsPage';
import lazy { WatchSyncPage } from '../WatchSyncPage';
import lazy { BleWatchSyncPage } from '../BleWatchSyncPage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';

@Preview
@ComponentV2
export struct DataSyncSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Local RdbSyncEnable: SettingValue = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;

  aboutToAppear(): void {
    this.RdbSyncEnable = AppPreference.getPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE);
    this.appCtx.eventHub.on(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, this.updateDATASYNCPermissions);
  }

  updateDATASYNCPermissions(isAccess: boolean) {
    if (!isAccess) {
      this.RdbSyncEnable = false;
      AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, false);
    }
  }

  aboutToDisappear() {
    this.appCtx.eventHub.off(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, this.updateDATASYNCPermissions);
  }

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.ShowDataSyncDetailsPage) {
      ShowDataSyncDetailsPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.WatchSyncPage) {
      WatchSyncPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.BleWatchSyncPage) {
      BleWatchSyncPage({ scrollEffectType: this.scrollEffectType })
    }
  }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column() {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: "" }) {
                SubItemToggle({
                  icon: $r('sys.symbol.link'),
                  title: $r('app.string.data_rdb_sync'),
                  isOn: this.RdbSyncEnable as boolean,
                  description: $r('app.string.data_rdb_sync_des'),
                  onChange: (IsOn: boolean) => {
                    if (IsOn) {
                      PermissionManager.getInstance().reqPermissionsFromUser(this.appCtx);
                    }
                    this.RdbSyncEnable = IsOn;
                    AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemButton({
                  symbol: $r('sys.symbol.arrow_counterclockwise_clock'),
                  text: $r('app.string.data_rdb_sync_details')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.ShowDataSyncDetailsPage, null);
                  }, 1000))

                SubItemDivider()

                // 手表同步(P2P): 经 Wear Engine 应用间消息下发令牌(独立子页面, 经本 Sheet 内嵌导航栈 push)
                SubItemButton({
                  symbol: $r('sys.symbol.transfer'),
                  text: $r('app.string.setting_watch_sync')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.WatchSyncPage, null);
                  }, 1000))

                SubItemDivider()

                // 手表同步(BLE): 经 BLE GATT 通道下发令牌(独立子页面, 与 P2P 页互不依赖)
                SubItemButton({
                  symbol: $r('sys.symbol.transfer'),
                  text: $r('app.string.setting_watch_sync_ble')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.BleWatchSyncPage, null);
                  }, 1000))
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
          }
          .clip(false)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 滚动末端抬高底部避让区(导航条/小横条)，避免最后一项被遮挡
          .contentEndOffset(this.window.AvoidBottomHeight)
          // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
          .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
        .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
      }
      .width('100%')
      .height('100%')
      // 嵌入分栏时与左侧设置列表同底色；半模态场景继续按材质策略透出背板。
      .clip(false)
      .backgroundColor(this.embedded ? $r('app.color.window_background') :
        MaterialTheme.surfaceBackground($r('app.color.window_background')))
      .mode(NavigationMode.Stack)
      .navDestination(this.navDestinationBuilder)
      .bindToScrollable([this.sheetScroller])
      .hideBackButton(this.embedded)
      .titleMode(this.embedded ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.MODAL)
      .titleBar({
        avoidLayoutSafeArea: this.embedded,
        enableComponentSafeArea: true,
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
            materialType: MaterialTheme.hdsMaterialType(),
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.data_sync'),
          },
        }
      })
    }
  }
}
