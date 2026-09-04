import { SETTING_GROUP_RADIUS, SETTING_TITLE_INSET_LEFT, SETTING_TITLE_INSET_VERTICAL } from './SettingStyle';

@Builder
function DefaultBuilder() {
  Text('Empty');
}

@Preview
@ComponentV2
export struct SettingItem {
  @BuilderParam subItemBuilder?: CustomBuilder = DefaultBuilder;
  @Require @Param title: ResourceStr | string = '';

  build() {
    Column() {
      if (this.title != '') {
        Text(this.title)
          .padding({
            left: SETTING_TITLE_INSET_LEFT,
            top: SETTING_TITLE_INSET_VERTICAL,
            bottom: SETTING_TITLE_INSET_VERTICAL
          })
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      // 内容区分组保留实体背景；材质直接应用于受支持的子控件。
      Column() {
        if (this.subItemBuilder) {
          this.subItemBuilder();
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .borderRadius(SETTING_GROUP_RADIUS)
      .backgroundColor($r('app.color.item_bg'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
