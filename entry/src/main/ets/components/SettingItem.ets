import { SETTING_TITLE_INSET_LEFT, SETTING_TITLE_INSET_VERTICAL } from './SettingStyle';
import { MaterialSurface } from './MaterialSurface';

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
      // 分组背景是分组列表唯一的背景层（Phase 5.3 起由 MaterialSurface 接管：
      // 沉浸档渲染 ImmersiveMaterial，其余档位回落 item_bg 实体色；
      // 圆角/实体色均取 MaterialSurface 默认值），子项背景须保持透明，
      // 不使用阴影（与材质表面冲突）
      MaterialSurface() {
        Column() {
          if (this.subItemBuilder) {
            this.subItemBuilder();
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
