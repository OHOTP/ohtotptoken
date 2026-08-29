import { AppWindowInfo, EVENT_NAMES, maFile, otpType, readFileContent, ROUTE_NAMES, ScanBarCode,
  showSelectFilePicker, showSnackBar, SnackBarNotifyType, TokenConfig } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { JSON, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

import { AddTokenActionButton, AddTokenHeader, AddTokenPageParams, ADD_TOKEN_BOTTOM_ACTION_INSET, ADD_TOKEN_PAGE_INSET,
  ADD_TOKEN_SECTION_PADDING, ADD_TOKEN_SECTION_RADIUS,
  AddTokenSectionTitle, AddTokenTextField } from '../components/AddTokenForm';
import { MaterialSurface } from '../components/MaterialSurface';
import { PageScaffold } from '../components/PageScaffold';
import { MaterialPolicy } from '../utils/MaterialPolicy';
import { IconPickerPageParams } from './IconPickerPage';
import { ResponsiveTokenEditStore, TokenSwitchPerf, TokenSwitchTrace } from '../utils/TokenSwitchPerf';

@Entry
@Preview
@ComponentV2
export struct AddSteamTokenPage {
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param pageParams: AddTokenPageParams = new AddTokenPageParams();
  @Event onExitFullScreen: () => void = () => {};
  @Event onBackToPlaceholder: () => void = () => {};

  @Local secret: string = '';
  @Local issuer: string = 'Steam';
  @Local accountName: string = '';
  @Local iconPath: string = '';
  @Local isSaving: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private scroller: Scroller = new Scroller();
  private activeEditConfig?: TokenConfig = undefined;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onResponsiveTokenSelectedHandler: (config: TokenConfig, trace: TokenSwitchTrace) => void = () => {};

  private steamMaFile: maFile | undefined = undefined;

  private applyEditConfig(editConfig: TokenConfig): void {
    this.activeEditConfig = editConfig;
    this.secret = editConfig.TokenSecret;
    this.issuer = editConfig.TokenIssuer;
    this.accountName = editConfig.TokenName;
    this.iconPath = editConfig.TokenIconPath ?? '';
    this.steamMaFile = editConfig.SteamMaFile;
  }

  aboutToAppear(): void {
    const responsiveStore = ResponsiveTokenEditStore.getInstance();
    const switchTrace = this.pageParams.responsiveEdit ? responsiveStore.currentTrace() : this.pageParams.switchTrace;
    TokenSwitchPerf.mark(switchTrace, 'aboutToAppear');
    this.onResponsiveTokenSelectedHandler = (config: TokenConfig, trace: TokenSwitchTrace): void => {
      this.applyEditConfig(config);
      TokenSwitchPerf.reusedReady(trace, this.getUIContext());
    };
    if (this.pageParams.responsiveEdit) {
      this.appCtx.eventHub?.on(EVENT_NAMES.RESPONSIVE_TOKEN_SELECTION_CHANGED,
        this.onResponsiveTokenSelectedHandler);
    }
    const editConfig = this.pageParams.responsiveEdit ?
      (responsiveStore.currentConfig() ?? this.pageParams.editConfig) : this.pageParams.editConfig;
    if (editConfig !== undefined) {
      this.applyEditConfig(editConfig);
    }
  }

  aboutToDisappear(): void {
    if (this.pageParams.responsiveEdit) {
      this.appCtx.eventHub?.off(EVENT_NAMES.RESPONSIVE_TOKEN_SELECTION_CHANGED,
        this.onResponsiveTokenSelectedHandler);
    }
  }

  private openIconPicker(): void {
    this.pageInfos?.pushPathByName(ROUTE_NAMES.IconPickerPage,
      new IconPickerPageParams(this.issuer, this.iconPath, (path: string) => this.iconPath = path));
  }

  private scanCode(): void {
    ScanBarCode().then((code: string) => this.applyOtpAuthUri(code)).catch((err: BusinessError) => {
      if (err.code !== 1000500002) {
        showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      }
    });
  }

  private importMaFile(): void {
    showSelectFilePicker(1, ['maFile|.mafile']).then((uris: string[]) => {
      if (uris.length === 0) return;
      return readFileContent(uris[0]).then((content: string) => {
        this.steamMaFile = JSON.parse(content) as maFile;
        this.applyOtpAuthUri(this.steamMaFile?.uri ?? '');
      });
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'AddSteamTokenPage', `maFile import failed: ${error.message}`);
      showSnackBar($r('app.string.add_steam_import_failed'), SnackBarNotifyType.ERROR);
    });
  }

  private applyOtpAuthUri(uriValue: string): void {
    let otpUrl: url.URL;
    try {
      otpUrl = url.URL.parseURL(uriValue);
    } catch (error) {
      hilog.error(0, 'AddSteamTokenPage', `Invalid OTPAuth URL: ${JSON.stringify(error)}`);
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }
    if (otpUrl.protocol !== 'otpauth:' || otpUrl.host.toLowerCase() !== 'totp') {
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }

    const label = decodeURIComponent(otpUrl.pathname.replace(/^\//, ''));
    const separator = label.indexOf(':');
    if (separator >= 0) {
      this.issuer = label.slice(0, separator).trim() || 'Steam';
      this.accountName = label.slice(separator + 1).trim();
    } else if (label !== '') {
      this.accountName = label;
    }
    const params = new url.URLParams(otpUrl.search);
    this.secret = params.get('secret') ?? this.secret;
    this.issuer = params.get('issuer') ?? this.issuer;
  }

  private canSave(): boolean {
    return this.secret.trim() !== '' && this.issuer.trim() !== '' && this.accountName.trim() !== '' && !this.isSaving;
  }

  private async submit(): Promise<void> {
    if (!this.canSave()) return;
    this.isSaving = true;
    const conf = new TokenConfig(this.secret.trim(), otpType.Steam, this.issuer.trim(), this.accountName.trim(),
      'SHA1', 30, 10, 0, this.activeEditConfig?.RankScore ?? 0);
    if (this.activeEditConfig !== undefined) {
      conf.TokenUUID = this.activeEditConfig.TokenUUID;
    }
    conf.TokenIconPath = this.iconPath;
    conf.SteamMaFile = this.steamMaFile;
    const ok = await this.saveToken(conf);
    this.isSaving = false;
    if (ok && !(this.window.AllowSplit && this.pageParams.editConfig !== undefined)) {
      this.pageInfos?.pop();
    }
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        Column() {
          List({ space: 12, scroller: this.scroller }) {
            ListItem() {
              AddTokenHeader({
                issuer: this.issuer,
                iconPath: this.iconPath,
                onIconClick: () => this.openIconPicker()
              })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 12 })

            ListItem() {
              Row() {
                AddTokenActionButton({
                  text: $r('app.string.dialog_cfg_steam_from_mafile'),
                  action: () => this.importMaFile()
                })
                .layoutWeight(1)
              }
              .width('100%')
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem() { AddTokenSectionTitle({ text: $r('app.string.add_token_account_section') }) }
              .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 8 })

            ListItem() {
              MaterialSurface({ radius: ADD_TOKEN_SECTION_RADIUS, applyShadow: true }) {
                Column({ space: 14 }) {
                  AddTokenTextField({
                    label: $r('app.string.dialog_cfg_tk_secret'),
                    value: this.secret,
                    inputType: InputType.Password,
                    onChange: (value: string) => this.secret = value
                  })
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  AddTokenTextField({
                    label: $r('app.string.dialog_cfg_tk_issuer'),
                    value: this.issuer,
                    onChange: (value: string) => this.issuer = value
                  })
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  AddTokenTextField({
                    label: $r('app.string.dialog_cfg_tk_name'),
                    value: this.accountName,
                    onChange: (value: string) => this.accountName = value
                  })
                }
                .padding(ADD_TOKEN_SECTION_PADDING).width('100%')
              }
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })
            ListItem().height(this.window.AvoidBottomHeight + 16)
          }
          .layoutWeight(1).width('100%').scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(false)

          AddTokenActionButton({
            text: this.isSaving ? $r('app.string.add_token_saving') : $r('app.string.add_token_save'),
            loading: this.isSaving,
            buttonEnabled: this.canSave(),
            action: () => this.submit()
          })
          .width('100%')
          .padding({
            left: ADD_TOKEN_PAGE_INSET,
            right: ADD_TOKEN_PAGE_INSET,
            top: 10,
            bottom: ADD_TOKEN_BOTTOM_ACTION_INSET
          })
        }
        .width('100%').height('100%')
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .padding({ top: this.window.IsPc ? 8 : 0 })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            backIconStyle: { iconColor: $r('sys.color.icon_primary') },
            menuStyle: { iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: {
        title: { mainTitle: this.pageParams.editConfig === undefined ?
          $r('app.string.tab_token_add_stream_key') : $r('app.string.edit_token_title') },
        menu: {
          value: this.window.IsPc ? [] : [{
            content: {
              label: $r('app.string.add_token_scan'),
              icon: $r('sys.symbol.qrcode'),
              isEnabled: true,
              action: () => this.scanCode()
            }
          }]
        }
      }
    })
    .bindToScrollable([this.scroller])
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      const switchTrace = this.pageParams.responsiveEdit ?
        ResponsiveTokenEditStore.getInstance().currentTrace() : this.pageParams.switchTrace;
      TokenSwitchPerf.routeReady(switchTrace, this.getUIContext());
    })
    .onShown(() => TokenSwitchPerf.mark(this.pageParams.responsiveEdit ?
      ResponsiveTokenEditStore.getInstance().currentTrace() : this.pageParams.switchTrace, 'shown'))
    .onWillDisappear(() => {
      TokenSwitchPerf.mark(this.pageParams.switchTrace, 'willDisappear');
      this.onExitFullScreen();
    })
    .onBackPressed(() => {
      if (this.window.AllowSplit && this.pageParams.editConfig !== undefined) {
        this.onBackToPlaceholder();
        return true;
      }
      return false;
    })
  }
}
