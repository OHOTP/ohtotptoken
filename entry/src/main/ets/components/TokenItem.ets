import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { otpType, TokenConfig, dialogSystemMaterial } from 'common';
import { convertToken2URI, copyText, generateOTP } from 'common';
import { TokenIcon } from 'uikit';
import { SteamUtils } from 'common';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from 'common';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { QRCodeDialog } from 'uikit';
import { AppWindowInfo } from 'common';
import { TokenStore } from 'common';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { CommonConstants } from 'common';
import { AppFonts } from 'common';
import { MaterialSurface } from './MaterialSurface';
import { MaterialTheme } from './MaterialTheme';
import { NfcSessionTokens } from '../oath/NfcSessionTokens';

let current_token_hide_map: Map<string, boolean> = new Map();
let tkStore = TokenStore.getInstance();

@Preview
@ComponentV2
export struct TokenItem {
  @Require @Param Config: TokenConfig = new TokenConfig();
  @Event Update: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Event Edit: (conf: TokenConfig) => void = () => {};
  @Event Select: (conf: TokenConfig) => void = () => {};
  @Param sortMode: boolean = false;
  @Param selectionMode: boolean = false;

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local TokenNumber: string = '000000';
  @Local TokenNumberNext: string = '000000';
  @Local TokenCounter: string = '0';
  @Local TokenLeftPeriod: number = 0;
  @Local btn_hotp_clicked: number = 0;
  @Local TokenHide: boolean = current_token_hide_map[this.Config.TokenUUID] ?? true;
  @Local previewDetailsVisible: boolean = false;
  @Local debugModeIsOn: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;

  @Local menu_icon_trash: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash')).fontSize('22vp').fontColor([Color.Red]);
  @Local menu_icon_qrcode: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.qrcode')).fontSize('22vp');
  @Local menu_icon_edit: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')).fontSize('22vp');
  @Local menu_icon_copy: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.doc_text_on_doc_text')).fontSize('22vp');
  @Local menu_icon_sort: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.list_bullet')).fontSize('22vp');

  private dialog_qrcode?: CustomDialogController;
  private isLongPressMenuActive: boolean = false;
  private pendingSortNavigation: boolean = false;

  private token_steps: number = 0;
  private onTimestampChangedHandler: (timestamp: number, force: boolean) => void = () => {};
  private onDebugModeChangedHandler: (isOn: boolean) => void = () => {};
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
      // DEBUG 排名并入首行，避免在固定高度卡片的验证码区新增一行并挤出计时环。
      Text(this.debugModeIsOn ?
        `${this.Config.RankScore} · ${this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenName : this.Config.TokenIssuer}` :
        (this.token_preference.app_appearance_swap_host_user_enable ? this.Config.TokenName : this.Config.TokenIssuer))
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

  /**
   * Config 引用变化时重新计算令牌内容（@Monitor 为 V2 监听器，仅在值变化后触发）。
   * 注意：LazyForEach 复用组件场景下 @Param 不会重新赋值，@Monitor 可能不触发，
   * 因此还依赖 NFC_EXTERNAL_TOKENS_CHANGED 事件驱动刷新（见 onNfcExternalTokensChanged）。
   */
  @Monitor("Config")
  onConfigChanged(monitor: IMonitor): void {
    hilog.info(0xFF00, 'TokenItem', `onConfigChanged triggered uuid=${this.Config.TokenUUID} issuer=${this.Config.TokenIssuer} name=${this.Config.TokenName}`);
    this.updateToken();
  }

  /**
   * 事件驱动刷新：外部令牌会话存储变更时，直接按 TokenUUID 查找最新令牌并刷新验证码。
   * 不依赖 @Param 重新赋值（LazyForEach 复用组件时不更新 @Param）。
   */
  private onNfcExternalTokensChangedHandler: () => void = () => {};
  onNfcExternalTokensChanged(): void {
    if (this.Config.TokenType !== otpType.NFC_external) {
      return;
    }
    const latest = NfcSessionTokens.getInstance().getTokens().find((t) => t.TokenUUID === this.Config.TokenUUID);
    if (latest !== undefined) {
      const newCode = latest.TokenExternalCode ?? '';
      if (newCode !== this.TokenNumber) {
        this.TokenNumber = newCode;
        hilog.info(0xFF00, 'TokenItem', `event refresh uuid=${this.Config.TokenUUID}`);
      }
    }
  }

  aboutToAppear(): void {
    this.onTimestampChangedHandler = (timestamp: number, force: boolean): void => this.onTimestampChanged(timestamp, force);
    // 使用 AppStorage 获取的 context 注册事件，避免 aboutToAppear 阶段调用 getUIContext()
    this.appCtx.eventHub?.on(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
    this.onNfcExternalTokensChangedHandler = (): void => this.onNfcExternalTokensChanged();
    this.appCtx.eventHub?.on(EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED, this.onNfcExternalTokensChangedHandler);
    this.onDebugModeChangedHandler = (isOn: boolean): void => {
      this.debugModeIsOn = isOn;
    };
    this.appCtx.eventHub?.on(EVENT_NAMES.DEBUG_MODE_CHANGED, this.onDebugModeChangedHandler);
    this.updateToken();
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
    this.appCtx.eventHub?.off(EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED, this.onNfcExternalTokensChangedHandler);
    this.appCtx.eventHub?.off(EVENT_NAMES.DEBUG_MODE_CHANGED, this.onDebugModeChangedHandler);
  }

  private onLongPressMenuWillAppear(): void {
    this.isLongPressMenuActive = true;
    this.pendingSortNavigation = false;
    this.previewDetailsVisible = false;
  }

  private onLongPressMenuDidAppear(): void {
    // 共享容器扩展完成后再淡入元数据，避免内容先于容器尺寸变化出现。
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
      this.previewDetailsVisible = true;
    });
  }

  private onLongPressMenuWillDisappear(): void {
    this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseIn }, () => {
      this.previewDetailsVisible = false;
    });
  }

  private requestTokenSort(): void {
    // 右键菜单没有长按预览，保持原有的直接跳转行为。
    if (!this.isLongPressMenuActive) {
      this.appCtx.eventHub?.emit(EVENT_NAMES.START_TOKEN_SORT);
      return;
    }
    this.pendingSortNavigation = true;
    this.previewDetailsVisible = false;
    // 主动关闭菜单，触发 CustomBuilder 预览到原组件截图的反向一镜到底动效。
    this.getUIContext().getContextMenuController().close();
  }

  private onLongPressMenuDidDisappear(): void {
    this.isLongPressMenuActive = false;
    if (!this.pendingSortNavigation) {
      return;
    }
    this.pendingSortNavigation = false;
    this.appCtx.eventHub?.emit(EVENT_NAMES.START_TOKEN_SORT);
  }

  private tokenTypeName(): string {
    if (this.Config.TokenType === otpType.HOTP) {
      return 'HOTP';
    }
    if (this.Config.TokenType === otpType.Forti) {
      return 'FortiToken';
    }
    if (this.Config.TokenType === otpType.Steam) {
      return 'Steam';
    }
    if (this.Config.TokenType === otpType.NFC_external) {
      return 'NFC OATH';
    }
    return 'TOTP';
  }

  onTimestampChanged(timestamp: number, force: boolean): void {
    if (this.Config.TokenType !== otpType.HOTP && this.Config.TokenType !== otpType.NFC_external) {
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
    if (this.Config.TokenType == otpType.NFC_external) {
      // 外部令牌静态展示：直接显示卡片读取的验证码，不参与计时计算
      this.TokenNumber = this.Config.TokenExternalCode ?? '';
      hilog.info(0xFF00, 'TokenItem', `updateToken external uuid=${this.Config.TokenUUID} issuer=${this.Config.TokenIssuer} name=${this.Config.TokenName}`);
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
              .fontColor(this.TokenLeftPeriod <= this.token_color_change_threshold && this.Config.TokenType !== otpType.HOTP &&
                this.Config.TokenType !== otpType.NFC_external ?
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
            } else if (this.Config.TokenType !== otpType.NFC_external &&
              this.token_preference.app_appearance_show_next_token_enable) {
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
          } else if (this.Config.TokenType == otpType.NFC_external) {
            // 外部令牌静态展示：不显示倒计时环
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
        if (this.selectionMode) {
          this.Select(this.Config);
          return;
        }
        if (this.TokenHide && this.token_preference.app_safety_hide_token_enable) {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = false;
        } else if (this.token_preference.app_safety_hide_token_enable) {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = true;
        }
      })
      .bindContextMenu(this.TokenRightCtxMenu, ResponseType.LongPress, {
        // 官方 hoverScale 仅在 LongPress + CustomBuilder 预览中提供原组件截图到
        // 扩展预览的一镜到底变形；isShown 方式只会直接展示目标尺寸。
        preview: this.TokenMenuPreview,
        previewAnimationOptions: { hoverScale: [1.0, 1.0] },
        previewBorderRadius: this.token_preference.app_appearance_item_radius,
        hapticFeedbackMode: HapticFeedbackMode.AUTO,
        onWillAppear: () => {
          this.onLongPressMenuWillAppear();
        },
        onDidAppear: () => {
          this.onLongPressMenuDidAppear();
        },
        onWillDisappear: () => {
          this.onLongPressMenuWillDisappear();
        },
        onDidDisappear: () => {
          this.onLongPressMenuDidDisappear();
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

  @Builder
  TokenPreviewMetadata(label: ResourceStr, value: string) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.str_main'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 长按菜单的扩展预览。卡片先随 ContextMenu 预览动效扩大，元数据随后淡入；
   * 关闭菜单时系统反向缩回原位。统一自绘也避免沉浸材质截图丢失。
   * 必须 @LocalBuilder：preview 是 CustomBuilder 参数，普通 @Builder 以
   * this.TokenMenuPreview 传入时 this 被重绑定，菜单弹出即崩。
   */
  @LocalBuilder
  TokenMenuPreview() {
    Column() {
      this.TokenRowContent(false)
      Divider()
        .color($r('sys.color.comp_divider'))
        .strokeWidth(0.5)
        .margin({ left: 16, right: 16 })
      Column({ space: 10 }) {
        Row({ space: 12 }) {
          this.TokenPreviewMetadata($r('app.string.add_token_type'), this.tokenTypeName())
          if (this.Config.TokenType !== otpType.NFC_external) {
            this.TokenPreviewMetadata($r('app.string.dialog_cfg_tk_alg'), this.Config.TokenAlgorithm)
          }
        }
        .width('100%')
        if (this.Config.TokenType !== otpType.NFC_external) {
          Row({ space: 12 }) {
            this.TokenPreviewMetadata($r('app.string.dialog_cfg_tk_digits'), this.Config.TokenDigits.toString())
            this.TokenPreviewMetadata(
              this.Config.TokenType === otpType.HOTP ?
                $r('app.string.dialog_cfg_tk_counter') : $r('app.string.dialog_cfg_tk_timeout'),
              this.Config.TokenType === otpType.HOTP ?
                this.Config.TokenCounter.toString() : `${this.Config.TokenPeriod}s`)
          }
          .width('100%')
        }
      }
      .padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .opacity(this.previewDetailsVisible ? 1 : 0)
      .translate({ y: this.previewDetailsVisible ? 0 : 8 })
    }
    .width('100%')
    .clip(true)
    .borderRadius(this.token_preference.app_appearance_item_radius)
    .backgroundColor($r('app.color.item_bg'))
  }

  @Builder
  TokenRightCtxMenu() {
    Menu() {
      // NFC 外部令牌为会话级、不持久化，排序（RankScore 持久化）对其无意义，故不提供排序入口
      if (this.Config.TokenType !== otpType.NFC_external) {
        MenuItem({ symbolStartIcon: this.menu_icon_sort, content: $r('app.string.token_right_menu_sort') })
          .onClick(() => {
            this.requestTokenSort();
          })
          .accessibilityText($r('app.string.token_right_menu_sort'))
      }
      MenuItem({ symbolStartIcon: this.menu_icon_copy, content: $r('app.string.token_right_menu_copy') })
        .onClick(() => {
          copyText(this.TokenNumber, `${this.TokenNumber} copied`);
        })
        .accessibilityText($r('app.string.token_right_menu_copy'))
      if (this.Config.TokenType !== otpType.NFC_external) {
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
              this.Edit(this.Config);
            } else if (this.Config.TokenType === otpType.Forti) { // forti
              this.Edit(this.Config);
            } else if (this.Config.TokenType === otpType.Steam) { // steam
              this.Edit(this.Config);
            }
          })
          .accessibilityText($r('app.string.token_right_menu_edit'))
      }
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
                if (this.Config.TokenType === otpType.NFC_external) {
                  // 外部令牌仅存于会话存储，从会话中移除
                  NfcSessionTokens.getInstance().remove(this.Config.TokenUUID);
                } else {
                  tkStore.deleteToken(this.Config.TokenUUID);
                }
              }
            }
          })

        })
        .contentFontColor(Color.Red)
        .accessibilityText($r('app.string.token_right_menu_delete'))
    }
  }
}
