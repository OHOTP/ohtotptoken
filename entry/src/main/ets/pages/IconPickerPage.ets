import { HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { IconPicker } from 'uikit';
import { PageScaffold } from '../components/PageScaffold';
import { MaterialPolicy } from '../utils/MaterialPolicy';

/** 添加/编辑令牌页打开图标选择页时使用的路由参数。 */
export class IconPickerPageParams {
  issuer: string = '';
  currentIconPath: string = '';
  onSelected: (path: string) => void = () => {};

  constructor(issuer: string = '', currentIconPath: string = '', onSelected: (path: string) => void = () => {}) {
    this.issuer = issuer;
    this.currentIconPath = currentIconPath;
    this.onSelected = onSelected;
  }
}

@Entry
@Preview
@ComponentV2
export struct IconPickerPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param pageParams: IconPickerPageParams = new IconPickerPageParams();

  private pageInfos: NavPathStack | null = null;

  private completeSelection(path: string): void {
    this.pageParams.onSelected(path);
    this.pageInfos?.pop();
  }

  build() {
    HdsNavDestination() {
      PageScaffold({ avoidBottom: true }) {
        IconPicker({
          issuer: this.pageParams.issuer,
          currentIconPath: this.pageParams.currentIconPath,
          showCancelButton: false,
          confirm: (path: string) => this.completeSelection(path)
        })
          .width('100%')
          .height('100%')
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            backIconStyle: { iconColor: $r('sys.color.icon_primary') },
            menuStyle: { iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: {
        title: { mainTitle: $r('app.string.add_token_choose_icon') }
      }
    })
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
  }
}
