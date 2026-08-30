import { ColorSelectDialog } from "../dialogs/ColorSelectDialog";
import { AppWindowInfo, dialogSystemMaterial } from 'common';
import { colorHex, hexColor } from 'common';
import { AppStorageV2 } from "@kit.ArkUI";
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsColorPicker } from '@kit.UIDesignKit';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING } from './SettingStyle';

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
  @Param description: string  | Resource = '';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local collapsed: boolean = true;

  private dialog_color_picker?: CustomDialogController;

  private isHdsColorPickerAvailable(): boolean {
    return deviceInfo.apiAvailable('26.0.0') &&
      canIUse('SystemCapability.UIDesign.HDSPattern.Standard');
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
    })
    this.dialog_color_picker.open()
  }

  build() {
    Column() {
      Row({ space: 12 }) {
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
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .fontWeight(FontWeight.Regular)
              .fontFamily('HarmonyHeiTi')
              .lineHeight(19)
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontColor([$r('sys.color.font_tertiary')])
            .fontSize(24)
            .align(Alignment.Center)
            .rotate(this.collapsed ? { angle: 0 } : { angle: 90 })
            .translate(this.collapsed ? {} : { x: -3 })
        }
        .alignItems(VerticalAlign.Center)

      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.window.uiContext?.animateTo({ duration: 200, curve: Curve.Sharp }, () => {
          this.collapsed = !this.collapsed;
        })
      })
      if (!this.collapsed) {
        Blank()
          .height(10)
        Column({ space: 10 }) {
          ForEach(this.colors, (color: ColorItem, index: number) => {
            Row({ space: 10 }) {
              Text(color.name)
                .width('50%')
                .textOverflow({ overflow: TextOverflow.MARQUEE })
              if (this.isHdsColorPickerAvailable()) {
                Row() {
                  HdsColorPicker({
                    initialColor: colorHex(color.color),
                    options: {
                      circleRadius: 16
                    },
                    onColorSelected: (selectedColor: string) => {
                      const normalizedColor = selectedColor.startsWith('#') ?
                        selectedColor : `#${selectedColor}`;
                      this.onChange(index, hexColor(normalizedColor));
                    }
                  })
                }
                .layoutWeight(1)
                .justifyContent(FlexAlign.End)
                .alignItems(VerticalAlign.Center)
              } else {
                Text(colorHex(color.color))
                  .fontWeight(FontWeight.Medium)
                  .backgroundColor(color.color)
                  .textAlign(TextAlign.Center)
                  .textShadow({ color: Color.White, radius: 10 })
                  .borderRadius($r('sys.float.corner_radius_level2'))
                  .height(30)
                  .fontSize($r('sys.float.Subtitle_M'))
                  .fontColor(Color.Black)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.openLegacyColorPicker(color.color, index)
                  })
              }
            }
          }, (color: ColorItem, index: number) => {
            if (this.isHdsColorPickerAvailable()) {
              // 切换颜色时保持组件身份稳定，避免销毁正在使用的 HdsColorPicker。
              return index.toString();
            }
            return `${index}_${color.color}`;
          })
        }

      }
    }
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)
  }
}
