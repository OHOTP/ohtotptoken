import {
  BottomBuilderShowType,
  HideMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  SegmentButtonV2ItemOptions,
  SegmentButtonV2Items,
  TabSegmentButtonV2,
  uiMaterial
} from '@kit.ArkUI';
import { IconPicker } from 'uikit';
import { AegisIconPack, TokenIconPacks } from 'common';
import { MaterialTheme } from '../components/MaterialTheme';
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

function createIconScrollers(): Scroller[] {
  const scrollers: Scroller[] = [new Scroller()];
  TokenIconPacks.aegis_icon_packs.forEach(() => scrollers.push(new Scroller()));
  return scrollers;
}

function createIconPackSegmentItems(): SegmentButtonV2Items {
  const items: SegmentButtonV2ItemOptions[] = [{ text: TokenIconPacks.default_icon_pack.name }];
  TokenIconPacks.aegis_icon_packs.forEach((iconPack: AegisIconPack) => {
    items.push({ text: iconPack.name });
  });
  return new SegmentButtonV2Items(items);
}

@Entry
@Preview
@ComponentV2
export struct IconPickerPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param pageParams: IconPickerPageParams = new IconPickerPageParams();
  @Local iconSearchText: string = '';
  @Local currentPackIndex: number = 0;

  private pageInfos: NavPathStack | null = null;
  private iconScrollers: Scroller[] = createIconScrollers();
  private packSegmentItems: SegmentButtonV2Items = createIconPackSegmentItems();

  private completeSelection(path: string): void {
    this.pageParams.onSelected(path);
    this.pageInfos?.pop();
  }

  @LocalBuilder
  SearchBottomBuilder() {
    Column() {
      if (MaterialTheme.isImmersiveEffective()) {
        Search({
          placeholder: $r('app.string.dialog_icon_search_placeholder'),
          value: this.iconSearchText
        })
          .width('100%')
          .backgroundColor(Color.Transparent)
          .systemMaterial(new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            lightEffect: { color: Color.White }
          }))
          .onChange((value: string) => {
            this.iconSearchText = value;
          })
          .onSubmit((value: string) => {
            this.iconSearchText = value;
          })
      } else {
        Search({
          placeholder: $r('app.string.dialog_icon_search_placeholder'),
          value: this.iconSearchText
        })
          .width('100%')
          .onChange((value: string) => {
            this.iconSearchText = value;
          })
          .onSubmit((value: string) => {
            this.iconSearchText = value;
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @LocalBuilder
  PackSegmentBuilder() {
    Column() {
      TabSegmentButtonV2({
        items: this.packSegmentItems,
        selectedIndex: this.currentPackIndex,
        $selectedIndex: (index: number) => {
          this.currentPackIndex = index;
          this.iconScrollers[index]?.scrollTo({ xOffset: 0, yOffset: 0 });
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    HdsNavDestination() {
      PageScaffold({ avoidBottom: true }) {
        if (TokenIconPacks.aegis_icon_packs.length > 0) {
          this.PackSegmentBuilder()
        }

        IconPicker({
          issuer: this.pageParams.issuer,
          currentIconPath: this.pageParams.currentIconPath,
          showCancelButton: false,
          showSearch: false,
          showPackTabs: false,
          currentPackIndex: this.currentPackIndex,
          iconScrollers: this.iconScrollers,
          searchText: this.iconSearchText,
          confirm: (path: string) => this.completeSelection(path)
        })
          .width('100%')
          .layoutWeight(1)
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
        title: { mainTitle: $r('app.string.add_token_choose_icon') },
        bottomBuilder: {
          builder: (): void => this.SearchBottomBuilder(),
          height: 56,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    .bindToScrollable(this.iconScrollers)
    .dynamicHideTitleBar({
      hideTitleArea: false,
      hideBottomBuilder: true,
      hideStatusBar: false,
      mode: HideMode.SCROLL_UP_TO
    })
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
  }
}
