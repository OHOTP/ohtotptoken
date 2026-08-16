import { AppWindowInfo, base32Decode, base32Encode, otpType, ScanBarCode, showSnackBar, SnackBarNotifyType,
  stringToIntArray, TokenConfig } from 'common';
import { common } from '@kit.AbilityKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { buffer, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SelectIconDialog } from 'uikit';
import { AddTokenActionButton, AddTokenHeader, ADD_TOKEN_BOTTOM_ACTION_INSET, ADD_TOKEN_PAGE_INSET,
  ADD_TOKEN_SECTION_PADDING, ADD_TOKEN_SECTION_RADIUS,
  AddTokenSectionTitle, AddTokenTextField } from '../components/AddTokenForm';
import { MaterialSurface } from '../components/MaterialSurface';
import { PageScaffold } from '../components/PageScaffold';
import { MaterialPolicy } from '../utils/MaterialPolicy';

class FortiServerError {
  error_code?: string;
  error_message?: string;
}
class FortiServerData {
  seed?: string;
  issuer?: string;
  error?: FortiServerError;
}
class FortiServerResponse {
  d: FortiServerData = {};
}

@Entry
@Preview
@ComponentV2
export struct AddFortiTokenPage {
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;

  @Local activationCode: string = '';
  @Local deviceId: string = '';
  @Local secret: string = '';
  @Local accountName: string = '';
  @Local iconPath: string = '';
  @Local isRequesting: boolean = false;
  @Local isSaving: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private scroller: Scroller = new Scroller();
  private iconDialog?: CustomDialogController;
  private filesDir: string = (AppStorage.get('appContext') as common.UIAbilityContext).filesDir;

  aboutToAppear(): void {
    if (this.deviceId === '') {
      this.generateDeviceId();
    }
  }

  private generateDeviceId(): void {
    this.deviceId = buffer.from(util.generateRandomBinaryUUID()).toString('hex').slice(0, 16);
  }

  private openIconPicker(): void {
    this.iconDialog = new CustomDialogController({
      builder: SelectIconDialog({
        issuer: 'Forti',
        currentIconPath: this.iconPath,
        confirm: (path: string) => this.iconPath = path
      })
    });
    this.iconDialog.open();
  }

  private scanCode(): void {
    ScanBarCode().then((code: string) => this.activationCode = code.trim()).catch((err: BusinessError) => {
      if (err.code !== 1000500002) {
        showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      }
    });
  }

  private decryptSeed(seed: string): void {
    const aesDecoder = cryptoFramework.createCipher('AES128|CBC|NoPadding');
    const aesIv: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: stringToIntArray('fortitokenmobile') }
    };
    const symKeyBlob: cryptoFramework.DataBlob = { data: stringToIntArray(this.deviceId) };
    const aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const aesKey = aesGenerator.convertKeySync(symKeyBlob);
    aesDecoder.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, aesKey, aesIv);
    try {
      const decodedSeed = new util.Base64Helper().decodeSync(seed);
      aesDecoder.doFinal({ data: decodedSeed }).then((decryptData: cryptoFramework.DataBlob) => {
        const decodeHex = new util.TextDecoder().decodeToString(decryptData.data.slice(0, 40));
        this.secret = base32Encode(buffer.from(decodeHex, 'hex').buffer as Uint8Array);
        this.isRequesting = false;
      }).catch((error: BusinessError) => {
        this.isRequesting = false;
        showSnackBar(`Error: ${error.message}`, SnackBarNotifyType.ERROR);
      });
    } catch (error) {
      this.isRequesting = false;
      showSnackBar(`Error: ${JSON.stringify(error)}`, SnackBarNotifyType.ERROR);
    }
  }

  private requestKey(): void {
    if (this.activationCode.length !== 16) {
      showSnackBar($r('app.string.toast_wrong_forti_token'), SnackBarNotifyType.WARNING);
      return;
    }
    if (this.deviceId.length !== 16) {
      showSnackBar($r('app.string.toast_wrong_device_id'), SnackBarNotifyType.WARNING);
      return;
    }
    let rawToken = base32Decode(this.activationCode);
    if (rawToken[0] !== 0x21) {
      showSnackBar($r('app.string.toast_wrong_user_token'), SnackBarNotifyType.WARNING);
      return;
    }

    this.isRequesting = true;
    rawToken = rawToken.slice(2);
    const rawTokenHex = buffer.from(rawToken).toString('hex');
    const request = http.createHttp();
    request.request('https://globalftm.fortinet.net/SoftToken/Provisioning.asmx/Mobile', {
      method: http.RequestMethod.POST,
      extraData: {
        'd': {
          'mobile_id': this.deviceId,
          '__type': 'SoftToken.MobileProvisionRequest',
          'token_activation_code': rawTokenHex
        }
      },
      header: { 'Accept': 'application/json' },
      readTimeout: 60000,
      connectTimeout: 60000,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      usingProxy: false,
      clientCert: {
        certPath: this.filesDir + '/fmt.ks',
        keyPath: '',
        certType: http.CertType.P12,
        keyPassword: 'Terran2023'
      }
    }, (err: BusinessError, data: http.HttpResponse) => {
      if (err) {
        this.isRequesting = false;
        hilog.error(err.code, 'AddFortiTokenPage', `request failed: ${err.message}`);
        request.destroy();
        return;
      }
      try {
        const response = JSON.parse(data.result.toString()) as FortiServerResponse;
        if (response.d.error !== undefined) {
          this.isRequesting = false;
          showSnackBar(`${response.d.error.error_message}, code ${response.d.error.error_code}`,
            SnackBarNotifyType.ERROR);
        } else if (response.d.seed !== undefined) {
          this.accountName = response.d.issuer ?? this.accountName;
          this.decryptSeed(response.d.seed);
        } else {
          this.isRequesting = false;
        }
      } catch (error) {
        this.isRequesting = false;
        showSnackBar(`Error: ${JSON.stringify(error)}`, SnackBarNotifyType.ERROR);
      }
      request.destroy();
    });
  }

  private canSave(): boolean {
    return this.activationCode.trim() !== '' && this.deviceId.trim() !== '' && this.secret.trim() !== '' &&
      this.accountName.trim() !== '' && !this.isSaving && !this.isRequesting;
  }

  private async submit(): Promise<void> {
    if (!this.canSave()) return;
    this.isSaving = true;
    const conf = new TokenConfig(this.secret.trim(), otpType.Forti, 'Forti', this.accountName.trim(), 'SHA1', 60, 6);
    conf.FortiToken = this.activationCode.trim();
    conf.FortiDevID = this.deviceId.trim();
    conf.TokenIconPath = this.iconPath;
    const ok = await this.saveToken(conf);
    this.isSaving = false;
    if (ok) this.pageInfos?.pop();
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        Column() {
          List({ space: 12, scroller: this.scroller }) {
            ListItem() {
              AddTokenHeader({
                issuer: 'Forti',
                iconPath: this.iconPath,
                onIconClick: () => this.openIconPicker()
              })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 12 })


            ListItem() { AddTokenSectionTitle({ text: $r('app.string.add_token_activation_section') }) }
              .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 8 })

            ListItem() {
              MaterialSurface({ radius: ADD_TOKEN_SECTION_RADIUS, applyShadow: true }) {
                Column({ space: 14 }) {
                  AddTokenTextField({
                    label: $r('app.string.dialog_cfg_forti_token'),
                    value: this.activationCode,
                    maxLength: 32,
                    onChange: (value: string) => this.activationCode = value.trim()
                  })
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  Column({ space: 8 }) {
                    AddTokenTextField({
                      label: $r('app.string.dialog_cfg_forti_dev_id'),
                      value: this.deviceId,
                      helper: $r('app.string.warn_forti_dev_id_popup'),
                      maxLength: 16,
                      onChange: (value: string) => this.deviceId = value.trim()
                    })
                    AddTokenActionButton({
                      text: $r('app.string.add_forti_regenerate_device_id'),
                      action: () => this.generateDeviceId()
                    })
                  }
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  AddTokenActionButton({
                    text: $r('app.string.dialog_cfg_forti_btn_gen_key'),
                    loading: this.isRequesting,
                    buttonEnabled: !this.isRequesting,
                    action: () => this.requestKey()
                  })
                }
                .padding(ADD_TOKEN_SECTION_PADDING).width('100%')
              }
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
    .titleMode(HdsNavDestinationTitleMode.MODAL)
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
        title: { mainTitle: $r('app.string.tab_token_add_forti_key') },
        menu: {
          value: [{
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
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
  }
}
