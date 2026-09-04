import { MaterialTheme } from '../components/MaterialTheme';
import { AppStorageV2 } from '@kit.ArkUI';

import { SettingItem } from '../components/SettingItem';
import { SubItemDivider } from '../components/SubItemDivider';
import { SubItemToggle } from '../components/SubItemToggle';
import { TokenItem } from '../components/TokenItem';
import { PageScaffold } from '../components/PageScaffold';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS, SettingHiddenTokenType,
  SettingTokenProgressType, AVAILABLE_HIDDEN_TOKEN_TYPES, AVAILABLE_TOKEN_PROGRESS_TYPES } from 'common';
import { otpType, TokenConfig } from 'common';
import { systemDateTime } from '@kit.BasicServicesKit';
import { SubItemColor } from '../components/SubItemColor';
import { SubItemSlider } from '../components/SubItemSlider';
import { SubItemButton } from '../components/SubItemButton';
import { SubItemEnumSelect } from '../components/SubItemEnumSelect';
import { AppWindowInfo } from 'common';
import { common } from '@kit.AbilityKit';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { CommonConstants } from 'common';
import { SETTING_PAGE_INSET } from '../components/SettingStyle';

@Entry
@Preview
@ComponentV2
export struct AppearancePage {
  pageInfos: NavPathStack | null = null;

  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  // 使用 AppStorage 获取 context，避免在字段初始化阶段调用 getUIContext()（此时 build() 尚未执行）
  private context: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private scroller: Scroller = new Scroller();

  // [性能优化] 本页不再无条件自建 1s 计时器。
  // 首页 Index 持有全局唯一时间计时器，每秒经 eventHub 广播 TIMESTAMP_CHANGED，
  // 预览区内的 TokenItem 自身已订阅该事件，正常情况下可直接复用、无需重复推送。
  //
  // [防御性兜底] 为避免对“Index 必然挂载且其计时器必然在跑”这一隐式假设产生硬依赖
  // （例如未来路由调整使本页在 Index 之外打开），这里订阅 TIMESTAMP_CHANGED 来探测全局心跳：
  //   - 收到事件 → 记录最近心跳时间，说明全局源健康，本页不做任何额外推送；
  //   - 超过阈值仍无心跳 → 全局源疑似缺失，本页启动兜底计时器自行广播，保证预览倒计时持续刷新。
  // 健康路径下兜底计时器虽每秒触发一次，但不产生 emit（不触发 TokenItem 重复计算 HMAC），开销可忽略。
  private timestampIntervalId: number = -1;
  private lastTimestampTick: number = 0;
  // 标记“正在由本页兜底广播”，避免自身 emit 同步回调时误刷新心跳。
  private selfEmitting: boolean = false;
  private onTimestampHandler: () => void = () => {};
  // 判定全局心跳缺失的阈值（毫秒）。全局计时器为 1s 一次，取 1.5s 留出抖动余量。
  private static readonly HEARTBEAT_TIMEOUT_MS: number = 1500;

  aboutToAppear(): void {
    this.lastTimestampTick = systemDateTime.getTime();
    // 仅用于探测全局心跳：仅当事件来源为“全局 Index”（非本页兜底）时才刷新心跳时间。
    // 若不区分来源，本页兜底广播会经 eventHub 同步回调自身，把心跳刷新为当前时间，
    // 导致兜底计时器每 2s 才触发一次（出现卡顿）。
    this.onTimestampHandler = (): void => {
      if (!this.selfEmitting) {
        this.lastTimestampTick = systemDateTime.getTime();
      }
    };
    this.context.eventHub?.on(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampHandler);

    // 兜底计时器：仅在全局心跳超时时才广播，避免与 Index 重复推送。
    // eventHub.emit 为同步调用，故用 selfEmitting 标志包裹以阻止自身回调污染心跳，
    // 保证全局心跳缺失时兜底能稳定每 1s 广播一次。
    this.timestampIntervalId = setInterval(() => {
      if (systemDateTime.getTime() - this.lastTimestampTick > AppearancePage.HEARTBEAT_TIMEOUT_MS) {
        const timestamp = Math.floor(systemDateTime.getTime() / 1000);
        this.selfEmitting = true;
        this.context.eventHub?.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, false);
        this.selfEmitting = false;
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    this.context.eventHub?.off(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampHandler);
    if (this.timestampIntervalId !== -1) {
      clearInterval(this.timestampIntervalId);
      this.timestampIntervalId = -1;
    }
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        Column() {
          List({ space: this.token_preference.app_appearance_item_space, scroller: this.scroller }) {
            // 顶部避让
            ListItem()
              .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)

            ListItemGroup({ space: this.token_preference.app_appearance_item_space }) {
              ListItem() {
                TokenItem({
                  Config: new TokenConfig('ABC', otpType.TOTP, 'Github', 'Foo Bar'),
                  Update: async (): Promise<boolean> => false
                })
              }

              ListItem() {
                TokenItem({
                  Config: new TokenConfig('ABC', otpType.HOTP, 'Microsoft', 'Some Body'),
                  Update: async (): Promise<boolean> => false
                })
              }
            }

            ListItemGroup() {
              ListItem()
            }
          }
          .alignListItem(ListItemAlign.Center)
          .width('100%')
          .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
          .backdropBlur(100)
          List({ space: 10 }) {
            ListItem()
            ListItem() {
              SettingItem({ title: $r('app.string.custom_function') }) {

                SubItemToggle({
                  icon: $r('sys.symbol.transfer_station'),
                  title: $r('app.string.swap_host_user'),
                  isOn: AppPreference.getPreference(PREF_KEYS.APPEARANCE_SWAP_HOST_USER_ENABLE) as boolean,
                  description: $r('app.string.swap_host_user_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_SWAP_HOST_USER_ENABLE, IsOn);
                    this.token_preference.app_appearance_swap_host_user_enable = IsOn;
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.star_square_stack_fill'),
                  title: $r('app.string.enable_icon_background'),
                  isOn: AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND) as boolean,
                  description: $r('app.string.enable_icon_background_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND, IsOn);
                    this.token_preference.app_appearance_logo_background = IsOn;
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.circle_lefthalf_inset_filled'),
                  title: $r('app.string.enable_dark_icon_filter'),
                  isOn: AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER) as boolean,
                  description: $r('app.string.enable_dark_icon_filter_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER, IsOn);
                    this.token_preference.app_appearance_logo_dark_filter = IsOn;
                  }
                })

                SubItemDivider()

                SubItemSlider({
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  title: $r('app.string.token_item_function_slider'),
                  items: [
                    {
                      name: $r('app.string.token_item_color_change_threshold'),
                      default: this.token_preference.app_appearance_token_counter_next_margin,
                      min: 0,
                      max: 30,
                      step: 1
                    },
                  ],
                  description: $r('app.string.token_item_function_slider_desc'),
                  onChange: (index, value) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN, value);
                    this.token_preference.app_appearance_token_counter_next_margin = value;
                  }
                })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            ListItem() {
              SettingItem({ title: $r('app.string.custom_layout') }) {
                SubItemEnumSelect({
                  icon: $r('sys.symbol.circle_lefthalf_inset_filled'),
                  title: $r('app.string.hidden_token_type'),
                  options: AVAILABLE_HIDDEN_TOKEN_TYPES,
                  selected: this.token_preference.app_appearance_hidden_token_type ?? SettingHiddenTokenType.STANDARD,
                  description: $r('app.string.hidden_token_type_desc'),
                  onChange: (value: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_HIDDEN_TOKEN_TYPE, value);
                    this.token_preference.app_appearance_hidden_token_type = value;
                  }
                })

                SubItemDivider()

                SubItemEnumSelect({
                  icon: $r('sys.symbol.arrow_counterclockwise_clock'),
                  title: $r('app.string.token_progress_type'),
                  options: AVAILABLE_TOKEN_PROGRESS_TYPES,
                  selected: this.token_preference.app_appearance_token_progress_type ?? SettingTokenProgressType.LINEAR,
                  description: $r('app.string.token_progress_type_desc'),
                  onChange: (value: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_PROGRESS_TYPE, value);
                    this.token_preference.app_appearance_token_progress_type = value;
                  }
                })

                SubItemDivider()

                SubItemSlider({
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  title: $r('app.string.token_item_slider'),
                  items: [
                    {
                      name: $r('app.string.token_item_max_width'),
                      default: this.token_preference.app_appearance_item_max_width,
                      min: 500,
                      max: 1000,
                      step: 50
                    },
                    {
                      name: $r('app.string.token_item_hight'),
                      default: this.token_preference.app_appearance_item_height,
                      min: 50,
                      max: 100,
                      step: 5
                    },
                    {
                      name: $r('app.string.token_item_space'),
                      default: this.token_preference.app_appearance_item_space,
                      min: 5,
                      max: 30,
                      step: 1
                    },
                    {
                      name: $r('app.string.token_logo_size'),
                      default: this.token_preference.app_appearance_logo_size,
                      min: 20,
                      max: 60,
                      step: 5
                    },
                    {
                      name: $r('app.string.token_logo_bg_size'),
                      default: this.token_preference.app_appearance_logo_background_size,
                      min: 25,
                      max: 65,
                      step: 5
                    },
                    {
                      name: $r('app.string.token_logo_bg_r'),
                      default: this.token_preference.app_appearance_logo_background_radius,
                      min: 0,
                      max: Math.round(this.token_preference.app_appearance_logo_background_size / 2),
                      step: 1
                    },
                    {
                      // 卡片圆角：默认 16vp 取自官方设计指南「圆角参数」普通卡片/内容容器档；
                      // 范围 0~32 步进 2，对齐系统圆角 Token 全量表（level1~level16）
                      name: $r('app.string.token_item_radius'),
                      default: this.token_preference.app_appearance_item_radius,
                      min: 0,
                      max: 32,
                      step: 2
                    },
                    {
                      name: $r('app.string.token_list_item_prefix_padding'),
                      default: this.token_preference.app_appearance_token_list_item_prefix_padding,
                      min: 0,
                      max: 30,
                      step: 1
                    },
                    {
                      name: $r('app.string.token_list_item_suffix_padding'),
                      default: this.token_preference.app_appearance_token_list_item_suffix_padding,
                      min: 0,
                      max: 30,
                      step: 1
                    },
                  ],
                  description: $r('app.string.token_item_slider_desc'),
                  onChange: (index, value) => {
                    switch (index) {
                      case 0: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ITEM_MAX_WIDTH, value);
                        this.token_preference.app_appearance_item_max_width = value;
                        break;
                      }
                      case 1: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ITEM_HEIGHT, value);
                        this.token_preference.app_appearance_item_height = value;
                        break;
                      }
                      case 2: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ITEM_SPACE, value);
                        this.token_preference.app_appearance_item_space = value;
                        break;
                      }
                      case 3: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_SIZE, value);
                        this.token_preference.app_appearance_logo_size = value;
                        break;
                      }
                      case 4: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_SIZE, value);
                        this.token_preference.app_appearance_logo_background_size = value;
                        break;
                      }
                      case 5: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_RADIUS, value);
                        this.token_preference.app_appearance_logo_background_radius = value;
                        break;
                      }
                      case 6: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ITEM_RADIUS, value);
                        this.token_preference.app_appearance_item_radius = value;
                        break;
                      }
                      case 7: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_PREFIX_PADDING, value);
                        this.token_preference.app_appearance_token_list_item_prefix_padding = value;
                        break;
                      }
                      case 8: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_SUFFIX_PADDING, value);
                        this.token_preference.app_appearance_token_list_item_suffix_padding = value;
                        break;
                      }
                    }
                  }
                })

                SubItemDivider()

                SubItemSlider({
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  title: $r('app.string.token_font_slider'),
                  items: [
                    {
                      name: $r('app.string.token_font_size'),
                      default: this.token_preference.app_appearance_token_font_size,
                      min: 10,
                      max: 50,
                      step: 5
                    },
                    {
                      name: $r("app.string.token_font_weight"),
                      default: this.token_preference.app_appearance_token_font_weight,
                      min: 100,
                      max: 900,
                      step: 100
                    },
                    {
                      name: $r('app.string.token_issuer_font_size'),
                      default: this.token_preference.app_appearance_issuer_font_size,
                      min: 10,
                      max: 30,
                      step: 5
                    },
                    {
                      name: $r('app.string.token_issuer_font_weight'),
                      default: this.token_preference.app_appearance_issuer_font_weight,
                      min: 100,
                      max: 900,
                      step: 100
                    },
                    {
                      name: $r('app.string.token_user_name_font_size'),
                      default: this.token_preference.app_appearance_user_name_font_size,
                      min: 5,
                      max: 30,
                      step: 5
                    },
                    {
                      name: $r('app.string.token_user_name_font_weight'),
                      default: this.token_preference.app_appearance_user_name_font_weight,
                      min: 100,
                      max: 900,
                      step: 100
                    },
                  ],
                  description: $r('app.string.token_item_font_desc'),
                  onChange: (index, value) => {
                    switch (index) {
                      case 0: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_FONT_SIZE, value);
                        this.token_preference.app_appearance_token_font_size = value;
                        break;
                      }
                      case 1: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_FONT_WEIGHT, value);
                        this.token_preference.app_appearance_token_font_weight = value;
                        break;
                      }
                      case 2: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ISSUER_FONT_SIZE, value);
                        this.token_preference.app_appearance_issuer_font_size = value;
                        break;
                      }
                      case 3: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ISSUER_FONT_WEIGHT, value);
                        this.token_preference.app_appearance_issuer_font_weight = value;
                        break;
                      }
                      case 4: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_USER_NAME_FONT_SIZE, value);
                        this.token_preference.app_appearance_user_name_font_size = value;
                        break;
                      }
                      case 5: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_USER_NAME_FONT_WEIGHT, value);
                        this.token_preference.app_appearance_user_name_font_weight = value;
                        break;
                      }
                    }
                  }
                })

              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            ListItem() {
              SettingItem({ title: $r('app.string.custom_decoration_color') }) {
                SubItemColor({
                  icon: $r('sys.symbol.paintpalette'),
                  title: $r('app.string.custom_color_palette'),
                  description: $r('app.string.custom_color_palette_des'),
                  colors: [
                    {
                      name: $r('app.string.custom_color_logo_background'),
                      color: this.token_preference.app_appearance_logo_background_color,
                    },
                    {
                      name: $r('app.string.custom_color_logo_dark_filter_color'),
                      color: this.token_preference.app_appearance_logo_dark_filter_color,
                    },
                    {
                      name: $r('app.string.custom_color_token_color'),
                      color: this.token_preference.app_appearance_token_color,
                    },
                    {
                      name: $r('app.string.custom_color_token_next_color'),
                      color: this.token_preference.app_appearance_token_next_color,
                    },
                    {
                      name: $r('app.string.custom_color_token_color_dark'),
                      color: this.token_preference.app_appearance_token_color_dark,
                    },
                    {
                      name: $r('app.string.custom_color_token_next_color_dark'),
                      color: this.token_preference.app_appearance_token_next_color_dark,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_light_color_start'),
                      color: this.token_preference.app_appearance_token_counter_light_color_start,
                    },
                    {
                      name: $r('app.string.custom_color_token_next_counter_light_color_end'),
                      color: this.token_preference.app_appearance_token_counter_light_color_end,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_dark_color_start'),
                      color: this.token_preference.app_appearance_token_counter_dark_color_start,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_dark_color_end'),
                      color: this.token_preference.app_appearance_token_counter_dark_color_end,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_next_light_color_start'),
                      color: this.token_preference.app_appearance_token_counter_next_light_color_start,
                    },
                    {
                      name: $r('app.string.custom_color_token_next_counter_next_light_color_end'),
                      color: this.token_preference.app_appearance_token_counter_next_light_color_end,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_next_dark_color_start'),
                      color: this.token_preference.app_appearance_token_counter_next_dark_color_start,
                    },
                    {
                      name: $r('app.string.custom_color_token_counter_next_dark_color_end'),
                      color: this.token_preference.app_appearance_token_counter_next_dark_color_end,
                    },
                  ],
                  onChange: (index, value) => {
                    switch (index) {
                      case 0: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_COLOR, value);
                        this.token_preference.app_appearance_logo_background_color = value;
                        break;
                      }
                      case 1: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER_COLOR, value);
                        this.token_preference.app_appearance_logo_dark_filter_color = value;
                        break;
                      }
                      case 2: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR, value);
                        this.token_preference.app_appearance_token_color = value;
                        break;
                      }
                      case 3: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR, value);
                        this.token_preference.app_appearance_token_next_color = value;
                        break;
                      }
                      case 4: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR_DARK, value);
                        this.token_preference.app_appearance_token_color_dark = value;
                        break;
                      }
                      case 5: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR_DARK, value);
                        this.token_preference.app_appearance_token_next_color_dark = value;
                        break;
                      }
                      case 6: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_START, value);
                        this.token_preference.app_appearance_token_counter_light_color_start = value;
                        break;
                      }
                      case 7: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_END, value);
                        this.token_preference.app_appearance_token_counter_light_color_end = value;
                        break;
                      }
                      case 8: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_START, value);
                        this.token_preference.app_appearance_token_counter_dark_color_start = value;
                        break;
                      }
                      case 9: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_END, value);
                        this.token_preference.app_appearance_token_counter_dark_color_end = value;
                        break;
                      }
                      case 10: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_START, value);
                        this.token_preference.app_appearance_token_counter_next_light_color_start = value;
                        break;
                      }
                      case 11: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_END, value);
                        this.token_preference.app_appearance_token_counter_next_light_color_end = value;
                        break;
                      }
                      case 12: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_START, value);
                        this.token_preference.app_appearance_token_counter_next_dark_color_start = value;
                        break;
                      }
                      case 13: {
                        AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_END, value);
                        this.token_preference.app_appearance_token_counter_next_dark_color_end = value;
                        break;
                      }
                    }
                  }
                })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            ListItem() {
              SettingItem({ title: $r('app.string.custom_appearance_cmd') }) {
                SubItemButton({
                  symbol: $r('sys.symbol.arrow_counterclockwise'),
                  text: $r('app.string.appearance_reset_to_default'),
                })
                  .onClick(() => {
                    AppPreference.resetAppearanceToDefault();
                  })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            ListItem()
              .height(this.window.AvoidBottomHeight + 56) // 56: navigation_height
          }
          .layoutWeight(1)
          .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .scrollBar(BarState.Off)

        }
        .padding({ top: 16 })
        .width('100%')
        .height('100%')
      }
    }
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
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.app_appearance'),
        },
      }
    })
    .bindToScrollable([this.scroller])
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}