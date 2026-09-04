import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { otpType, TokenConfig } from 'common';
import { convertToken2URI, copyText, generateOTP } from 'common';
import { SteamUtils } from 'common';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS, SettingHiddenTokenType } from 'common';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { QRCodeDialog } from 'uikit';
import { AppWindowInfo } from 'common';
import { TokenStore } from 'common';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { AppFonts } from 'common';
import { ArcTokenIcon } from './ArcTokenIcon';
import { hilog } from '@kit.PerformanceAnalysisKit';

let current_token_hide_map: Map<string, boolean> = new Map();
let tkStore = TokenStore.getInstance();

@Preview
@ComponentV2
export struct ArcTokenItem {
  @Require @Param Config: TokenConfig = new TokenConfig();
  @Event Update: (conf: TokenConfig) => Promise<boolean> = async () => false;

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local TokenNumber: string = '000000';
  @Local TokenNumberNext: string = '000000';
  @Local TokenCounter: string = '0';
  @Local TokenLeftPeriod: number = 0;
  @Local btn_hotp_clicked: number = 0;
  @Local TokenHide: boolean = current_token_hide_map[this.Config.TokenUUID] ?? true;

  @Local menu_icon_trash: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash')).fontSize('22vp').fontColor([Color.Red]);
  @Local menu_icon_qrcode: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.qrcode')).fontSize('22vp');
  @Local menu_icon_copy: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.doc_text_on_doc_text')).fontSize('22vp');

  private token_steps: number = 0;
  // 使用 AppStorage 获取 context，避免在 aboutToAppear（build 之前）调用 getUIContext()
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTimestampChangedHandler: (timestamp: number, force: boolean) => void = () => {};

  @Computed
  get is_dark_mode() {
    return this.window.ColorMode == ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  @Computed
  get token_color_normal() {
    return this.is_dark_mode ?
    this.token_preference.app_appearance_token_color_dark : this.token_preference.app_appearance_token_color;
  }

  @Computed
  get token_color_expiring() {
    return this.is_dark_mode ?
    this.token_preference.app_appearance_token_next_color_dark : this.token_preference.app_appearance_token_next_color;
  }

  @Computed
  get hotp_next_btn_color() {
    return this.is_dark_mode ?
      this.token_preference.app_appearance_token_counter_dark_color_end :
      this.token_preference.app_appearance_token_counter_dark_color_end;
  }

  @Computed
  get token_color_change_threshold() {
    return this.token_preference.app_appearance_token_counter_next_margin;
  }

  @Computed
  get token_progress_color_normal(): LinearGradient {
    return new LinearGradient(
      [
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_dark_color_start :
          this.token_preference.app_appearance_token_counter_light_color_start,
          offset: 0
        },
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_dark_color_end :
          this.token_preference.app_appearance_token_counter_light_color_end,
          offset: 1
        },
      ]);
  }

  @Computed
  get token_progress_color_near_next(): LinearGradient {
    return new LinearGradient(
      [
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_next_dark_color_start :
          this.token_preference.app_appearance_token_counter_next_light_color_start,
          offset: 0
        },
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_next_dark_color_end :
          this.token_preference.app_appearance_token_counter_next_light_color_end,
          offset: 1
        },
      ]);
  }

  aboutToAppear(): void {
    this.onTimestampChangedHandler = (timestamp: number, force: boolean) => this.onTimestampChanged(timestamp, force);
    this.appCtx.eventHub?.on(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
    this.updateToken();
  }

  // 清理事件监听，防止组件销毁后监听器泄漏
  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
  }

  onTimestampChanged(timestamp: number, force: boolean): void {
    if (this.Config.TokenType !== otpType.HOTP) {
      this.token_steps = Math.floor(timestamp / this.Config.TokenPeriod);
      this.TokenLeftPeriod = this.Config.TokenPeriod - timestamp % this.Config.TokenPeriod;
      if (this.TokenLeftPeriod == this.Config.TokenPeriod || force) {
        this.updateTOTPToken();
      }
    }
  }

  updateToken() {
    if (this.Config === undefined) {
      return;
    }
    if (this.Config.TokenType == otpType.HOTP) {
      this.updateHOTPToken();
    } else {
      const timestamp = Math.floor(systemDateTime.getTime() / 1000);
      this.onTimestampChanged(timestamp, true);
    }
  }

  updateHOTPToken() {
    this.TokenCounter = this.Config.TokenCounter.toString();
    this.TokenNumber = generateOTP(this.Config, this.Config.TokenCounter).toString().padStart(this.Config.TokenDigits, '0');
    this.TokenNumberNext = generateOTP(this.Config, this.Config.TokenCounter + 1).toString().padStart(this.Config.TokenDigits, '0');
  }

  updateTOTPToken() {
    let int_code = generateOTP(this.Config, this.token_steps);
    let int_code_next = generateOTP(this.Config, this.token_steps + 1);
    if (this.Config.TokenType === otpType.Steam) {
      this.TokenNumber = SteamUtils.SteamTokenFromTOTP(int_code);
      this.TokenNumberNext = SteamUtils.SteamTokenFromTOTP(int_code_next);
    } else {
      this.TokenNumber = int_code.toString().padStart(this.Config.TokenDigits, '0');
      this.TokenNumberNext = int_code_next.toString().padStart(this.Config.TokenDigits, '0');
    }
  }

  @Builder
  HiddenTokenDot(size: number) {
    Circle({ width: size, height: size })
      .fill(Color.Gray)
  }

  @Builder
  HiddenTokenDots() {
    if (this.token_preference.app_appearance_hidden_token_type === SettingHiddenTokenType.COMPACT) {
      Row({ space: 6 }) {
        this.HiddenTokenDot(8)
        this.HiddenTokenDot(8)
        this.HiddenTokenDot(8)
        this.HiddenTokenDot(8)
      }
    } else {
      Row({ space: 10 }) {
        Row({ space: 4 }) {
          this.HiddenTokenDot(6)
          this.HiddenTokenDot(6)
          this.HiddenTokenDot(6)
        }
        Row({ space: 4 }) {
          this.HiddenTokenDot(6)
          this.HiddenTokenDot(6)
          this.HiddenTokenDot(6)
        }
      }
    }
  }

  build() {
    Row({ space: 10 }) {
      ArcTokenIcon({ issuer: this.Config.TokenIssuer })
      Column() {
        Text(this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenName : this.Config.TokenIssuer)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .maxLines(1)
          .fontSize(this.token_preference.app_appearance_issuer_font_size)
          .fontWeight(this.token_preference.app_appearance_issuer_font_weight)
          .fontColor('#ffe0e0e0')
        Text(this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenIssuer : this.Config.TokenName)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .maxLines(1)
          .fontSize(this.token_preference.app_appearance_user_name_font_size)
          .fontWeight(this.token_preference.app_appearance_user_name_font_weight)
          .fontColor($r('app.color.str_gray'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
        Text(this.Config.RankScore.toString())
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .maxLines(1)
          .fontSize(30)
      }

      if (this.TokenHide && this.token_preference.app_safety_hide_token_enable) {
        Stack() {
          this.HiddenTokenDots()
        }
        .responseRegion({
          x: 0,
          y: this.token_preference.app_appearance_hidden_token_type === SettingHiddenTokenType.COMPACT ? -20 : -21,
          width: '100%',
          height: 48
        })
        .onClick(() => {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = false;
        })

      } else {
        Column() {
          Text(this.TokenNumber)
            .textAlign(TextAlign.End)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .maxLines(1)
            .fontColor('#ffe0e0e0')
            .fontSize(this.token_preference.app_appearance_token_font_size)
            .fontWeight(this.token_preference.app_appearance_token_font_weight)
            .fontFamily(AppFonts.CODE_FONT)
            .gesture(
              LongPressGesture()
                .onAction(() => {
                  copyText(this.TokenNumber, `token ${this.TokenNumber} `+ this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.token_copied').id));
                })
            )
          if (this.Config.TokenType == otpType.HOTP) {
            Text(this.TokenCounter + (this.token_preference.app_appearance_show_next_token_enable ? ":" + this.TokenNumberNext : ""))
              .textAlign(TextAlign.End)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .maxLines(1)
              .fontColor($r('app.color.str_gray'))
              .fontSize(10)
          } else if (this.token_preference.app_appearance_show_next_token_enable) {
            Text(this.TokenNumberNext)
              .textAlign(TextAlign.End)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .maxLines(1)
              .fontColor($r('app.color.str_gray'))
              .fontSize(10)
              .fontFamily(AppFonts.CODE_FONT)
          }
        }
        .onClick(() => {
          if (this.token_preference.app_safety_hide_token_enable) {
            this.TokenHide = !this.TokenHide;
            current_token_hide_map[this.Config.TokenUUID] = true;
          }
        })

        if (this.Config.TokenType == otpType.HOTP) {
          SymbolGlyph($r('sys.symbol.lock_filled_arrow_counterclockwise'))
            .fontColor([this.hotp_next_btn_color])
            .fontSize(40)
            .fontWeight(FontWeight.Medium)
            .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
              this.btn_hotp_clicked)
            .onClick(() => {
              this.btn_hotp_clicked++;
              this.Config.TokenCounter++;
              this.Update(this.Config)
              this.updateHOTPToken();
            })
        } else {
          Stack() {
            Text(this.TokenLeftPeriod.toString())
            Progress({ value: this.TokenLeftPeriod, total: this.Config.TokenPeriod, type: ProgressType.Ring })
              .style({ strokeWidth: 8 })
              .width(40)
              .height(40)
              .color(this.TokenLeftPeriod <= this.token_color_change_threshold ?
                this.token_progress_color_near_next :
                this.token_progress_color_normal)
          }
        }
      }
    }
    .borderRadius(40)
    .padding(10)
    .justifyContent(FlexAlign.SpaceBetween)
    .width('100%')
    .height(this.token_preference.app_appearance_item_height)
    .backgroundColor('#20e0e0e0')
    .bindContextMenu(this.TokenRightCtxMenu, ResponseType.RightClick, { enableArrow: true })
  }

  @Builder
  QRCodeDialogBuilder(): void {
    QRCodeDialog({
      content: convertToken2URI(this.Config),
      winSize: this.window.Size
    })
  }

  private openQRCodeDialog(): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.QRCodeDialogBuilder();
      }
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'ArcTokenItem', `open QR code dialog failed: ${error.message}`);
    });
  }

  @Builder
  TokenRightCtxMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: this.menu_icon_copy, content: $r('app.string.token_right_menu_copy') })
        .onClick(() => {
          copyText(this.TokenNumber, `${this.TokenNumber} copied`);
        })
        .accessibilityText($r('app.string.token_right_menu_copy'))
      MenuItem({ symbolStartIcon: this.menu_icon_qrcode, content: $r('app.string.token_right_menu_show_qrcode') })
        .onClick(() => {
          this.openQRCodeDialog();
        })
        .accessibilityText($r('app.string.token_right_menu_show_qrcode'))
      MenuItem({ symbolStartIcon: this.menu_icon_trash, content: $r('app.string.token_right_menu_delete') })
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: $r('app.string.alert_remove_title', this.Config.TokenIssuer),
            subtitle: this.Config.TokenName,
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
                tkStore.deleteToken(this.Config.TokenUUID);
              }
            }
          })

        })
        .contentFontColor(Color.Red)
        .accessibilityText($r('app.string.token_right_menu_delete'))
    }
  }
}
