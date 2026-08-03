import { systemDateTime } from '@kit.BasicServicesKit';
import { otpType, TokenConfig, dialogSystemMaterial } from 'common';
import { convertToken2URI, copyText, generateOTP } from 'common';
import { TokenIcon } from 'uikit';
import { SteamUtils } from 'common';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from 'common';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { TOTPConfigDialog } from 'uikit';
import { FortiConfigDialog } from 'uikit';
import { SteamConfigDialog } from 'uikit';
import { QRCodeDialog } from 'uikit';
import { AppWindowInfo } from 'common';
import { TokenStore } from 'common';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { CommonConstants } from 'common';
import { AppFonts } from 'common';
import { MaterialSurface } from './MaterialSurface';
import { MaterialTheme } from './MaterialTheme';

let current_token_hide_map: Map<string, boolean> = new Map();
let tkStore = TokenStore.getInstance();

@Preview
@ComponentV2
export struct TokenItem {
  @Require @Param Config: TokenConfig = new TokenConfig();
  @Event Update: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Param sortMode: boolean = false;

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local TokenNumber: string = '000000';
  @Local TokenNumberNext: string = '000000';
  @Local TokenCounter: string = '0';
  @Local TokenLeftPeriod: number = 0;
  @Local btn_hotp_clicked: number = 0;
  @Local TokenHide: boolean = current_token_hide_map[this.Config.TokenUUID] ?? true;
  @Local isLongPressMenuShown: boolean = false;

  @Local menu_icon_trash: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash')).fontSize('22vp').fontColor([Color.Red]);
  @Local menu_icon_qrcode: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.qrcode')).fontSize('22vp');
  @Local menu_icon_edit: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')).fontSize('22vp');
  @Local menu_icon_copy: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.doc_text_on_doc_text')).fontSize('22vp');
  @Local menu_icon_sort: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.list_bullet')).fontSize('22vp');

  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;

  private token_steps: number = 0;
  private onTimestampChangedHandler: (timestamp: number, force: boolean) => void = () => {};
  // 使用 AppStorage 获取 context，避免在 aboutToAppear（build 之前）调用 getUIContext()
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;

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
      this.token_preference.app_appearance_token_counter_light_color_end;
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

  @Builder
  TextContentBuilder() {
    Column() {
      Text(this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenName : this.Config.TokenIssuer)
        .fontSize(this.token_preference.app_appearance_issuer_font_size)
        .fontWeight(this.token_preference.app_appearance_issuer_font_weight)
        .fontColor($r('app.color.str_main'))
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        .maxLines(1)
      Text(this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenIssuer : this.Config.TokenName)
        .fontSize(this.token_preference.app_appearance_user_name_font_size)
        .fontWeight(this.token_preference.app_appearance_user_name_font_weight)
        .fontColor($r('app.color.str_gray'))
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
  }

  aboutToAppear(): void {
    this.onTimestampChangedHandler = (timestamp: number, force: boolean): void => this.onTimestampChanged(timestamp, force);
    // 使用 AppStorage 获取的 context 注册事件，避免 aboutToAppear 阶段调用 getUIContext()
    this.appCtx.eventHub?.on(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
    this.updateToken();
  }

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
  TokenIconBuilder() {
    TokenIcon({ issuer: this.Config.TokenIssuer, icon_path: this.Config.TokenIconPath })
      .padding({ left: $r('sys.float.ohos_id_text_overlay_menu_button_padding_left'), right: $r('sys.float.ohos_id_text_overlay_menu_button_padding_right') })
  }

  @Builder
  TokenCodeBuilder() {
    Column() {
      if (AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
        Text(this.Config.RankScore.toString())
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .maxLines(1)
          .fontSize(30)
      }

      if (this.TokenHide && this.token_preference.app_safety_hide_token_enable) {
        Text() {
          Span("●●●●")
        }
        .fontColor(Color.Gray)
        .fontSize(this.token_preference.app_appearance_token_font_size)
      } else {
        Row({ space: 4 }) {
          Column() {
            Text(this.TokenNumber)
              .textAlign(TextAlign.End)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .maxLines(1)
              .fontColor(this.TokenLeftPeriod <= this.token_color_change_threshold && this.Config.TokenType !== otpType.HOTP ?
                this.token_color_expiring : this.token_color_normal)
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
    }
    .alignItems(HorizontalAlign.End)
    .padding({ left: $r('sys.float.ohos_id_text_overlay_menu_button_padding_left'), right: $r('sys.float.ohos_id_text_overlay_menu_button_padding_right') })
  }

  build() {
    if (this.sortMode) {
      // 排序模式：禁用上下文菜单和长按手势，Suffix 显示排序图标；
      // 材质与主列表一致跟随设置（逐项光感为用户显式开启项，开启前经 Dialog 二次确认）
      Column() {
        if (MaterialTheme.isTokenItemMaterialEffective()) {
          // 内容背景透明透出材质层（不透明背景会盖住 ImmersiveMaterial）
          MaterialSurface({ radius: this.token_preference.app_appearance_item_radius }) {
            this.TokenRowContent(true)
          }
        } else {
          Column() {
            this.TokenRowContent(true)
          }
          .width('100%')
          .borderRadius(this.token_preference.app_appearance_item_radius)
          .backgroundColor($r('app.color.item_bg'))
        }
      }
      // 外层只带 margin 不设 width：width('100%')+margin 会把卡片撑出列表右边界；
      // 与下方非排序分支结构一致，margin 由外层承担，宽度交给 ListItem 约束
      .margin({
        left: this.token_preference.app_appearance_token_list_item_prefix_padding,
        right: this.token_preference.app_appearance_token_list_item_suffix_padding
      })
    } else {
      Column() {
        if (MaterialTheme.isTokenItemMaterialEffective()) {
          // 列表项光感材质：用户在设置中显式开启（官方不建议滚动列表逐项
          // 材质，开启前已经 Dialog 二次确认）；内容背景透明透出材质层
          MaterialSurface({ radius: this.token_preference.app_appearance_item_radius }) {
            this.TokenRowContent(false)
          }
        } else {
          Column() {
            this.TokenRowContent(false)
          }
          .width('100%')
          .borderRadius(this.token_preference.app_appearance_item_radius)
          .backgroundColor($r('app.color.item_bg'))
        }
      }
      // 卡片左右边距跟随设置中的「左侧边距/右侧边距」，实体与光感两种模式等宽；
      // 卡片内部内容边距固定为 0（见 TokenRowContent）
      .margin({
        left: this.token_preference.app_appearance_token_list_item_prefix_padding,
        right: this.token_preference.app_appearance_token_list_item_suffix_padding
      })
      .onClick(() => {
        if (this.TokenHide && this.token_preference.app_safety_hide_token_enable) {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = false;
        } else if (this.token_preference.app_safety_hide_token_enable) {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = true;
        }
      })
      .gesture(
        LongPressGesture({ duration: this.token_preference.app_appearance_long_press_duration })
          .onAction(() => {
            this.isLongPressMenuShown = true;
          })
      )
      .bindContextMenu(this.isLongPressMenuShown, this.TokenRightCtxMenu, {
        // 预览走 CustomBuilder 自绘实体卡片，而非 MenuPreviewMode.IMAGE 组件截图：
        // 沉浸材质由 materialFilter 在合成时采样窗口背景实现，不属于组件自身像素，
        // 截图对效果类属性官方明确"可能产生非用户预期的结果"（材质层丢失只剩透明
        // 背景+图标文字）；实体模式下截图即为所见，仍用 IMAGE
        preview: MaterialTheme.isTokenItemMaterialEffective() ? this.TokenMenuPreview : MenuPreviewMode.IMAGE,
        previewBorderRadius: this.token_preference.app_appearance_item_radius,
        hapticFeedbackMode: HapticFeedbackMode.AUTO,
        onDisappear: () => {
          this.isLongPressMenuShown = false;
        }
      })
      .bindContextMenu(this.TokenRightCtxMenu, ResponseType.RightClick, { enableArrow: true })
    }
  }

  /**
   * 列表项内容行（自绘，替代原 HdsListItemCard）：图标 + 文本 + suffix。
   * 实体与光感两种模式的可见背景边界统一由本行所在表面决定；
   * 卡片左右边距（外层 .margin）跟随设置中的「左侧边距/右侧边距」，
   * 卡片内部内容边距固定为 0（图标/验证码 builder 自带少量间距）
   */
  @Builder
  TokenRowContent(sort: boolean) {
    Row() {
      this.TokenIconBuilder()
      Column() {
        this.TextContentBuilder()
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (sort) {
        this.TokenSortIconBuilder()
      } else {
        this.TokenCodeBuilder()
      }
    }
    .width('100%')
    .height(this.token_preference.app_appearance_item_height)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TokenSortIconBuilder() {
    // 与主页验证码区（TokenCodeBuilder）同款左右内边距，排序图标不贴卡片边缘
    SymbolGlyph($r('sys.symbol.list_bullet'))
      .fontSize(24)
      .fontColor([$r('sys.color.icon_secondary')])
      .padding({ left: $r('sys.float.ohos_id_text_overlay_menu_button_padding_left'), right: $r('sys.float.ohos_id_text_overlay_menu_button_padding_right') })
  }

  /**
   * 长按菜单的自定义预览（材质模式专用，替代 MenuPreviewMode.IMAGE 截图）。
   * 自绘实体卡片：内容复用 TokenRowContent，背景用与 solid 档位一致的
   * item_bg + 卡片圆角；材质列表项浮起后呈现实体卡是长按预览的标准观感。
   * 预览可布局区域默认扣除左右各 16vp（layoutRegionMargin 默认值），
   * width('100%') 与列表卡片视觉宽度基本一致。
   * 必须 @LocalBuilder：preview 是 CustomBuilder 参数，普通 @Builder 以
   * this.TokenMenuPreview 传入时 this 被重绑定，菜单弹出即崩
   * （TypeError: observeComponentCreation2 of undefined，已真机踩坑）
   */
  @LocalBuilder
  TokenMenuPreview() {
    Column() {
      this.TokenRowContent(false)
    }
    .width('100%')
    .borderRadius(this.token_preference.app_appearance_item_radius)
    .backgroundColor($r('app.color.item_bg'))
  }

  @Builder
  TokenRightCtxMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: this.menu_icon_sort, content: $r('app.string.token_right_menu_sort') })
        .onClick(() => {
          if (this.appCtx.eventHub != undefined) {
            this.appCtx.eventHub.emit(EVENT_NAMES.START_TOKEN_SORT);
          }
        })
        .accessibilityText($r('app.string.token_right_menu_sort'))
      MenuItem({ symbolStartIcon: this.menu_icon_copy, content: $r('app.string.token_right_menu_copy') })
        .onClick(() => {
          copyText(this.TokenNumber, `${this.TokenNumber} copied`);
        })
        .accessibilityText($r('app.string.token_right_menu_copy'))
      MenuItem({ symbolStartIcon: this.menu_icon_qrcode, content: $r('app.string.token_right_menu_show_qrcode') })
        .onClick(() => {
          this.dialog_qrcode = new CustomDialogController({
            systemMaterial: dialogSystemMaterial(),
            builder: QRCodeDialog({
              content: convertToken2URI(this.Config),
              winSize: this.window.Size
            })
          });
          this.dialog_qrcode.open();
        })
        .accessibilityText($r('app.string.token_right_menu_show_qrcode'))
      MenuItem({ symbolStartIcon: this.menu_icon_edit, content: $r('app.string.token_right_menu_edit') })
        .onClick(() => {
          if (this.Config.TokenType === otpType.TOTP || this.Config.TokenType === otpType.HOTP ||
            this.Config.TokenType === undefined) { // default
            this.dialog_totp_config = new CustomDialogController({
              systemMaterial: dialogSystemMaterial(),
              builder: TOTPConfigDialog({
                conf_json: JSON.stringify(this.Config),
                confirm: async (new_conf): Promise<boolean> => {
                  return await this.Update(JSON.parse(new_conf))
                }
              })
            })
            this.dialog_totp_config.open()
          } else if (this.Config.TokenType === otpType.Forti) { // forti
            this.dialog_forti_config = new CustomDialogController({
              systemMaterial: dialogSystemMaterial(),
              builder: FortiConfigDialog({
                conf_json: JSON.stringify(this.Config),
                confirm: async (new_conf): Promise<boolean> => {
                  return await this.Update(JSON.parse(new_conf))
                }
              })
            })
            this.dialog_forti_config.open()
          } else if (this.Config.TokenType === otpType.Steam) { // steam
            this.dialog_steam_config = new CustomDialogController({
              systemMaterial: dialogSystemMaterial(),
              builder: SteamConfigDialog({
                conf_json: JSON.stringify(this.Config),
                confirm: async (new_conf): Promise<boolean> => {
                  return await this.Update(JSON.parse(new_conf))
                }
              })
            })
            this.dialog_steam_config.open()
          }
        })
        .accessibilityText($r('app.string.token_right_menu_edit'))
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
