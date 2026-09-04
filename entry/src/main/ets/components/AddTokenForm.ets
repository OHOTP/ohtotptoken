import { dialogSystemMaterial } from 'common';
import { AppPreference, PREF_KEYS, TokenConfig } from 'common';
import { TokenIcon } from 'uikit';
import { TokenSwitchTrace } from '../utils/TokenSwitchPerf';

/** 添加令牌页面统一视觉常量：克制、清晰、适合表单，不复用旧 Dialog 布局。 */
export const ADD_TOKEN_PAGE_INSET: number = 16;
export const ADD_TOKEN_SECTION_RADIUS: number = 16;
export const ADD_TOKEN_SECTION_PADDING: number = 16;
export const ADD_TOKEN_FIELD_GAP: number = 8;
/** 底部操作按钮距屏幕底部的留白，取官方设计指南「间隔参数」屏幕底部边距推荐值（手机/折叠屏/平板均为 28vp）。 */
export const ADD_TOKEN_BOTTOM_ACTION_INSET: number = 28;

/** 添加/编辑令牌页面的统一路由参数。 */
export class AddTokenPageParams {
  initialUri: string = '';
  editConfig?: TokenConfig = undefined;
  switchTrace?: TokenSwitchTrace = undefined;
  responsiveEdit: boolean = false;

  constructor(initialUri: string = '', editConfig?: TokenConfig, switchTrace?: TokenSwitchTrace,
    responsiveEdit: boolean = false) {
    this.initialUri = initialUri;
    this.editConfig = editConfig;
    this.switchTrace = switchTrace;
    this.responsiveEdit = responsiveEdit;
  }
}

/**
 * 添加令牌页统一操作按钮。
 *
 * 内容区按钮不在沉浸光感生效范围，保持蓝底白字。
 */
@Preview
@ComponentV2
export struct AddTokenActionButton {
  @Require @Param text: ResourceStr = '';
  @Param buttonEnabled: boolean = true;
  @Param loading: boolean = false;
  @Event action: () => void = () => {};

  build() {
    Button() {
      Row({ space: 8 }) {
        if (this.loading) {
          LoadingProgress().width(20).height(20).color(Color.White)
        }
        Text(this.text)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
      }
    }
    .type(ButtonType.ROUNDED_RECTANGLE)
    .width('100%')
    .height(48)
    .backgroundColor(this.buttonEnabled ? $r('app.color.button_blue') : Color.Gray)
    .stateEffect(false)
    .enabled(this.buttonEnabled)
    .onClick(() => this.action())
  }
}

@Preview
@ComponentV2
export struct AddTokenHeader {
  @Require @Param issuer: string = '';
  @Param iconPath: string = '';
  @Event onIconClick: () => void = () => {};

  @Local iconGuidePopup: boolean = false;
  private iconGuideInitialized: boolean = false;

  onDidBuild(): void {
    if (this.iconGuideInitialized) {
      return;
    }
    this.iconGuideInitialized = true;
    if (AppPreference.getPreference(PREF_KEYS.SHOW_ADD_TOKEN_ICON_GUIDE) as boolean) {
      // 官方建议页面构建完成后再显示 Popup，避免定位或形状异常。
      this.iconGuidePopup = true;
    }
  }

  private dismissIconGuide(): void {
    AppPreference.setPreference(PREF_KEYS.SHOW_ADD_TOKEN_ICON_GUIDE, false);
    this.iconGuidePopup = false;
  }

  build() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        TokenIcon({ issuer: this.issuer, icon_path: this.iconPath, displaySize: 80 })
      }
      .width(96)
      .height(96)
      .padding(0)
      .borderRadius(24)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.dismissIconGuide();
        this.onIconClick();
      })
      .accessibilityText($r('app.string.add_token_choose_icon'))
      .bindPopup(this.iconGuidePopup, {
        systemMaterial: dialogSystemMaterial(),
        placement: Placement.Bottom,
        message: this.getUIContext().getHostContext()?.resourceManager
          .getStringSync($r('app.string.add_token_icon_guide').id),
        onStateChange: (event) => {
          if (!event.isVisible) {
            this.iconGuidePopup = false;
          }
        },
        primaryButton: {
          value: this.getUIContext().getHostContext()?.resourceManager
            .getStringSync($r('app.string.add_token_icon_guide_confirm').id),
          action: () => this.dismissIconGuide()
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }
}

@Preview
@ComponentV2
export struct AddTokenTextField {
  @Require @Param label: ResourceStr = '';
  @Require @Param value: string = '';
  @Param helper: ResourceStr | undefined = undefined;
  @Param inputType: InputType = InputType.Normal;
  @Param maxLength: number = 256;
  @Param fieldEnabled: boolean = true;
  @Event onChange: (value: string) => void = () => {};

  build() {
    Column({ space: ADD_TOKEN_FIELD_GAP }) {
      Text(this.label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
      TextInput({ text: this.value, placeholder: this.label })
        .type(this.inputType)
        .enabled(this.fieldEnabled)
        .maxLength(this.maxLength)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .placeholderFont({ size: 14 })
        .placeholderColor($r('sys.color.font_tertiary'))
        .borderRadius(0)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .width('100%')
        .onChange((value: string) => this.onChange(value))
      if (this.helper !== undefined) {
        Text(this.helper)
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('sys.color.font_tertiary'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Preview
@ComponentV2
export struct AddTokenSectionTitle {
  @Require @Param text: ResourceStr = '';

  build() {
    Text(this.text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 4 })
  }
}
