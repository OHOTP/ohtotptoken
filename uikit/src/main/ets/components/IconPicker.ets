import { CropModel, CropView } from './ImageCropView';
import { getImageDimensions, savePixelMapToFile, copyFileToDir } from 'common';
import { showSelectFilePicker } from 'common';
import { AegisIconPack, TokenIconPacks } from 'common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { showSnackBar, SnackBarNotifyType } from 'common';

const MAX_ICON_SIZE = 256;

function extractIconName(path: string): string {
  const lastSep = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  let name = path.substring(lastSep + 1);
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    name = name.substring(0, dot);
  }
  return name.toLowerCase();
}

function getPickerImageSource(path: string): ResourceStr {
  const previewPath = TokenIconPacks.getPickerPreviewPath(path);
  if (previewPath.startsWith('rawfile://')) {
    return $rawfile(previewPath.slice(10));
  }
  return previewPath;
}

enum IconGridItemType {
  AUTO,
  ADD,
  USER,
  PACK
}

@ObservedV2
class IconGridItem {
  readonly key: string;
  readonly type: IconGridItemType;
  readonly path: string;
  readonly removable: boolean;

  constructor(key: string, type: IconGridItemType, path: string = '', removable: boolean = false) {
    this.key = key;
    this.type = type;
    this.path = path;
    this.removable = removable;
  }
}

function uniquePaths(paths: string[]): string[] {
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (const path of paths) {
    if (path !== undefined && !seen.has(path)) {
      seen.add(path);
      result.push(path);
    }
  }
  return result;
}

function createGridItems(packPaths: string[], userPaths: string[], includeUtilities: boolean): IconGridItem[] {
  const items: IconGridItem[] = [];
  if (includeUtilities) {
    items.push(new IconGridItem('__auto__', IconGridItemType.AUTO));
    items.push(new IconGridItem('__add__', IconGridItemType.ADD));
    for (const path of userPaths) {
      items.push(new IconGridItem(`user:${path}`, IconGridItemType.USER, path, true));
    }
  }
  for (const path of packPaths) {
    items.push(new IconGridItem(`pack:${path}`, IconGridItemType.PACK, path));
  }
  return items;
}

@ObservedV2
export class IconPickerViewState {
  @Trace searchText: string = '';
  @Trace packIndex: number = 0;
}

@Preview
@ComponentV2
export struct IconPicker {
  @Require @Param issuer: string = '';
  @Param currentIconPath: string = '';
  @Param showCancelButton: boolean = true;
  @Param showSearch: boolean = true;
  @Param showPackTabs: boolean = true;
  @Param currentPackIndex: number = 0;
  /**
   * 确认按钮是否启用沉浸光感材质（跟随设置里的材质模式选项）。
   * uikit 无法依赖 entry 侧 MaterialTheme，由调用方（entry 页面）求值后传入；
   * 默认 false 保持实体蓝底（未传入场景行为不变）。
   */
  @Param immersiveMaterialEnabled: boolean = false;
  @Param iconScrollers: Scroller[] = [];
  @Param searchText: string = '';
  @Param viewState: IconPickerViewState = new IconPickerViewState();
  @Event cancel: () => void = () => {};
  @Event confirm: (new_conf: string) => void = () => {};
  @Event onPackChange: (index: number) => void = () => {};

  @Local selectedIconPath: string = '';
  @Local showCropCover: boolean = false;
  @Local cropModel: CropModel = new CropModel();
  @Local pendingCropUri: string = '';
  @Local localSearchText: string = '';
  @Local activePackIndex: number = 0;
  @Local defaultIconPaths: string[] = [];
  @Local userIconPaths: string[] = [];
  @Local aegisIconPaths: string[][] = [];

  private defaultGridData: IconGridDataSource = new IconGridDataSource();
  private aegisGridData: IconGridDataSource[] = [];

  aboutToAppear(): void {
    this.selectedIconPath = this.currentIconPath;
    this.localSearchText = this.searchText;
    this.activePackIndex = this.currentPackIndex;

    const defaultIconPaths: string[] = [];
    TokenIconPacks.default_icon_pack.default_icon_pack_path.forEach((path: string) => {
      defaultIconPaths.push(path);
    });
    this.defaultIconPaths = uniquePaths(defaultIconPaths);
    this.userIconPaths = uniquePaths(TokenIconPacks.user_added_icon_packs.icon_path);
    this.aegisIconPaths = TokenIconPacks.aegis_icon_packs.map((aegisIconPack: AegisIconPack) => {
      const paths: string[] = [];
      for (const icon of aegisIconPack.icons) {
        for (const path of icon.icon_pack_path) {
          paths.push(path);
        }
      }
      return uniquePaths(paths);
    });
    this.aegisGridData = this.aegisIconPaths.map(() => new IconGridDataSource());
    this.refreshGridData();
  }

  @Monitor('viewState.searchText')
  onViewStateSearchChanged(_monitor: IMonitor): void {
    if (!this.showSearch) {
      this.refreshGridData();
    }
  }

  @Monitor('searchText')
  onSearchParamChanged(_monitor: IMonitor): void {
    if (!this.showSearch) {
      this.refreshGridData();
    }
  }

  private filterPaths(paths: string[], query: string): string[] {
    if (query === '') {
      return paths;
    }
    const q = query.toLowerCase();
    return paths.filter((path: string) => extractIconName(path).includes(q));
  }

  private currentSearchText(): string {
    return this.showSearch ? this.localSearchText : (this.viewState.searchText || this.searchText);
  }

  private currentPack(): number {
    return this.showPackTabs ? this.activePackIndex : this.viewState.packIndex;
  }

  private gridItemsFor(paths: string[]): IconGridItem[] {
    const query = this.currentSearchText();
    return createGridItems(this.filterPaths(paths, query), this.userIconPaths, query === '');
  }

  private refreshGridData(): void {
    this.defaultGridData.replaceData(this.gridItemsFor(this.defaultIconPaths));
    for (let index = 0; index < this.aegisIconPaths.length; index++) {
      if (index >= this.aegisGridData.length) {
        this.aegisGridData.push(new IconGridDataSource());
      }
      this.aegisGridData[index].replaceData(this.gridItemsFor(this.aegisIconPaths[index]));
    }
  }

  private updateSearchText(value: string): void {
    if (this.localSearchText !== value) {
      this.localSearchText = value;
      this.refreshGridData();
    }
  }

  @LocalBuilder
  ItemIconOverlay(path: string, removable: boolean) {
    Stack() {
      if (removable) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(LengthMetrics.vp(12).value)
            .fontColor([Color.White])
            .fontWeight(FontWeight.Medium)
            .rotate({ angle: 45 })
        }
        .backgroundColor(Color.Red)
        .width(LengthMetrics.vp(18).value)
        .height(LengthMetrics.vp(18).value)
        .align(Alignment.BottomStart)
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            message: $r('app.string.icon_alert_remove_confirm_msg'),
            autoCancel: true,
            alignment: DialogAlignment.Center,
            primaryButton: {
              defaultFocus: false,
              value: $r('app.string.dialog_btn_cancel'),
              action: () => {
                return
              }
            },
            secondaryButton: {
              value: $r('app.string.dialog_btn_confirm'),
              fontColor: Color.Red,
              action: () => {
                TokenIconPacks.user_added_icon_packs.removeIcon(path);
                TokenIconPacks.removePickerPreviewPath(path);
                this.userIconPaths = this.userIconPaths.filter((iconPath: string) => iconPath !== path);
                this.refreshGridData();
              }
            }
          })
        })
      }

      if (this.selectedIconPath === path) {
        Stack() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(LengthMetrics.vp(12).value)
            .fontWeight(FontWeight.Bold)
            .fontColor([Color.White])
        }
        .width(LengthMetrics.vp(18).value)
        .height(LengthMetrics.vp(18).value)
        .borderRadius(LengthMetrics.vp(9).value)
        .backgroundColor($r('app.color.button_blue'))
        .align(Alignment.BottomEnd)
      }
    }
    .width('100%')
    .height('100%')
  }

  @LocalBuilder
  ItemIcon(path: string, removable: boolean) {
    Stack() {
      if (path === '') {
        Shape() {
          Text($r('app.string.dialog_icon_select_auto'))
        }
        .align(Alignment.Center)
        .backgroundColor($r('app.color.item_bg'))
        .height(LengthMetrics.vp(40).value)
        .width(LengthMetrics.vp(40).value)
        .borderRadius(LengthMetrics.vp(20).value)
      } else {
        Image(getPickerImageSource(path))
          .width(LengthMetrics.vp(40).value)
          .height(LengthMetrics.vp(40).value)
          .objectFit(ImageFit.Contain)
          .borderRadius(TokenIconPacks.user_added_icon_packs.raster_icons.has(path) ?
            LengthMetrics.vp(20).value : 0)
      }

      if (removable || this.selectedIconPath === path) {
        this.ItemIconOverlay(path, removable)
      }
    }
    .width(LengthMetrics.vp(40).value)
    .height(LengthMetrics.vp(40).value)
    .alignContent(Alignment.Center)
  }

  @LocalBuilder
  IconChoice(path: string, removable: boolean) {
    Stack() {
      this.ItemIcon(path, removable)
    }
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .alignContent(Alignment.Center)
    .borderRadius(LengthMetrics.vp(12).value)
    .backgroundColor(this.selectedIconPath === path ? $r('app.color.item_bg') : Color.Transparent)
    .border({
      width: this.selectedIconPath === path ? LengthMetrics.vp(2).value : 0,
      color: $r('app.color.button_blue')
    })
    .onClick(() => {
      this.selectedIconPath = path;
    })
  }

  private async addIconToUserPack(uri: string): Promise<void> {
    const destPath = await copyFileToDir(uri, TokenIconPacks.user_added_icon_packs.user_icon_path);
    TokenIconPacks.user_added_icon_packs.addIconByPath(destPath);
    await TokenIconPacks.preparePickerPreviewPaths([destPath]);
    if (!this.userIconPaths.includes(destPath)) {
      this.userIconPaths = [...this.userIconPaths, destPath];
      this.refreshGridData();
    }
  }

  @LocalBuilder
  ItemIconAddButton() {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(LengthMetrics.vp(24).value)
        .fontWeight(FontWeight.Medium)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .backgroundColor($r('app.color.item_bg'))
    .borderRadius(LengthMetrics.vp(12).value)
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .onClick(async () => {
      try {
        const uris = await showSelectFilePicker(1, ['png', 'jpg', 'jpeg', 'svg', 'webp']);
        if (uris.length === 0) {
          return;
        }
        const uri = uris[0];
        const isSvg = uri.toLowerCase().endsWith('.svg');
        if (isSvg) {
          await this.addIconToUserPack(uri);
          return;
        }
        const dims = await getImageDimensions(uri);
        if (dims === null) {
          hilog.warn(0, 'IconPicker', 'Cannot get image dimensions, copying directly');
          await this.addIconToUserPack(uri);
          return;
        }
        if (dims.width > MAX_ICON_SIZE || dims.height > MAX_ICON_SIZE) {
          this.pendingCropUri = uri;
          this.cropModel = new CropModel();
          this.cropModel.setImage(uri).setFrameWidth(1000).setFrameRatio(1);
          this.showCropCover = true;
        } else {
          await this.addIconToUserPack(uri);
        }
      } catch (e) {
        hilog.error(0, 'IconPicker', 'Add icon error: ' + JSON.stringify(e));
        const msg = e instanceof Error ? e.message : `${e}`;
        showSnackBar(msg, SnackBarNotifyType.ERROR);
      }
    })
  }

  @LocalBuilder
  CropCoverBuilder() {
    Column() {
      CropView({ model: this.cropModel })
        .layoutWeight(1)
        .width('100%')

      Row() {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onClick(() => {
            this.showCropCover = false;
          })
        Button($r('app.string.dialog_btn_confirm'))
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onClick(async () => {
            try {
              const pm: PixelMap = await this.cropModel.crop();
              const destPath = await savePixelMapToFile(pm, TokenIconPacks.user_added_icon_packs.user_icon_path);
              TokenIconPacks.user_added_icon_packs.addIconByPath(destPath);
              await TokenIconPacks.preparePickerPreviewPaths([destPath]);
              if (!this.userIconPaths.includes(destPath)) {
                this.userIconPaths = [...this.userIconPaths, destPath];
                this.refreshGridData();
              }
              this.showCropCover = false;
            } catch (e) {
              hilog.error(0, 'IconPicker', 'Crop error: ' + JSON.stringify(e));
            }
          })
      }
      .width('100%')
      .padding({ left: LengthMetrics.vp(20).value, right: LengthMetrics.vp(20).value, bottom: LengthMetrics.vp(30).value })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  @LocalBuilder
  LazyIconGrid(dataSource: IconGridDataSource, scroller?: Scroller) {
    if (dataSource.totalCount() === 0 && this.currentSearchText() !== '') {
      Column() {
        Text($r('app.string.dialog_icon_empty'))
          .fontSize(LengthMetrics.vp(14).value)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: LengthMetrics.vp(48).value })
      .alignItems(HorizontalAlign.Center)
    } else {
      Grid(scroller) {
        LazyForEach(dataSource, (item: IconGridItem) => {
          GridItem() {
            if (item.type === IconGridItemType.ADD) {
              this.ItemIconAddButton()
            } else {
              this.IconChoice(item.path, item.removable)
            }
          }
        }, (item: IconGridItem) => item.key)
      }
      .columnsTemplate('repeat(auto-fit, 56vp)')
      .columnsGap(LengthMetrics.vp(12).value)
      .rowsGap(LengthMetrics.vp(8).value)
      .width('100%')
      .layoutWeight(1)
      .padding({ left: LengthMetrics.vp(12).value, right: LengthMetrics.vp(12).value,
        top: LengthMetrics.vp(8).value, bottom: LengthMetrics.vp(8).value })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // HdsNavDestination 内容区从标题栏下方开始布局，Grid 显示区域上边缘距屏幕顶部
      // 最远约 状态栏(~40vp) + MINI标题(56vp) + bottomBuilder(112vp) + 页面padding(10vp) ≈ 218vp。
      // 行高 56+8=64vp，顶部缓存 4 行(256vp) 可覆盖整个标题栏区域；配合 clip(false)，
      // 图标滚过屏幕顶部后才离开显示+缓存范围被销毁，不会在状态栏附近提前消失。
      .cachedCount(4, true)
      .clip(false)
    }
  }

  @LocalBuilder
  TabBuilder(title: ResourceStr, index: number) {
    Column() {
      Text(title)
        .fontSize(LengthMetrics.vp(14).value)
        .fontWeight(this.activePackIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activePackIndex === index ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: LengthMetrics.vp(80).value })
    }
    .padding({ left: LengthMetrics.vp(12).value, right: LengthMetrics.vp(12).value,
      top: LengthMetrics.vp(8).value, bottom: LengthMetrics.vp(8).value })
  }

  build() {
    Column() {
      if (this.showSearch) {
        Search({ placeholder: $r('app.string.dialog_icon_search_placeholder'), value: this.localSearchText })
          .width('100%')
          .onChange((value: string) => {
            this.updateSearchText(value);
          })
          .onSubmit((value: string) => {
            this.updateSearchText(value);
          })
      }

      if (TokenIconPacks.aegis_icon_packs.length === 0) {
        this.LazyIconGrid(this.defaultGridData, this.iconScrollers[0])
      } else if (this.showPackTabs) {
        Tabs({ barPosition: BarPosition.Start }) {
          TabContent() {
            this.LazyIconGrid(this.defaultGridData, this.iconScrollers[0])
          }
          .tabBar(this.TabBuilder(TokenIconPacks.default_icon_pack.name, 0))

          ForEach(TokenIconPacks.aegis_icon_packs, (aegisIconPack: AegisIconPack, index: number) => {
            TabContent() {
              if (index < this.aegisGridData.length) {
                this.LazyIconGrid(this.aegisGridData[index], this.iconScrollers[index + 1])
              }
            }
            .tabBar(this.TabBuilder(aegisIconPack.name, index + 1))
          }, (aegisIconPack: AegisIconPack) => aegisIconPack.on_device_path)
        }
        .scrollable(true)
        .barMode(BarMode.Scrollable)
        .barHeight(LengthMetrics.vp(48).value)
        .layoutWeight(1)
        .animationDuration(200)
        .onChange((index: number) => {
          this.activePackIndex = index;
          this.onPackChange(index);
        })
      } else if (this.currentPack() === 0) {
        this.LazyIconGrid(this.defaultGridData, this.iconScrollers[0])
      } else if (this.currentPack() - 1 < this.aegisGridData.length) {
        this.LazyIconGrid(this.aegisGridData[this.currentPack() - 1], this.iconScrollers[this.currentPack()])
      }

      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        if (this.showCancelButton) {
          Button($r('app.string.dialog_btn_cancel'))
            .fontColor($r('app.color.item_fg'))
            .backgroundColor(Color.Transparent)
            .onClick(() => this.cancel())
            .layoutWeight(1)
        }
        if (this.immersiveMaterialEnabled) {
          // 沉浸档：材质参数与 AddTokenActionButton 对齐（THIN/蓝色赋色/光感/形变），
          // 背景透明透出材质层；uiMaterial 符号仅在本分支求值，低 API 设备不触达。
          Button($r('app.string.dialog_btn_confirm'))
            .fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .height(48)
            .borderRadius(24)
            .systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.THIN,
              materialColor: $r('app.color.button_blue'),
              interactive: true,
              lightEffect: { color: Color.White }
            }))
            .onClick(() => this.confirm(this.selectedIconPath))
            .layoutWeight(1)
        } else {
          Button($r('app.string.dialog_btn_confirm'))
            .fontColor(Color.White)
            .backgroundColor($r('app.color.button_blue'))
            .height(48)
            .borderRadius(24)
            .onClick(() => this.confirm(this.selectedIconPath))
            .layoutWeight(1)
        }
      }
      .width('100%')
      .padding({ top: LengthMetrics.vp(8).value })
    }
    .padding(LengthMetrics.vp(10).value)
    .width('100%')
    .height('100%')
    .bindContentCover(this.showCropCover, this.CropCoverBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.showCropCover = false;
      }
    })
  }
}

class IconGridDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: IconGridItem[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): IconGridItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replaceData(items: IconGridItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}
