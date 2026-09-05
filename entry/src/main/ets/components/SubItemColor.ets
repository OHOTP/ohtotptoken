import { ColorSelectDialog } from "../dialogs/ColorSelectDialog";
import { dialogSystemMaterial, colorHex, hexColor } from 'common';
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
  @Param description: string | Resource = '';

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
    });
    this.dialog_color_picker.open();
  }

  build() {
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
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        ForEach(this.colors, (color: ColorItem, index: number) => {
          Row({ space: 8 }) {
            if (this.colors.length > 1) {
              Text(color.name)
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.isHdsColorPickerAvailable()) {
              Row() {
                HdsColorPicker({
                  initialColor: colorHex(color.color),
                  options: { circleRadius: 16 },
                  onColorSelected: (selectedColor: string) => {
                    const normalizedColor = selectedColor.startsWith('#') ?
                      selectedColor : `#${selectedColor}`;
                    this.onChange(index, hexColor(normalizedColor));
                  }
                })
              }
              .constraintSize({ minWidth: 48, minHeight: 48 })
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
            } else {
              Button({ type: ButtonType.Normal }) {
                Row()
                  .width(32)
                  .height(32)
                  .backgroundColor(color.color)
                  .borderRadius($r('sys.float.corner_radius_level2'))
                  .border({ width: 1, color: $r('sys.color.comp_divider') })
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .accessibilityText(typeof color.name === 'string' ? color.name :
                this.getUIContext().getHostContext()!.resourceManager.getStringSync(color.name.id))
              .onClick(() => this.openLegacyColorPicker(color.color, index))
            }
          }
          .alignItems(VerticalAlign.Center)
        }, (_color: ColorItem, index: number) => index.toString())
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .alignItems(VerticalAlign.Center)
    .enabled(!this.disable)
    .opacity(this.disable ? 0.4 : 1)
  }
}
