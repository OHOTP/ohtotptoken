import { LengthMetrics } from '@kit.ArkUI';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING } from './SettingStyle';

@Preview
@ComponentV2
export struct SubItemButton {
  @Param symbol: Resource | undefined = $r('sys.symbol.tip_fit_test');
  @Param icon: Resource | undefined = undefined;
  @Require @Param text: ResourceStr | string = 'TEST';
  @Param description: string  | Resource = '';
  @Param descriptionColor: ResourceColor = $r('sys.color.ohos_id_color_text_secondary');
  /** 副标题最大行数，默认 2 行超出省略；传 0 表示不限制行数、完整展示全部文字 */
  @Param descriptionMaxLines: number = 2;

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 10 }) {
            if (this.icon !== undefined) {
              Image(this.icon)
                .width(LengthMetrics.vp(20).value)
                .height(LengthMetrics.vp(20).value)
                .fillColor($r('app.color.str_main'))
                .supportSvg2(true)
            } else {
              SymbolGlyph(this.symbol)
                .fontSize(LengthMetrics.vp(20).value)
                .fontWeight(FontWeight.Medium)
                .fontColor([$r('app.color.str_main')])
            }
            Text(this.text)
              .fontSize($r('sys.float.ohos_id_text_size_body1'))
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .fontWeight(FontWeight.Regular)
              .textAlign(TextAlign.Start)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          
          if (this.description != '') {
            if (this.descriptionMaxLines > 0) {
              Text(this.description)
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontColor(this.descriptionColor)
                .fontWeight(FontWeight.Regular)
                .fontFamily('HarmonyHeiTi')
                .lineHeight(19)
                .textAlign(TextAlign.Start)
                .maxLines(this.descriptionMaxLines)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              // 不设 maxLines：超长自动换行完整显示（官方 arkts-text-faq 推荐做法）
              Text(this.description)
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontColor(this.descriptionColor)
                .fontWeight(FontWeight.Regular)
                .fontFamily('HarmonyHeiTi')
                .lineHeight(19)
                .textAlign(TextAlign.Start)
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .justifyContent(FlexAlign.Start)
    }
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)

  }
}
