import {
  BottomBuilderShowType,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  AppStorageV2,
  SegmentButtonV2ItemOptions,
  SegmentButtonV2Items,
  TabSegmentButtonV2,
  uiMaterial
} from '@kit.ArkUI';
import { IconPicker } from 'uikit';
import { AegisIconPack, AppWindowInfo, TokenIconPacks } from 'common';
import { MaterialTheme, MaterialThickness } from '../components/MaterialTheme';
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
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private iconScrollers: Scroller[] = createIconScrollers();
  private packSegmentItems: SegmentButtonV2Items = createIconPackSegmentItems();

  /**
   * SegmentButtonV2 背景板材质跟随全局材质偏好。
   * API 26 应用级 ENABLE 会让 SegmentButtonV2 默认启用材质，因此实体模式下
   * 必须显式传 Material.empty；低 API/无能力设备不求值 uiMaterial 符号。
   */
  private segmentBackgroundMaterial(): uiMaterial.Material | undefined {
    if (MaterialPolicy.getInstance().getTier() !== 'immersive') {
      return undefined;
    }
    if (!MaterialTheme.isImmersiveEffective()) {
      return uiMaterial.Material.empty;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: this.mapMaterialThickness(MaterialTheme.preferredThickness()),
      colorInvert: true,
      interactive: true
    });
  }

  /** MaterialThickness → uiMaterial.ImmersiveStyle（仅 API 26 材质分支调用）。 */
  private mapMaterialThickness(thickness: MaterialThickness): uiMaterial.ImmersiveStyle {
    switch (thickness) {
      case MaterialThickness.ULTRA_THIN:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      case MaterialThickness.THIN:
        return uiMaterial.ImmersiveStyle.THIN;
      case MaterialThickness.THICK:
        return uiMaterial.ImmersiveStyle.THICK;
      case MaterialThickness.ULTRA_THICK:
        return uiMaterial.ImmersiveStyle.ULTRA_THICK;
      case MaterialThickness.REGULAR:
      default:
        return uiMaterial.ImmersiveStyle.REGULAR;
    }
  }

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
    .height(56)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
  }

  @LocalBuilder
  PackSegmentBuilder() {
    Column() {
      TabSegmentButtonV2({
        items: this.packSegmentItems,
        selectedIndex: this.currentPackIndex,
        backgroundSystemMaterial: this.segmentBackgroundMaterial(),
        $selectedIndex: (index: number) => {
          this.currentPackIndex = index;
          this.iconScrollers[index]?.scrollTo({ xOffset: 0, yOffset: 0 });
        }
      })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
  }

  @LocalBuilder
  TitleBottomBuilder() {
    Column() {
      this.SearchBottomBuilder()
      if (TokenIconPacks.aegis_icon_packs.length > 0) {
        this.PackSegmentBuilder()
      }
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      HdsNavigation() {
        PageScaffold({ avoidBottom: true }) {
        IconPicker({
          issuer: this.pageParams.issuer,
          currentIconPath: this.pageParams.currentIconPath,
          showCancelButton: false,
          showSearch: false,
          showPackTabs: false,
          currentPackIndex: this.currentPackIndex,
          immersiveMaterialEnabled: MaterialTheme.isImmersiveEffective(),
          iconScrollers: this.iconScrollers,
          searchText: this.iconSearchText,
          confirm: (path: string) => this.completeSelection(path)
        })
          .width('100%')
          .layoutWeight(1)
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .mode(NavigationMode.Stack)
    .hideBackButton(false)
    .titleMode(HdsNavigationTitleMode.MINI)
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
        backIcon: {
          label: $r('app.string.dialog_btn_cancel'),
          icon: $r('sys.symbol.chevron_left'),
          action: () => this.pageInfos?.pop()
        },
        title: { mainTitle: $r('app.string.add_token_choose_icon') },
        bottomBuilder: {
          builder: (): void => this.TitleBottomBuilder(),
          height: TokenIconPacks.aegis_icon_packs.length > 0 ? 112 : 56,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    .bindToScrollable(this.iconScrollers)
    }
    .clip(false)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.window_background'))
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
  }
}
