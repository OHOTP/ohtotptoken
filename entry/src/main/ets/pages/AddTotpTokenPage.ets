import { AppWindowInfo, HMACAlgorithm, otpType, ScanBarCode, showSnackBar, SnackBarNotifyType, TokenConfig } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SelectIconDialog } from 'uikit';
import { AddTokenActionButton, AddTokenHeader, ADD_TOKEN_PAGE_INSET, ADD_TOKEN_SECTION_PADDING, ADD_TOKEN_SECTION_RADIUS,
  AddTokenSectionTitle, AddTokenTextField } from '../components/AddTokenForm';
import { MaterialSurface } from '../components/MaterialSurface';
import { PageScaffold } from '../components/PageScaffold';
import { MaterialPolicy } from '../utils/MaterialPolicy';

export class AddTotpPageParams {
  initialUri: string = '';
}

@Entry
@Preview
@ComponentV2
export struct AddTotpTokenPage {
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Param pageParams: AddTotpPageParams = new AddTotpPageParams();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;

  @Local secret: string = '';
  @Local issuer: string = '';
  @Local accountName: string = '';
  @Local algorithm: HMACAlgorithm = 'SHA1';
  @Local digits: number = 6;
  @Local tokenType: otpType = otpType.TOTP;
  @Local period: number = 30;
  @Local counter: number = 0;
  @Local iconPath: string = '';
  @Local isSaving: boolean = false;
  @Local scanEffect: number = 0;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private scroller: Scroller = new Scroller();
  private iconDialog?: CustomDialogController;
  private readonly algorithms: HMACAlgorithm[] = ['SHA1', 'SHA224', 'SHA256', 'SHA384', 'SHA512', 'SM3', 'MD5'];

  aboutToAppear(): void {
    if (this.pageParams.initialUri !== '') {
      this.applyOtpAuthUri(this.pageParams.initialUri);
    }
  }

  private openIconPicker(): void {
    this.iconDialog = new CustomDialogController({
      builder: SelectIconDialog({
        issuer: this.issuer,
        currentIconPath: this.iconPath,
        confirm: (path: string) => {
          this.iconPath = path;
        }
      })
    });
    this.iconDialog.open();
  }

  private scanCode(): void {
    this.scanEffect++;
    ScanBarCode().then((code: string) => {
      this.applyOtpAuthUri(code);
    }).catch((err: BusinessError) => {
      if (err.code !== 1000500002) {
        showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      }
    });
  }

  private applyOtpAuthUri(uriValue: string): void {
    let otpUrl: url.URL;
    try {
      otpUrl = url.URL.parseURL(uriValue);
    } catch (error) {
      hilog.error(0, 'AddTotpTokenPage', `Invalid OTPAuth URL: ${JSON.stringify(error)}`);
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }
    if (otpUrl.protocol !== 'otpauth:') {
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }

    const host = otpUrl.host.toLowerCase();
    if (host === 'totp') {
      this.tokenType = otpType.TOTP;
    } else if (host === 'hotp') {
      this.tokenType = otpType.HOTP;
    } else {
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }

    const label = decodeURIComponent(otpUrl.pathname.replace(/^\//, ''));
    const separator = label.indexOf(':');
    if (separator >= 0) {
      this.issuer = label.slice(0, separator).trim();
      this.accountName = label.slice(separator + 1).trim();
    } else if (label !== '') {
      this.accountName = label;
    }

    const params = new url.URLParams(otpUrl.search);
    this.secret = params.get('secret') ?? this.secret;
    this.issuer = params.get('issuer') ?? this.issuer;
    this.period = this.parsePositiveInt(params.get('period'), 30);
    this.counter = this.parseNonNegativeInt(params.get('counter'), 0);
    this.digits = this.parsePositiveInt(params.get('digits'), 6);
    const algorithm = (params.get('algorithm') ?? 'SHA1').toUpperCase() as HMACAlgorithm;
    if (this.algorithms.includes(algorithm)) {
      this.algorithm = algorithm;
    }
  }

  private parsePositiveInt(value: string | null, fallback: number): number {
    const parsed = Number.parseInt(value ?? '');
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
  }

  private parseNonNegativeInt(value: string | null, fallback: number): number {
    const parsed = Number.parseInt(value ?? '');
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
  }

  private canSave(): boolean {
    return this.secret.trim() !== '' && this.issuer.trim() !== '' && this.accountName.trim() !== '' && !this.isSaving;
  }

  private async submit(): Promise<void> {
    if (!this.canSave()) {
      return;
    }
    this.isSaving = true;
    const conf = new TokenConfig(this.secret.trim(), this.tokenType, this.issuer.trim(), this.accountName.trim(),
      this.algorithm, this.period, this.digits, this.counter);
    conf.TokenIconPath = this.iconPath;
    const ok = await this.saveToken(conf);
    this.isSaving = false;
    if (ok) {
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
                title: $r('app.string.tab_token_add_key'),
                description: $r('app.string.add_totp_intro'),
                issuer: this.issuer,
                iconPath: this.iconPath,
                onIconClick: () => this.openIconPicker()
              })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 12 })

            ListItem() {
              AddTokenActionButton({
                text: $r('app.string.add_token_scan'),
                symbol: $r('sys.symbol.camera'),
                effectTrigger: this.scanEffect,
                action: () => this.scanCode()
              })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem() {
              AddTokenSectionTitle({ text: $r('app.string.add_token_account_section') })
            }
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
                .padding(ADD_TOKEN_SECTION_PADDING)
                .width('100%')
              }
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem() {
              AddTokenSectionTitle({ text: $r('app.string.add_token_advanced_section') })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 8 })

            ListItem() {
              MaterialSurface({ radius: ADD_TOKEN_SECTION_RADIUS, applyShadow: true }) {
                Column({ space: 16 }) {
                  Column({ space: 8 }) {
                    Text($r('app.string.add_token_type'))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    Row({ space: 24 }) {
                      Row({ space: 6 }) {
                        Radio({ value: 'totp', group: 'add_token_type' }).checked(this.tokenType === otpType.TOTP)
                          .onChange((checked: boolean) => { if (checked) this.tokenType = otpType.TOTP; })
                        Text('TOTP')
                      }
                      Row({ space: 6 }) {
                        Radio({ value: 'hotp', group: 'add_token_type' }).checked(this.tokenType === otpType.HOTP)
                          .onChange((checked: boolean) => { if (checked) this.tokenType = otpType.HOTP; })
                        Text('HOTP')
                      }
                    }
                  }
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  Column({ space: 8 }) {
                    Text($r('app.string.dialog_cfg_tk_alg'))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    Select([
                      { value: 'SHA1' },
                      { value: 'SHA224' },
                      { value: 'SHA256' },
                      { value: 'SHA384' },
                      { value: 'SHA512' },
                      { value: 'SM3' },
                      { value: 'MD5' }
                    ])
                      .selected(this.algorithms.indexOf(this.algorithm))
                      .value(this.algorithm)
                      .width('100%')
                      .onSelect((_: number, value: string) => this.algorithm = value as HMACAlgorithm)
                  }
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  Column({ space: 8 }) {
                    Text($r('app.string.dialog_cfg_tk_digits'))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    Row() {
                      ForEach([4, 6, 8], (value: number) => {
                        Row({ space: 4 }) {
                          Radio({ value: value.toString(), group: 'add_token_digits' }).checked(this.digits === value)
                            .onChange((checked: boolean) => { if (checked) this.digits = value; })
                          Text(value.toString())
                        }
                      })
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.SpaceAround)
                  }
                  Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                  if (this.tokenType === otpType.TOTP) {
                    Column({ space: 8 }) {
                      Row() {
                        Text($r('app.string.dialog_cfg_tk_timeout'))
                          .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                        Text(`${this.period}s`).fontSize(13).fontColor($r('sys.color.font_secondary'))
                      }
                      .width('100%').justifyContent(FlexAlign.SpaceBetween)
                      Slider({ min: 1, max: 60, value: this.period, step: 1, style: SliderStyle.InSet })
                        .width('100%')
                        .onChange((value: number) => this.period = Math.round(value))
                    }
                  } else {
                    AddTokenTextField({
                      label: $r('app.string.dialog_cfg_tk_counter'),
                      value: this.counter.toString(),
                      maxLength: 16,
                      onChange: (value: string) => this.counter = this.parseNonNegativeInt(value, 0)
                    })
                  }
                }
                .padding(ADD_TOKEN_SECTION_PADDING)
                .width('100%')
              }
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem().height(this.window.AvoidBottomHeight + 16)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(false)

          Column({ space: 6 }) {
            Text($r('app.string.add_token_required_hint'))
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
            AddTokenActionButton({
              text: this.isSaving ? $r('app.string.add_token_saving') : $r('app.string.add_token_save'),
              symbol: $r('sys.symbol.checkmark'),
              loading: this.isSaving,
              buttonEnabled: this.canSave(),
              action: () => this.submit()
            })
          }
          .width('100%')
          .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 10, bottom: 12 })
        }
        .width('100%')
        .height('100%')
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
            backIconStyle: { iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: { title: { mainTitle: $r('app.string.tab_token_add_key') } }
    })
    .bindToScrollable([this.scroller])
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
  }
}
