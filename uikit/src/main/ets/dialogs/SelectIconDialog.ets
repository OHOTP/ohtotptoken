import { TokenIcon } from "../components/TokenIcon";
import { CropModel, CropView } from "../components/ImageCropView";
import { getImageDimensions, savePixelMapToFile, copyFileToDir } from 'common';
import { showSelectFilePicker } from 'common';
import { AegisIconPack, TokenIconPacks } from 'common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
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

@Preview
@Component
export struct IconPicker {
  @Prop @Require issuer: string = '';
  @Prop currentIconPath: string = '';
  @Prop showCancelButton: boolean = true;
  @Prop showSearch: boolean = true;
  @Prop @Watch('onSearchTextChanged') searchText: string = '';
  cancel: () => void = () => {};
  confirm: (new_conf: string) => void = () => {};

  @State selected_icon_path: string = '';
  @State currentTabIndex: number = 0;
  @State showCropCover: boolean = false;
  @State cropModel: CropModel = new CropModel();
  @State pendingCropUri: string = '';

  private icon_matched_with_issuer: string[] = [''];
  private default_icon_data: MyDataSource = new MyDataSource();
  private user_icon_data: MyDataSource = new MyDataSource();
  private aegis_icon_data: MyDataSource[] = [];
  private filtered_default_icon_data: MyDataSource = new MyDataSource();
  private filtered_aegis_icon_data: MyDataSource[] = [];

  aboutToAppear(): void {
    this.selected_icon_path = this.currentIconPath;
    this.icon_matched_with_issuer = [''];
    const default_icon = TokenIconPacks.default_icon_pack.getIconPathByIssuer(this.issuer);
    if (default_icon !== '') {
      this.icon_matched_with_issuer.push(default_icon);
    }
    TokenIconPacks.aegis_icon_packs.forEach((aegis_icon_pack) => {
      const aegis_icon = aegis_icon_pack.getIconPathByIssuer(this.issuer);
      if (aegis_icon !== '') {
        this.icon_matched_with_issuer.push(aegis_icon);
      }
    });

    const defaultIconPaths: string[] = [];
    TokenIconPacks.default_icon_pack.default_icon_pack_path.forEach((path: string) => {
      defaultIconPaths.push(path);
    });
    this.default_icon_data.replaceData(defaultIconPaths);
    this.user_icon_data.replaceData(TokenIconPacks.user_added_icon_packs.icon_path);
    this.aegis_icon_data = TokenIconPacks.aegis_icon_packs.map((aegis_icon_pack) => {
      const data_source = new MyDataSource();
      for (let icon of aegis_icon_pack.icons) {
        for (let path of icon.icon_pack_path) {
          data_source.pushData(path);
        }
      }
      return data_source;
    });
    this.filtered_aegis_icon_data = this.aegis_icon_data.map(() => new MyDataSource());
    this.refreshFilteredData();
  }

  private filterPaths(paths: string[], query: string): string[] {
    if (query === '') {
      return paths;
    }
    const q = query.toLowerCase();
    return paths.filter(p => extractIconName(p).includes(q));
  }

  private onSearchTextChanged(): void {
    this.refreshFilteredData();
  }

  private refreshFilteredData(): void {
    this.filtered_default_icon_data.replaceData(
      this.filterPaths(this.default_icon_data.toArray(), this.searchText)
    );
    for (let i = 0; i < this.aegis_icon_data.length; i++) {
      if (i >= this.filtered_aegis_icon_data.length) {
        this.filtered_aegis_icon_data.push(new MyDataSource());
      }
      this.filtered_aegis_icon_data[i].replaceData(
        this.filterPaths(this.aegis_icon_data[i].toArray(), this.searchText)
      );
    }
  }

  @Builder
  ItemIconOverlay(path: string, removable: boolean) {
    Stack({ alignContent: Alignment.Bottom }) {
      Row() {
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
                  this.user_icon_data.removeData(path);
                }
              }
            })
          })
        }

        Blank()

        if (this.selected_icon_path === path) {
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
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
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
        TokenIcon({ issuer: '', icon_path: path, bypassColorFilter: true, bypassLogoBackground: true })
      }
    }
    .width(LengthMetrics.vp(40).value)
    .height(LengthMetrics.vp(40).value)
    .alignContent(Alignment.Center)
    .overlay(this.ItemIconOverlay(path, removable), { align: Alignment.Bottom })
  }

  @Builder
  IconChoice(path: string, removable: boolean) {
    Stack() {
      this.ItemIcon(path, removable)
    }
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .alignContent(Alignment.Center)
    .borderRadius(LengthMetrics.vp(12).value)
    .backgroundColor(this.selected_icon_path === path ? $r('app.color.item_bg') : Color.Transparent)
    .border({
      width: this.selected_icon_path === path ? LengthMetrics.vp(2).value : 0,
      color: $r('app.color.button_blue')
    })
    .onClick(() => {
      this.selected_icon_path = path;
    })
  }

  private async addIconToUserPack(uri: string): Promise<void> {
    const destPath = await copyFileToDir(uri, TokenIconPacks.user_added_icon_packs.user_icon_path);
    TokenIconPacks.user_added_icon_packs.addIconByPath(destPath);
    this.user_icon_data.pushData(destPath);
  }

  @Builder
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
          hilog.warn(0, 'SelectIconDialog', 'Cannot get image dimensions, copying directly');
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
        hilog.error(0, 'SelectIconDialog', 'Add icon error: ' + JSON.stringify(e));
        const msg = e instanceof Error ? e.message : `${e}`;
        showSnackBar(msg, SnackBarNotifyType.ERROR);
      }
    })
  }

  @Builder
  RecommendRow() {
    Column({ space: LengthMetrics.vp(8).value }) {
      Text($r('app.string.dialog_icon_recommend'))
        .fontSize(LengthMetrics.vp(14).value)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Scroll() {
        Row({ space: LengthMetrics.vp(8).value }) {
          ForEach(this.icon_matched_with_issuer, (path: string) => {
            this.IconChoice(path, false)
          }, (path: string) => path)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(false)
      .width('100%')
    }
    .width('100%')
    .padding({ top: LengthMetrics.vp(12).value, left: LengthMetrics.vp(12).value,
      right: LengthMetrics.vp(12).value })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  CustomRow() {
    Column({ space: LengthMetrics.vp(8).value }) {
      Text($r('app.string.dialog_icon_select_custom'))
        .fontSize(LengthMetrics.vp(14).value)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Scroll() {
        Row({ space: LengthMetrics.vp(8).value }) {
          this.ItemIconAddButton()
          LazyForEach(this.user_icon_data, (path: string) => {
            this.IconChoice(path, true)
          }, (path: string) => path)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(false)
      .width('100%')
    }
    .width('100%')
    .padding({ top: LengthMetrics.vp(12).value, bottom: LengthMetrics.vp(8).value,
      left: LengthMetrics.vp(12).value, right: LengthMetrics.vp(12).value })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
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
              this.user_icon_data.pushData(destPath);
              this.showCropCover = false;
            } catch (e) {
              hilog.error(0, 'SelectIconDialog', 'Crop error: ' + JSON.stringify(e));
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

  @Builder
  LazyIconGrid(dataSource: MyDataSource) {
    if (dataSource.totalCount() === 0) {
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
      Grid() {
        LazyForEach(dataSource, (path: string) => {
          GridItem() {
            this.IconChoice(path, false)
          }
        }, (path: string) => path)
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
      .cachedCount(2)
    }
  }

  @Builder
  TabBuilder(title: ResourceStr, index: number) {
    Column() {
      Text(title)
        .fontSize(LengthMetrics.vp(14).value)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTabIndex === index ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: LengthMetrics.vp(80).value })
    }
    .padding({ left: LengthMetrics.vp(12).value, right: LengthMetrics.vp(12).value, top: LengthMetrics.vp(8).value, bottom: LengthMetrics.vp(8).value })
  }

  build() {
    Column() {
      if (this.showSearch) {
        Search({ placeholder: $r('app.string.dialog_icon_search_placeholder'), value: this.searchText })
          .width('100%')
          .onChange((value: string) => {
            this.searchText = value;
          })
          .onSubmit((value: string) => {
            this.searchText = value;
          })
      }

      if (this.searchText === '') {
        this.RecommendRow()
        this.CustomRow()
      }

      if (TokenIconPacks.aegis_icon_packs.length === 0) {
        if (this.searchText === '') {
          this.LazyIconGrid(this.default_icon_data)
        } else {
          this.LazyIconGrid(this.filtered_default_icon_data)
        }
      } else {
        Tabs({ barPosition: BarPosition.Start }) {
          TabContent() {
            if (this.searchText === '') {
              this.LazyIconGrid(this.default_icon_data)
            } else {
              this.LazyIconGrid(this.filtered_default_icon_data)
            }
          }
          .tabBar(this.TabBuilder(TokenIconPacks.default_icon_pack.name, 0))

          ForEach(TokenIconPacks.aegis_icon_packs, (aegis_icon_pack: AegisIconPack, index: number) => {
            TabContent() {
              if (this.searchText === '' && index < this.aegis_icon_data.length) {
                this.LazyIconGrid(this.aegis_icon_data[index])
              } else {
                this.LazyIconGrid(this.filtered_aegis_icon_data[index])
              }
            }
            .tabBar(this.TabBuilder(aegis_icon_pack.name, 1 + index))
          }, (aegis_icon_pack: AegisIconPack) => {
            return aegis_icon_pack.on_device_path;
          })
        }
        .scrollable(true)
        .barMode(BarMode.Scrollable)
        .barHeight(LengthMetrics.vp(48).value)
        .layoutWeight(1)
        .animationDuration(200)
        .onChange((index: number) => {
          this.currentTabIndex = index;
        })
      }

      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        if (this.showCancelButton) {
          Button($r('app.string.dialog_btn_cancel'))
            .fontColor($r('app.color.item_fg'))
            .backgroundColor(Color.Transparent)
            .onClick(() => this.cancel())
            .layoutWeight(1)
        }
        Button($r('app.string.dialog_btn_confirm'))
          .fontColor(Color.White)
          .backgroundColor($r('app.color.button_blue'))
          .borderRadius(20)
          .onClick(() => this.confirm(this.selected_icon_path))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: LengthMetrics.vp(8).value })
    }
    .padding(LengthMetrics.vp(10).value)
    .width('100%')
    .bindContentCover(this.showCropCover, this.CropCoverBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.showCropCover = false;
      }
    })
  }
}

/**
 * 兼容旧配置流程的弹窗外壳。新添加/编辑令牌流程使用独立 IconPickerPage，
 * 选择器主体由 IconPicker 共用，避免页面版与弹窗版的搜索、图标包和裁剪逻辑分叉。
 */
@Preview
@CustomDialog
export struct SelectIconDialog {
  @Prop @Require issuer: string = '';
  @Prop currentIconPath: string = '';
  controller?: CustomDialogController;
  cancel?: () => void;
  confirm: (new_conf: string) => void = () => {};

  build() {
    IconPicker({
      issuer: this.issuer,
      currentIconPath: this.currentIconPath,
      showCancelButton: true,
      cancel: () => {
        this.cancel?.();
        this.controller?.close();
      },
      confirm: (path: string) => {
        this.confirm(path);
        this.controller?.close();
      }
    })
  }
}

class BasicDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private originDataArray: string[] = [];

  public totalCount(): number {
    return 0;
  }

  public getData(index: number): string {
    return this.originDataArray[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      hilog.info(0, 'SelectIconDialog', 'add listener');
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      hilog.info(0, 'SelectIconDialog', 'remove listener');
      this.listeners.splice(pos, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach(listener => {
      listener.onDataReloaded();
    })
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataAdd(index);
    })
  }

  notifyDataChange(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataChange(index);
    })
  }

  notifyDataDelete(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataDelete(index);
    })
  }

  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach(listener => {
      listener.onDataMove(from, to);
    })
  }

  notifyDatasetChange(operations: DataOperation[]): void {
    this.listeners.forEach(listener => {
      listener.onDatasetChange(operations);
    })
  }
}

class MyDataSource extends BasicDataSource {
  private dataArray: string[] = [];

  public totalCount(): number {
    return this.dataArray.length;
  }

  public getData(index: number): string {
    return this.dataArray[index];
  }

  public toArray(): string[] {
    return this.dataArray.slice();
  }

  public replaceData(data: string[]): void {
    this.dataArray = data.filter((path: string, index: number, paths: string[]) =>
      path !== undefined && paths.indexOf(path) === index);
    this.notifyDataReload();
  }

  public pushData(data: string): void {
    if (this.dataArray.findIndex(_ => _ === data) < 0) {
      this.dataArray.push(data);
      this.notifyDataAdd(this.dataArray.length - 1);
    }
  }

  public removeData(data: string): void {
    const index = this.dataArray.findIndex(_ => _ === data);
    this.dataArray = this.dataArray.filter(_ => _ !== data);
    this.notifyDataDelete(index);
  }
}
