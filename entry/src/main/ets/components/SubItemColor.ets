import { ColorSelectDialog } from "../dialogs/ColorSelectDialog";
import { dialogSystemMaterial, colorHex, hexColor, DeviceInfoHelper } from 'common';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsColorPickerHostModule, HdsColorPickerParams } from './HdsColorPickerTypes';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

export class ColorItem {
  name: ResourceStr = '';
  color: number = 0;
}

@Preview
@ComponentV2
export struct SubItemColor {
  @Require @Param onChange: (index: number, color: number) => void = () => {};
  @Require @Param title: string | Resource = '';
  @Require @Param colors: ColorItem[] = [{name: "a", color: 0}];
  @Param disable: boolean = false;
  @Param icon: Resource | undefined = undefined;
  @Param description: string | Resource = '';
  @Param rowPadding: Padding = SETTING_ROW_PADDING;
  @Param expandable: boolean = false;
  @Local collapsed: boolean = true;
  /**
   * HDS 拾色器宿主：仅在 phone/tablet 上通过动态 import 装载；PC 上保持 undefined，
   * 走 openLegacyColorPicker(ColorSelectDialog)。**不可改成静态 import**：
   * 2in1 的 @kit.UIDesignKit 不导出 HdsColorPicker，静态加载即 SyntaxError 杀进程。
   */
  @Local hdsPicker: WrappedBuilder<[HdsColorPickerParams]> | undefined = undefined;

  private dialog_color_picker?: CustomDialogController;

  aboutToAppear(): void {
    this.loadHdsPicker();
  }

  /** 按设备能力懒加载 HdsColorPicker 宿主；任何失败都回退到旧拾色器 */
  private async loadHdsPicker(): Promise<void> {
    if (this.hdsPicker !== undefined || !this.isHdsColorPickerAvailable()) {
      return;
    }
    try {
      const host: HdsColorPickerHostModule = await import('./HdsColorPickerHost');
      this.hdsPicker = host.hdsColorPickerHost;
    } catch (_) {
      this.hdsPicker = undefined;
    }
  }

  private isHdsColorPickerAvailable(): boolean {
    // HdsColorPicker 仅 phone/tablet 提供导出（见 SDK UIDesignKit.json 的 deviceTypes），
    // 2in1 上加载会抛 SyntaxError，必须显式排除。
    return !DeviceInfoHelper.getInstance().isPc() &&
      deviceInfo.apiAvailable('26.0.0') &&
      canIUse('SystemCapability.UIDesign.HDSPattern.Standard');
  }

  /** 为第 index 个色块构造 HDS 拾色器入参 */
  private hdsPickerParams(index: number): HdsColorPickerParams {
    const params = new HdsColorPickerParams();
    params.color = colorHex(this.colors[index].color);
    params.onSelected = (selectedColor: string): void => {
      const normalizedColor = selectedColor.startsWith('#') ? selectedColor : `#${selectedColor}`;
      this.onChange(index, hexColor(normalizedColor));
    };
    return params;
  }

  private openLegacyColorPicker(color: number, index: number): void {
    this.dialog_color_picker = new CustomDialogController({
      systemMaterial: dialogSystemMaterial(),
      builder: ColorSelectDialog({
        old_color: color,
        confirm: (new_color) => {
          this.onChange(index, new_color);
        }
      })
    });
    this.dialog_color_picker.open();
  }

  @Builder
  titleBuilder() {
      Column({ space: 4 }) {
        Row({ space: 10 }) {
          if (this.icon != undefined) {
            SymbolGlyph(this.icon)
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor([$r('app.color.str_main')])
          }
          Text(this.title)
            .fontSize($r('sys.float.ohos_id_text_size_body1'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .fontWeight(FontWeight.Regular)
            .textAlign(TextAlign.Start)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (this.description != '') {
          Text(this.description)
            .width('100%')
            .padding({ left: this.icon !== undefined ? SETTING_ROW_ICON_OFFSET : 0 })
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontFamily('HarmonyHeiTi')
            .lineHeight(19)
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  colorsBuilder() {
      Column({ space: 8 }) {
        // 索引键复用行时直接读取 @Param 数组，避免捕获已被替换的普通 ColorItem。
        ForEach(this.colors, (_color: ColorItem, index: number) => {
          Row({ space: 8 }) {
            if (this.expandable || this.colors.length > 1) {
              Text(this.colors[index].name)
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontColor($r('sys.color.font_secondary'))
                .layoutWeight(this.expandable ? 1 : 0)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.hdsPicker !== undefined) {
              this.hdsPicker!.builder(this.hdsPickerParams(index))
            } else {
              Button({ type: ButtonType.Normal }) {
                Row()
                  .width(32)
                  .height(32)
                  .backgroundColor(this.colors[index].color)
                  .borderRadius($r('sys.float.corner_radius_level2'))
                  .border({ width: 1, color: $r('sys.color.comp_divider') })
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .accessibilityText(typeof this.colors[index].name === 'string' ? this.colors[index].name as string :
                this.getUIContext().getHostContext()!.resourceManager.getStringSync((this.colors[index].name as Resource).id))
              .onClick(() => this.openLegacyColorPicker(this.colors[index].color, index))
            }
          }
          .width(this.expandable ? '100%' : undefined)
          .alignItems(VerticalAlign.Center)
        }, (_color: ColorItem, index: number) => index.toString())
      }
      .width(this.expandable ? '100%' : undefined)
      .alignItems(HorizontalAlign.End)
  }

  build() {
    Column() {
      if (this.expandable) {
        Row({ space: 12 }) {
          this.titleBuilder()
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontColor([$r('sys.color.font_tertiary')])
            .fontSize(24)
            .rotate({ angle: this.collapsed ? 0 : 90 })
            .translate(this.collapsed ? {} : { x: -3 })
        }
        .width('100%')
        .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
        .padding(this.rowPadding)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.getUIContext().animateTo({ duration: 200, curve: Curve.Sharp }, () => {
            this.collapsed = !this.collapsed;
          });
        })
        if (!this.collapsed) {
          Column() {
            this.colorsBuilder()
          }
          .width('100%')
          .padding(this.rowPadding)
        }
      } else {
        Row({ space: 12 }) {
          this.titleBuilder()
          this.colorsBuilder()
        }
        .width('100%')
        .padding(this.rowPadding)
        .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .enabled(!this.disable)
    .opacity(this.disable ? 0.4 : 1)
  }
}
