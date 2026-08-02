
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
      Column() {
        if (this.subItemBuilder) {
          this.subItemBuilder();
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      // 分组背景是分组列表唯一的不透明层，Phase 3 由 MaterialSurface 接管；
      // 子项背景须保持透明，不使用阴影（与材质表面冲突）
      .backgroundColor($r('app.color.item_bg'))
      .borderRadius(SETTING_GROUP_RADIUS)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
