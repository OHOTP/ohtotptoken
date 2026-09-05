import { AppStorageV2, CapsuleSegmentButtonV2, ColorMetrics, LengthMetrics,
  SegmentButtonV2ItemOptions, SegmentButtonV2Items, uiMaterial } from '@kit.ArkUI';
import { ALL_TOKEN_GROUPS, MaterialPreference, TokenGroupState, TokenGroupStore } from 'common';
import { MaterialTheme } from './MaterialTheme';

/** 必须位于 HdsNavigation.titleBar.content.bottomBuilder 内，材质才会生效。 */
@ComponentV2
export struct TokenGroupBar {
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;
  @Local material: MaterialPreference = AppStorageV2.connect(MaterialPreference, () => new MaterialPreference())!;
  @Local availableWidth: number = 0;
  @Event onSelect: (id: string) => void = () => {};

  @Computed
  get items(): SegmentButtonV2Items {
    const options: SegmentButtonV2ItemOptions[] = [
      { text: $r('app.string.token_group_all') },
      { text: $r('app.string.token_group_ungrouped') }
    ];
    for (const group of this.state.groups) {
      options.push({ text: group.name, accessibilityText: group.name });
    }
    return new SegmentButtonV2Items(options);
  }

  @Computed
  get selectedIndex(): number {
    if (this.state.selectedId === ALL_TOKEN_GROUPS) {
      return 0;
    }
    return this.state.selectedId === '' ? 1 :
      Math.max(0, this.state.groups.findIndex(group => group.id === this.state.selectedId) + 2);
  }

  private select(index: number): void {
    if (index < 0 || index >= this.state.groups.length + 2) {
      return;
    }
    this.onSelect(index === 0 ? ALL_TOKEN_GROUPS : index === 1 ? '' : this.state.groups[index - 2].id);
  }

  @Computed
  get backgroundMaterial(): uiMaterial.Material | undefined {
    // 直接读取响应式设置，厚度、交互和光感变化均重算材质实参。
    this.material.app_appearance_immersive_style;
    this.material.app_appearance_immersive_interactive;
    this.material.app_appearance_immersive_light_effect;
    this.material.app_appearance_material_shadow;
    this.material.app_appearance_material_color;
    this.material.app_appearance_light_color;
    this.material.app_appearance_immersive_enable;
    return MaterialTheme.systemMaterial(true) as uiMaterial.Material | undefined;
  }

  build() {
    Scroll() {
      if (MaterialTheme.supportsNativeMaterial()) {
        CapsuleSegmentButtonV2({
          items: this.items,
          selectedIndex: this.selectedIndex,
          $selectedIndex: (index: number) => this.select(index),
          itemMinHeight: LengthMetrics.vp(44),
          itemMaxFontScale: 1.3,
          itemFontColor: ColorMetrics.resourceColor($r('sys.color.font_primary')),
          backgroundSystemMaterial: this.backgroundMaterial
        })
        .width(Math.max(this.availableWidth, this.items.length * 112))
      } else {
        CapsuleSegmentButtonV2({
          items: this.items,
          selectedIndex: this.selectedIndex,
          $selectedIndex: (index: number) => this.select(index),
          itemMinHeight: LengthMetrics.vp(44),
          itemMaxFontScale: 1.3
        })
        .width(Math.max(this.availableWidth, this.items.length * 112))
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
    .onAreaChange((_oldArea: Area, area: Area) => {
      this.availableWidth = Math.max(0, Number(area.width) - 32);
    })
  }
}
