import { SettingItem } from '../../components/SettingItem';
import { SubItemButton } from '../../components/SubItemButton';
import { SubItemDivider } from '../../components/SubItemDivider';
import { MaterialPolicy } from '../../utils/MaterialPolicy';

import { AppWindowInfo } from 'common';
import { bundleManager, common } from '@kit.AbilityKit';
import { AppStorageV2, curves, DrawableDescriptor, LayeredDrawableDescriptor } from '@kit.ArkUI';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppPreference, PREF_KEYS } from 'common';
import { throttle, startBrowsableAbility, EXTERNAL_URLS } from 'common';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SETTING_PAGE_INSET, SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';

/** 开源软件条目：展示名 + 仓库路径 + 跳转链接 */
interface OssEntry {
  name: string;
  repoPath: string;
  url: string;
}

/** 软件信息静态行（标题 + 右侧值），不可点击 */
@ComponentV2
struct AboutInfoRow {
  @Require @Param label: ResourceStr = '';
  @Require @Param value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text(this.value)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
  }
}

@Preview
@ComponentV2
export struct AboutSheet {
  @Require @Param scrollEffectStyle: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Event debugModeChanged: (isOn: boolean) => void = () => {};
  @Local debug_mode_is_on: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  private appIcon: DrawableDescriptor | undefined = undefined;
  private versionText: string = '';
  private bundleName: string = '';
  private versionCodeText: string = '';
  private contactEmail: string = 'enbinli@outlook.com';
  private contributors: string =
    '@Solidfaker, @eveloki, @lsxuan12138, @TomStilson, @tomygin, @wulongshe, @ShigureMoe';
  private ossEntries: OssEntry[] = [
    { name: 'libcotp', repoPath: 'paolostivanin/libcotp', url: EXTERNAL_URLS.OSS_LIBCOTP },
    { name: 'TOTP-MCU', repoPath: 'Netthaw/TOTP-MCU', url: EXTERNAL_URLS.OSS_TOTP_MCU },
    {
      name: 'fortitoken-mobile-registration',
      repoPath: 'ss23/fortitoken-mobile-registration',
      url: EXTERNAL_URLS.OSS_FORTI_REGISTRATION
    },
    { name: 'Aigis', repoPath: 'iamhyc/Aigis', url: EXTERNAL_URLS.OSS_AIGIS },
    { name: 'andOTP Icons', repoPath: 'andOTP/andOTP', url: EXTERNAL_URLS.OSS_ANDOTP_ICONS },
  ];
  private debug_mode_counter: number = 0;

  aboutToAppear(): void {
    let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
    let versionName = bundleInfo?.versionName ?? '';
    this.bundleName = bundleInfo?.name ?? '';
    this.versionCodeText = `${bundleInfo?.versionCode ?? ''}`;
    this.versionText =
      this.appCtx?.resourceManager.getStringSync($r('app.string.about_app_version').id, versionName);
    // 官方分层图标接口：直接渲染与桌面一致的应用图标（前景+背景+蒙版）
    let descriptor = this.appCtx?.resourceManager.getDrawableDescriptor($r('app.media.layered_image').id);
    if (descriptor instanceof LayeredDrawableDescriptor) {
      this.appIcon = descriptor;
    }
  }

  build() {
    Column() {
      HdsNavigation() {
        List({ scroller: this.sheetScroller, space: 10 }) {
          // 顶部品牌区：应用图标 + 名称 + 版本号（版本号保留 DEBUG 模式彩蛋）
          ListItem() {
            Column({ space: 8 }) {
              if (this.appIcon) {
                Image(this.appIcon)
                  .width(72)
                  .height(72)
              } else {
                Image($r('app.media.foreground'))
                  .width(72)
                  .height(72)
              }
              Text($r('app.string.EntryAbility_label'))
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
              Text(this.versionText)
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .onClick(() => {
                  if (!this.debug_mode_is_on) {
                    setTimeout(() => {
                      this.debug_mode_counter = 0;
                    }, 2000);
                    if (this.debug_mode_counter > 7) {
                      this.window.uiContext?.animateTo({ curve: curves.springMotion() }, () => {
                        this.debug_mode_is_on = true;
                        AppPreference.setPreference(PREF_KEYS.DEBUG_MODE_ON, true);
                        this.debugModeChanged(true);
                        showSnackBar('DEBUG MODE ON', SnackBarNotifyType.INFO);
                      })

                    }
                    this.debug_mode_counter++;
                  }
                })
            }
            .width('100%')
            .padding({ top: 16, bottom: 8 })
          }

          // 软件信息
          ListItem() {
            SettingItem({ title: $r('app.string.about_software_info') }) {
              AboutInfoRow({ label: $r('app.string.about_bundle_name'), value: this.bundleName })
              SubItemDivider()
              AboutInfoRow({ label: $r('app.string.about_version_code'), value: this.versionCodeText })
              SubItemDivider()
              AboutInfoRow({ label: $r('app.string.about_contact_email'), value: this.contactEmail })
            }
          }
          .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

          // 开源项目：代码仓 / 贡献者 / 许可证
          ListItem() {
            SettingItem({ title: $r('app.string.about_opensource_project') }) {
              SubItemButton({
                icon: $r('app.media.github_logo'),
                text: $r('app.string.about_repo'),
                description: $r('app.string.about_repo_desc')
              })
                .onClick(throttle((event) => {
                  startBrowsableAbility(this.appCtx, EXTERNAL_URLS.REPO_HOME);
                }, 1000))

              SubItemDivider()

              SubItemButton({
                symbol: $r('sys.symbol.doc_plaintext'),
                text: $r('app.string.about_license'),
                description: $r('app.string.about_license_desc')
              })
                .onClick(throttle((event) => {
                  startBrowsableAbility(this.appCtx, EXTERNAL_URLS.REPO_LICENSE);
                }, 1000))

              SubItemDivider()

              // 贡献者名单完整展示，不设行数上限
              SubItemButton({
                symbol: $r('sys.symbol.person_crop_circle_fill_1'),
                text: $r('app.string.about_contributors'),
                description: this.contributors,
                descriptionMaxLines: 0
              })
                .onClick(throttle((event) => {
                  startBrowsableAbility(this.appCtx, EXTERNAL_URLS.REPO_CONTRIBUTORS);
                }, 1000))
            }
          }
          .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

          // 使用到的开源软件
          ListItem() {
            SettingItem({ title: $r('app.string.setting_opensource_leg') }) {
              ForEach(this.ossEntries, (entry: OssEntry, index: number) => {
                SubItemButton({
                  symbol: $r('sys.symbol.link'),
                  text: entry.name,
                  description: entry.repoPath
                })
                  .onClick(throttle((event) => {
                    startBrowsableAbility(this.appCtx, entry.url);
                  }, 1000))
                if (index < this.ossEntries.length - 1) {
                  SubItemDivider()
                }
              }, (entry: OssEntry) => entry.repoPath)
            }
          }
          .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

          // 备案信息
          ListItem() {
            Row() {
              Hyperlink('https://beian.miit.gov.cn/', '粤ICP备2020075515号-2A')
                .height(10)
                .padding({ left: 10 })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
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
      .backgroundColor(this.embedded ? $r('app.color.window_background') :
        MaterialTheme.surfaceBackground($r('app.color.window_background')))
      .mode(NavigationMode.Stack)
      .bindToScrollable([this.sheetScroller])
      .hideBackButton(this.embedded)
      .titleMode(this.embedded ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.MODAL)
      .titleBar({
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
            scrollEffectType: this.scrollEffectStyle
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.setting_about'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }
}
