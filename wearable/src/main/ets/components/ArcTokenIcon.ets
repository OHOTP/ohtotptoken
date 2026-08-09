import { ConfigurationConstant, common } from "@kit.AbilityKit";
import { TokenIconPacks } from 'common';
import { fileIo } from "@kit.CoreFileKit";
import { TokenPreference, EVENT_NAMES } from 'common';
import { AppStorageV2 } from "@kit.ArkUI";
import { AppWindowInfo } from 'common';

@Preview
@ComponentV2
export struct ArcTokenIcon {
  @Require @Param issuer: string = '';
  @Param icon_path: string = '';
  @Param bypassColorFilter: boolean = false;
  @Param bypassLogoBackground: boolean = false;
  @Local icon: ResourceStr | undefined =
    (this.icon_path !== '' && this.icon_path !== undefined)
      ? this.validateUri(this.icon_path)
      : this.getIconResourceStr(TokenIconPacks.getIconByIssuer(this.issuer));
  @Local applyColorFilter: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;

  // 使用 AppStorage 获取 context，避免在 aboutToAppear（build 之前）调用 getUIContext()
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private iconPackChangedHandler: () => void = () => {};

  @Computed
  get is_dark_mode() {
    return true;
  }

  @Computed
  get iconRadius(): number {
    return TokenIconPacks.user_added_icon_packs.raster_icons.has(this.icon_path) ? 20 : 0;
  }

  @Monitor("issuer")
  onStrChange(monitor: IMonitor) {
    monitor.dirty.forEach((path: string) => {
      this.refreshIcon((monitor.value(path)?.now as string).trim());
    });
  }

  @Monitor("icon_path")
  onIconPathChange(monitor: IMonitor) {
    monitor.dirty.forEach((path: string) => {
      this.refreshIcon(this.issuer, (monitor.value(path)?.now as string).trim());
    });
  }

  refreshIcon(issuer: string, path: string = ''): void {
    this.icon = this.getIconResourceStr(TokenIconPacks.getIconByIssuer(issuer), path);
  }

  validateUri(uri: string): ResourceStr | undefined {
    if (uri === undefined) {
      return undefined;
    }
    if (uri.length < 10) {
      return undefined;
    }
    if (uri.startsWith('rawfile://')) {
      return $rawfile(uri.slice(10));
    }
    if (!fileIo.accessSync(uri.slice(7))){
      return undefined;
    }
    return uri;
  }

  getIconResourceStr(uri: string, path: string = ''): ResourceStr | undefined {
    if (path === '') {
      path = this.icon_path;
    }
    if (path !== '' && path !== undefined) {
      return this.validateUri(this.icon_path);
    }
    return this.validateUri(uri);
  }

  onIconPackChanged(): void {
    if (!this.icon_path || this.icon_path === '' || this.validateUri(this.icon_path) === undefined) {
      this.icon = this.validateUri(TokenIconPacks.getIconByIssuer(this.issuer));
    }
    this.applyColorFilter = !this.bypassColorFilter &&
      (typeof this.icon === 'object');
  }

  aboutToAppear(): void {
    if (this.icon_path && this.icon_path !== '' && this.icon === undefined) {
      this.icon = this.validateUri(TokenIconPacks.getIconByIssuer(this.issuer));
    }
    this.applyColorFilter = !this.bypassColorFilter &&
      (typeof this.icon === 'object');
    this.iconPackChangedHandler = () => this.onIconPackChanged();
    this.appCtx.eventHub?.on(EVENT_NAMES.ICON_PACK_CHANGED, this.iconPackChangedHandler);
  }

  // 清理事件监听，防止组件销毁后监听器泄漏
  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.ICON_PACK_CHANGED, this.iconPackChangedHandler);
  }

  stringToColor(str: string): string {
    let hash: number = 0;
    for (let i = 0; i < str.length; i++) {
      hash = str.charCodeAt(i) + ((hash << 5) - hash);
    }

    let color: string = "#";
    for (let i = 0; i < 3; i++) {
      const value: number = (hash >> (i * 8)) & 0xff;
      const hex: string = "00" + value.toString(16);
      color += hex.substring(hex.length - 2);
    }

    return color;
  }

  build() {
    Stack() {
      // 手表端恒为暗色模式, 无需亮暗判断
      if (this.token_preference.app_appearance_logo_background && !this.bypassLogoBackground) {
        Shape() {}
        .align(Alignment.Center)
        .backgroundColor(this.token_preference.app_appearance_logo_background_color)
        .height(this.token_preference.app_appearance_logo_background_size)
        .width(this.token_preference.app_appearance_logo_background_size)
        .borderRadius(this.token_preference.app_appearance_logo_background_radius)
      }
      if (this.icon === undefined) {
        Shape() {
          Text(this.issuer.charAt(0).toUpperCase() )
            .fontWeight(FontWeight.Bold)
            .fontSize(26)
            .fontColor(0xFFFFFF)
            .textAlign(TextAlign.Center)
            .height(this.token_preference.app_appearance_logo_size)
            .width(this.token_preference.app_appearance_logo_size)
        }
        .backgroundColor(this.stringToColor(this.issuer))
        .height(this.token_preference.app_appearance_logo_size)
        .width(this.token_preference.app_appearance_logo_size)
        .borderRadius(20)
      } else {
        if (
          this.token_preference.app_appearance_logo_dark_filter &&
          this.applyColorFilter && this.is_dark_mode
        ) {
          Image(this.icon)
            .height(this.token_preference.app_appearance_logo_size)
            .width(this.token_preference.app_appearance_logo_size)
            .fillColor(this.token_preference.app_appearance_logo_dark_filter_color)
            .objectFit(ImageFit.Contain)
            .borderRadius(this.iconRadius)
            .supportSvg2(true)
        } else {
          Image(this.icon)
            .height(this.token_preference.app_appearance_logo_size)
            .width(this.token_preference.app_appearance_logo_size)
            .objectFit(ImageFit.Contain)
            .borderRadius(this.iconRadius)
            .supportSvg2(true)
        }
      }
    }
  }
}