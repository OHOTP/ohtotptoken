import { TokenIcon } from 'uikit';
import { MaterialSurface } from './MaterialSurface';
import { MaterialTheme, MaterialThickness } from './MaterialTheme';

/** 添加令牌页面统一视觉常量：克制、清晰、适合表单，不复用旧 Dialog 布局。 */
export const ADD_TOKEN_PAGE_INSET: number = 16;
export const ADD_TOKEN_SECTION_RADIUS: number = 16;
export const ADD_TOKEN_SECTION_PADDING: number = 16;
export const ADD_TOKEN_FIELD_GAP: number = 8;

/**
 * 添加令牌页统一操作按钮。
 *
 * 实体档保持蓝底白字；沉浸档由 MaterialSurface 切换为系统材质，并跟随
 * 设置页的材质模式、厚度和光源反馈选项。Button 自身背景在沉浸档透明，
 * 避免遮住材质层。
 */
@Preview
@ComponentV2
export struct AddTokenActionButton {
  @Require @Param text: ResourceStr = '';
  @Param buttonEnabled: boolean = true;
  @Param loading: boolean = false;
  @Event action: () => void = () => {};

  build() {
    MaterialSurface({
      thickness: MaterialThickness.THIN,
      interactive: this.buttonEnabled,
      lightEffect: this.buttonEnabled,
      materialColor: this.buttonEnabled ? $r('app.color.button_blue') : Color.Gray,
      radius: 24,
      solidColor: Color.Transparent
    }) {
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
      .backgroundColor(MaterialTheme.surfaceBackground(
        this.buttonEnabled ? $r('app.color.button_blue') : Color.Gray))
      .stateEffect(false)
      .enabled(this.buttonEnabled)
      .onClick(() => this.action())
    }
  }
}

@Preview
@ComponentV2
export struct AddTokenHeader {
  @Require @Param title: ResourceStr = '';
  @Require @Param description: ResourceStr = '';
  @Require @Param issuer: string = '';
  @Param iconPath: string = '';
  @Event onIconClick: () => void = () => {};

  build() {
    Row({ space: 16 }) {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        TokenIcon({ issuer: this.issuer, icon_path: this.iconPath })
      }
      .width(64)
      .height(64)
      .padding(0)
      .borderRadius(16)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.onIconClick())
      .accessibilityText($r('app.string.add_token_choose_icon'))

      Column({ space: 6 }) {
        Text(this.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text(this.description)
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(20)
          .maxLines(3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
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
        .placeholderColor($r('sys.color.font_tertiary'))
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
