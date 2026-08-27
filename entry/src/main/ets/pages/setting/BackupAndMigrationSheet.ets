import { TokenConfig, otpType, dialogSystemMaterial } from 'common';
import { MaterialPolicy } from '../../utils/MaterialPolicy';

import { BusinessError } from '@kit.BasicServicesKit';
import { bundleManager,common } from '@kit.AbilityKit';
import { convertToken2URI, generateFileNameWithDate } from 'common'
import { showSnackBar, SnackBarNotifyType } from 'common';
import { SubItemButton } from '../../components/SubItemButton';
import { SubItemToggle } from '../../components/SubItemToggle';
import { SettingItem } from '../../components/SettingItem';
import { EncryptionPassWordDialog } from '../../dialogs/EncryptionPassWordDialog';
import { restoreFromBackup, saveBackupToFile, TokenBackup } from 'common';
import { showSaveFilePicker, showSelectFilePicker, writeFileContent } from 'common';
import { SubItemDivider } from '../../components/SubItemDivider';
import { LengthMetrics, AppStorageV2 } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreference, SettingValue, PREF_KEYS, ROUTE_NAMES } from 'common';
import { throttle } from 'common';
import { ShowCloudSyncDetailsPage } from '../ShowCloudSyncDetailsPage';
import { ShowCloudBackupHistoryPage } from '../ShowCloudBackupHistoryPage';
import { HuaweiAccountManager } from 'common';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { TokenImporterRegistry, TokenImporter } from 'common';
import { URIConfigDialog } from '../../dialogs/URIConfigDialog';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';
import { AppWindowInfo } from 'common';

@Preview
@ComponentV2
export struct BackupAndMigrationSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param Tokens: Array<TokenConfig> = [];
  @Require @Param scrollEffectStyle: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Event backupReload: (conf: Array<TokenConfig>) => void = () => {};

  @Local versionCode?: number;
  @Local cloudBackupEnabled: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local importers: TokenImporter[] = [];
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();

  // 导入时选择的备份文件路径
  private backup_select_uri: string = '';
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  // URI 导入对话框控制器（组件内持有，避免非组件上下文问题）
  private uriDialogController: CustomDialogController | null = null;

  aboutToAppear(): void {
    let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
    this.versionCode = bundleInfo?.versionCode;
    this.cloudBackupEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    // 初始化导入器注册表
    const registry = TokenImporterRegistry.getInstance();
    registry.init();
    this.importers = registry.getAll();
  }

  //region 加密导入导出
  // 加密导出：设置备份密码
  private password_export_dialog: CustomDialogController | null = new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: EncryptionPassWordDialog({
      title: $r('app.string.dialog_backup_password_set'),
      showConfirmPassword: true,
      cancel: () => {},
      confirm: (password: string) => {
        // NFC 外部令牌仅会话存在、不持久化，导出前统一过滤（不含空 secret 伪 TOTP）
        const exportable = this.Tokens.filter(t => t.TokenType !== otpType.NFC_external);
        if (exportable.length === 0) {
          showSnackBar($r('app.string.toast_no_exportable_tokens'), SnackBarNotifyType.WARNING);
          return;
        }
        showSaveFilePicker([`totp_backup_${generateFileNameWithDate()}.bak`], ['BAK|.bak']).then((uris) => {
          const backup: TokenBackup = new TokenBackup(this.versionCode ?? 0, exportable);
          if (uris[0] !== undefined && uris[0] !== '') {
            saveBackupToFile(uris[0], backup, true, password).then(() => {
              showSnackBar($r('app.string.toast_backup_success'), SnackBarNotifyType.SUCCESS);
            }).catch((reason: BusinessError) => {
              showSnackBar(reason.message, SnackBarNotifyType.ERROR);
            });
          }
        });
      },
    }),
    cancel: () => {},
    autoCancel: true,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'BackupAndMigrationSheet', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'BackupAndMigrationSheet', "dialog onWillDismiss")
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
      }
    },
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: $r('sys.float.ohos_id_corner_radius_panel'),
  })

  // 加密导入：输入备份密码
  private password_import_dialog: CustomDialogController | null = new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: EncryptionPassWordDialog({
      title: $r('app.string.dialog_backup_password'),
      cancel: () => {},
      confirm: (password: string) => {
        restoreFromBackup(this.backup_select_uri, true, password).then((backup) => {
          this.backupReload(backup.configs);
        }).catch((reason: BusinessError) => {
          showSnackBar(reason.message, SnackBarNotifyType.ERROR);
        });
      },
    }),
    cancel: () => {},
    autoCancel: true,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'BackupAndMigrationSheet', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'BackupAndMigrationSheet', "dialog onWillDismiss")
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
      }
    },
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: $r('sys.float.ohos_id_corner_radius_panel'),
  })

  async callFilePickerSaveMigrationFile(): Promise<void> {
    this.getUIContext().showAlertDialog(
      {
        title: $r('app.string.setting_migration_output'),
        subtitle: $r('app.string.setting_migration_output_des'),
        message: $r('app.string.setting_migration_output_msg'),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        gridCount: 4,
        buttonDirection: DialogButtonDirection.HORIZONTAL,
        buttons: [
          {
            value: $r('app.string.setting_migration_confirm'),
            action: () => {
              showSaveFilePicker([`totp_migration_${generateFileNameWithDate()}.txt`], ['TEXT|.txt']).then((uris) => {
                // NFC 外部令牌不持久化，迁移导出同样过滤
                const exportable = this.Tokens.filter(t => t.TokenType !== otpType.NFC_external);
                if (exportable.length === 0) {
                  showSnackBar($r('app.string.toast_no_exportable_tokens'), SnackBarNotifyType.WARNING);
                  return;
                }
                let migration_content: string = '';
                exportable.forEach((token) => {
                  migration_content += convertToken2URI(token) + "\n";
                })
                if (uris[0] !== undefined && uris[0] !== '') {
                  writeFileContent(uris[0], migration_content);
                }
              });
            }
          },
          {
            value: $r('app.string.setting_backup_cancel'),
            enabled: true,
            action: () => {
              hilog.info(0, 'BackupAndMigrationSheet', 'Callback when button3 is clicked')
            }
          },
        ],
        cancel: () => {
          hilog.info(0, 'BackupAndMigrationSheet', 'Closed callbacks')
        },
        onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
          hilog.info(0, 'BackupAndMigrationSheet', "reason=" + JSON.stringify(dismissDialogAction.reason))
          hilog.info(0, 'BackupAndMigrationSheet', "dialog onWillDismiss")
          if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
            dismissDialogAction.dismiss()
          }
          if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
            dismissDialogAction.dismiss()
          }
        }
      }
    );
  }

  async callFilePickerSaveFile(): Promise<void> {
    this.getUIContext().showAlertDialog(
      {
        title: $r('app.string.setting_backup_output'),
        message: $r('app.string.setting_backup_output_msg'),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        gridCount: 4,
        buttonDirection: DialogButtonDirection.HORIZONTAL,
        buttons: [
          {
            value: $r('app.string.setting_backup_type_enc'),
            action: () => {
              this.password_export_dialog?.open();
            }
          },
          {
            value: $r('app.string.setting_backup_type_default'),
            action: () => {
              // NFC 外部令牌仅会话存在、不持久化，导出前统一过滤
              const exportable = this.Tokens.filter(t => t.TokenType !== otpType.NFC_external);
              if (exportable.length === 0) {
                showSnackBar($r('app.string.toast_no_exportable_tokens'), SnackBarNotifyType.WARNING);
                return;
              }
              showSaveFilePicker([`totp_backup_${generateFileNameWithDate()}.json`], ['JSON|.json']).then((uris) => {
                const backup: TokenBackup = new TokenBackup(this.versionCode, exportable);
                if (uris[0] !== undefined && uris[0] !== '') {
                  saveBackupToFile(uris[0], backup).then(() => {
                    showSnackBar($r('app.string.toast_backup_success'), SnackBarNotifyType.SUCCESS);
                  }).catch((reason: BusinessError) => {
                    showSnackBar(reason.message, SnackBarNotifyType.ERROR);
                  });
                }
              });
            }
          },
          {
            value: $r('app.string.setting_backup_cancel'),
            enabled: true,
            action: () => {
              hilog.info(0, 'BackupAndMigrationSheet', 'Callback when button3 is clicked')
            }
          },
        ],
        cancel: () => {
          hilog.info(0, 'BackupAndMigrationSheet', 'Closed callbacks')
        },
        onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
          hilog.info(0, 'BackupAndMigrationSheet', "reason=" + JSON.stringify(dismissDialogAction.reason))
          hilog.info(0, 'BackupAndMigrationSheet', "dialog onWillDismiss")
          if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
            dismissDialogAction.dismiss()
          }
          if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
            dismissDialogAction.dismiss()
          }
        }
      }
    );
  }

  async callFilePickerSelectFile(): Promise<void> {
    showSelectFilePicker(1, ['JSON|.json', 'BAK|.bak']).then((uris) => {
      this.backup_select_uri = uris[0];
      if (this.backup_select_uri.endsWith('.bak')) {
        //后缀bak为加密包 唤醒加密导入弹窗
        this.password_import_dialog?.open();
      } else {
        restoreFromBackup(uris[0]).then((backup) => {
          this.backupReload(backup.configs);
        }).catch((reason: BusinessError) => {
          showSnackBar(reason.message, SnackBarNotifyType.ERROR);
        });
      }
    });
  }

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.ShowCloudSyncDetailsPage) {
      ShowCloudSyncDetailsPage({ scrollEffectType: this.scrollEffectStyle })
    } else if (name === ROUTE_NAMES.ShowCloudBackupHistoryPage) {
      ShowCloudBackupHistoryPage({ scrollEffectType: this.scrollEffectStyle })
    }
  }

  //endregion
  // 在自定义组件即将析构销毁时将dialogController置空
  aboutToDisappear() {
    this.password_export_dialog = null // 将dialogController置空
    this.password_import_dialog = null
    this.uriDialogController = null
  }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column({ space: LengthMetrics.vp(12).value }) {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: $r('app.string.setting_backup') }) {
                SubItemButton({
                  symbol: $r('sys.symbol.save'),
                  text: $r('app.string.setting_backup_export')
                })
                  .onClick(() => {
                    this.callFilePickerSaveFile()
                  })

                SubItemDivider()

                SubItemButton({
                  symbol: $r('sys.symbol.folder'),
                  text: $r('app.string.setting_backup_import')
                })
                  .onClick(() => {
                    this.callFilePickerSelectFile()
                  })

                SubItemDivider()

                SubItemButton({
                  symbol: $r('sys.symbol.briefcase'),
                  text: $r('app.string.setting_migration')
                })
                  .onClick(() => {
                    this.callFilePickerSaveMigrationFile()
                  })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            // 从其他验证器导入
            if (this.importers.length > 0) {
              ListItem() {
                SettingItem({ title: $r('app.string.setting_import_from_other_apps') }) {
                  ForEach(this.importers, (importer: TokenImporter, index: number) => {
                    if (index > 0) {
                      SubItemDivider()
                    }
                    SubItemButton({
                      symbol: importer.icon,
                      text: importer.name,
                      description: importer.description
                    })
                      .onClick(() => {
                        if (importer.id === 'uri') {
                          // URI 导入需要组件上下文，在此创建 CustomDialogController
                          if (!this.uriDialogController) {
                            this.uriDialogController = new CustomDialogController({
                              systemMaterial: dialogSystemMaterial(),
                              builder: URIConfigDialog({
                                confirm: async (tokens: Array<TokenConfig>): Promise<boolean> => {
                                  this.backupReload(tokens);
                                  return true;
                                }
                              }),
                              autoCancel: true,
                              customStyle: false,
                              cornerRadius: 10,
                            });
                          }
                          this.uriDialogController.open();
                        } else {
                          // 其他导入器（如 TwoFAImporter）使用各自的 import() 方法
                          importer.import(this.getUIContext(), (tokens: Array<TokenConfig>) => {
                            this.backupReload(tokens);
                          });
                        }
                      })
                  }, (importer: TokenImporter) => importer.id)
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
            }

            ListItem() {
              SettingItem({ title: $r('app.string.data_rdb_cloud_sync') }) {
                SubItemToggle({
                  icon: $r('sys.symbol.icloud'),
                  title: $r('app.string.data_rdb_cloud_sync'),
                  isOn: this.cloudBackupEnabled as boolean,
                  disable: !this.isHuaweiLoggedIn,
                  description: this.isHuaweiLoggedIn
                    ? $r('app.string.data_rdb_cloud_sync_des')
                    : $r('app.string.cloud_backup_login_required'),
                  onChange: (IsOn: boolean) => {
                    if (IsOn) {
                      if (!HuaweiAccountManager.getInstance().userLogin) {
                        this.cloudBackupEnabled = false;
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
                        this.showHuaweiAccountRequiredDialog();
                        return;
                      }
                    }
                    this.cloudBackupEnabled = IsOn;
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemButton({
                  symbol: $r('sys.symbol.info_circle'),
                  text: $r('app.string.data_huawei_cloud_sync_details'),
                  description: this.isHuaweiLoggedIn ? '' : $r('app.string.cloud_backup_login_required'),
                  descriptionColor: $r('sys.color.ohos_id_color_warning'),
                })
                  .onClick(throttle((event) => {
                    if (!this.isHuaweiLoggedIn) {
                      this.showHuaweiAccountRequiredDialog();
                      return;
                    }
                    this.pageInfos.pushPathByName(ROUTE_NAMES.ShowCloudSyncDetailsPage, null);
                  }, 1000))
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
          }
          .clip(false)
          .width('100%')
          .height('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 滚动末端抬高底部避让区(导航条/小横条)，避免最后一项被遮挡
          .contentEndOffset(this.window.AvoidBottomHeight)
          // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
          .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
        }
        .width('100%')
        .height('100%')
        // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
        .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
      }
      .width('100%')
      .height('100%')
      // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
      .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
      .mode(NavigationMode.Stack)
      .navDestination(this.navDestinationBuilder)
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
            mainTitle: $r('app.string.setting_backup'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }

  private showHuaweiAccountRequiredDialog(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cloud_sync_require_huawei_account_title'),
      message: $r('app.string.cloud_sync_require_huawei_account_msg'),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {}
        },
      ],
      cancel: () => {},
    });
  }
}
