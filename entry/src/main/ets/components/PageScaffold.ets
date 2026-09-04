import { AppStorageV2 } from '@kit.ArkUI';
import { AppWindowInfo } from 'common';

@Builder
function EmptyBuilder() {
}

/**
 * 统一页面背景与安全区容器(Task 3.2)
 *
 * 集中管理 app.color.window_background 背景色与状态栏/导航条安全区内边距,
 * 各 NavDestination 页面的根容器统一使用本组件,避免每个页面各自重复设置。
 *
 * 注意:
 * - 本组件为非滚动容器;内部滚动组件(List/Grid/Scroll)若需在安全区内裁剪,
 *   请使用滚动组件自身的 clipContent(ContentClipMode.SAFE_AREA);
 * - 页面内容区不在沉浸光感生效范围，保留实体背景。
 */
@Preview
@ComponentV2
export struct PageScaffold {
  /** 页面背景色,默认统一窗口背景 */
  @Param bgColor: ResourceColor = $r('app.color.window_background');
  /** 是否避让顶部安全区(状态栏) */
  @Param avoidTop: boolean = false;
  /** 是否避让底部安全区(导航条) */
  @Param avoidBottom: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @BuilderParam content?: CustomBuilder = EmptyBuilder;

  build() {
    Column() {
      if (this.content) {
        this.content();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor)
    .padding({
      top: this.avoidTop ? this.window.AvoidTopHeight : 0,
      bottom: this.avoidBottom ? this.window.AvoidBottomHeight : 0
    })
  }
}
