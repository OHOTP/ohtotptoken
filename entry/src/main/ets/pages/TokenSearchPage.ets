import { dialogSystemMaterial } from 'common';
import { TokenItem } from "../components/TokenItem";

import { PageScaffold } from "../components/PageScaffold";
import { MaterialTheme } from "../components/MaterialTheme";
import { QRCodeDialog } from 'uikit';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from 'common';
import { otpType, TokenConfig, TokenConfigVM } from 'common';
import { TokenStore } from 'common';
import { convertToken2URI } from 'common';
import { AppStorageV2 } from "@kit.ArkUI";
import { AppWindowInfo } from 'common';
import { GenericDataSource } from 'common';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { common } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BottomBuilderShowType,
  HdsListItem,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from "@kit.UIDesignKit";
import { AddTokenPageParams } from '../components/AddTokenForm';

let tkStore = TokenStore.getInstance();

function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

@Preview
@ComponentV2
export struct TokenSearchPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onExitFullScreen: () => void = () => {};
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfigVM> = new GenericDataSource([]);
  @Local tokenSearchText: string = '';
  @Local token_copy_guide_popup: boolean = false;

  private searchListScroller: Scroller = new Scroller();
  private pageInfos: NavPathStack | null = null;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTokenChangedHandler: () => void = () => {};
  private onSingleTokenUpdatedHandler: (token: TokenConfig) => void = () => {};

  aboutToAppear(): void {
    this.onTokenChangedHandler = () => this.loadTokens();
    this.onSingleTokenUpdatedHandler = (token: TokenConfig) => this.handleTokenSingleUpdated(token);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
    if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
      this.token_copy_guide_popup = true;
    }
    this.loadTokens();
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  private async loadTokens(): Promise<void> {
    this.tokens = await tkStore.getTokens();
    this.filterCurrentTokens(this.tokenSearchText);
  }

  private filterCurrentTokens(filterWord: string): void {
    const keyword = filterWord.trim().toLowerCase();
    if (keyword.length === 0) {
      this.dataSource.updateData(toVMs(this.tokens));
      return;
    }
    const filtered = this.tokens.filter((token) => {
      return token.TokenIssuer.toLowerCase().indexOf(keyword) >= 0 ||
        token.TokenName.toLowerCase().indexOf(keyword) >= 0;
    });
    this.dataSource.updateData(toVMs(filtered));
  }

  private handleTokenSingleUpdated(token: TokenConfig): void {
    const tokenIndex = this.tokens.findIndex((item: TokenConfig) => item.TokenUUID === token.TokenUUID);
    if (tokenIndex >= 0) {
      this.tokens[tokenIndex] = token;
    }
    const index = this.dataSource.findIndex((vm: TokenConfigVM) => vm.config.TokenUUID === token.TokenUUID);
    if (index >= 0) {
      const vm = this.dataSource.getData(index);
      vm.config = token;
      vm.refreshObjId();
      this.dataSource.updateItem(index, vm);
    }
  }

  private async updateSingleToken(conf: TokenConfig, toast: boolean): Promise<boolean> {
    try {
      await tkStore.updateToken(conf);
      if (toast) {
        showSnackBar($r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName), SnackBarNotifyType.SUCCESS);
      }
      return true;
    } catch (e) {
      hilog.error(0, 'TokenSearchPage', `updateSingleToken failed: ${e}`);
      return false;
    }
  }

  @Builder
  SearchBottomBuilder() {
    Column() {
      // 标题栏内直接设置 Search 材质，保持系统默认尺寸。
      Search({
        placeholder: $r('app.string.token_search_placeholder'),
        value: this.tokenSearchText
      })
        .width('100%')
        .defaultFocus(true)
        .backgroundColor(MaterialTheme.surfaceBackground($r('sys.color.comp_background_tertiary')))
        .systemMaterial(MaterialTheme.systemMaterial(true))
        .onChange((value: string) => {
          this.tokenSearchText = value;
          this.filterCurrentTokens(value);
        })
        .onSubmit((value: string) => {
          this.tokenSearchText = value;
          this.filterCurrentTokens(value);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    HdsNavDestination() {
      PageScaffold() {
        List({ space: this.token_preference.app_appearance_item_space, scroller: this.searchListScroller }) {
          if (this.dataSource.totalCount() === 0) {
            ListItem() {
              Text(this.tokenSearchText.trim().length > 0 ? $r('app.string.app_token_list_search_msg') :
              $r('app.string.app_guide_msg'))
                .textAlign(TextAlign.Center)
                .fontSize(20)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ top: 80 })
            }
          }

          LazyForEach(this.dataSource, (vm: TokenConfigVM) => {
            // 与 TokenListPage 同构：HdsListItem 承载自绘内容与侧滑
            HdsListItem({
              customItemBuilder: (): void => { this.TokenItemContentBuilder(vm) },
              swipeActionOptions: {
                end: {
                  builder: (): void => {
                    this.TokenItemSwipeEnd(vm);
                  },
                }
              }
            })
          }, (vm: TokenConfigVM) => vm.objid)
        }
        .clip(false)
        // 至少缓存 5 行，UI 空闲时扩展到 10 行；配合 clip(false)+show=true，
        // 避免令牌项滚入标题栏渐变模糊区时尚未创建或未参与绘制。
        // 计量单位是行：多列（lanes）设备行高不变。
        .cachedCount({ minCount: 5, maxCount: 10 }, true)
        .alignListItem(ListItemAlign.Center)
        .lanes(this.window.IsPc ?
          { minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width } : 1)
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .contentEndOffset(this.window.AvoidBottomHeight)
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
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType,
        },
        systemMaterialEffect: {
          // HDS 标题栏跟随开关，性能等级由系统自适应。
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.app_ua_search_token'),
        },
        bottomBuilder: {
          builder: (): void => this.SearchBottomBuilder(),
          height: 56,
          showType: BottomBuilderShowType.DIRECTLY_SHOW,
        },
      }
    })
    .bindToScrollable([this.searchListScroller])
    .onReady((context: NavDestinationContext) => this.pageInfos = context.pathStack)
    .onWillDisappear(() => this.onExitFullScreen())
  }

  @Builder
  QRCodeDialogBuilder(conf: TokenConfig): void {
    QRCodeDialog({
      content: convertToken2URI(conf),
      winSize: this.window.Size
    })
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => {
        this.QRCodeDialogBuilder(conf);
      }
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'TokenSearchPage', `open QR code dialog failed: ${error.message}`);
    });
  }

  private openEditPage(conf: TokenConfig): void {
    if (conf.TokenType === otpType.TOTP || conf.TokenType === otpType.HOTP || conf.TokenType === undefined) {
      this.pageInfos?.pushPathByName(ROUTE_NAMES.AddTotpTokenPage, new AddTokenPageParams('', conf));
    } else if (conf.TokenType === otpType.Forti) {
      this.pageInfos?.pushPathByName(ROUTE_NAMES.AddFortiTokenPage, new AddTokenPageParams('', conf));
    } else if (conf.TokenType === otpType.Steam) {
      this.pageInfos?.pushPathByName(ROUTE_NAMES.AddSteamTokenPage, new AddTokenPageParams('', conf));
    }
  }

  /**
   * 单个令牌项内容（供 HdsListItem.customItemBuilder 引用）。
   * 注意：组件创建必须发生在 @Builder 方法内——直接在普通箭头闭包里写
   * TokenItem({...}) 不会被编译器转换为组件创建，运行时按类构造器直接调用，
   * 抛 "class constructor cannot called without 'new'"（已踩坑，faultlog 实证）
   */
  @Builder
  TokenItemContentBuilder(vm: TokenConfigVM) {
    TokenItem({
      Config: vm.config,
      Edit: (conf: TokenConfig) => this.openEditPage(conf),
      Update: async (conf_new): Promise<boolean> => {
        return await this.updateSingleToken(conf_new, false);
      }
    })
      .bindPopup(this.token_copy_guide_popup && vm.config.TokenUUID === this.dataSource.getData(0)?.config.TokenUUID, {
        systemMaterial: dialogSystemMaterial(),
        placement: Placement.Left,
        message: this.getUIContext().getHostContext()?.resourceManager
          .getStringSync($r('app.string.token_copy_guide_popup').id),
        onStateChange: (e) => {
          if (!e.isVisible) {
            this.token_copy_guide_popup = false;
          }
        },
        primaryButton: {
          value: this.getUIContext().getHostContext()?.resourceManager
            .getStringSync($r('app.string.token_copy_guide_popup_Confirm').id),
          action: () => {
            if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
              AppPreference.setPreference(PREF_KEYS.SHOW_GUIDE_TIPS, false);
            }
            this.token_copy_guide_popup = false;
          }
        }
      })
  }

  @Builder
  TokenItemSwipeEnd(vm: TokenConfigVM) {
    Row({ space: 10 }) {
      // 内容区侧滑按钮不在材质生效范围，保留语义色背景。
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.qrcode'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Orange)
      .padding(10)
      .onClick(() => {
        this.showQRCodeDialog(vm.config);
      })

      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.square_and_pencil_fill'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Gray)
      .padding(10)
      .onClick(() => {
        this.openEditPage(vm.config);
      })

      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.trash_fill'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Red)
      .padding(10)
      .onClick(async () => {
        AlertDialog.show({
          systemMaterial: dialogSystemMaterial(),
          title: $r('app.string.alert_remove_title', vm.config.TokenIssuer),
          subtitle: vm.config.TokenName,
          message: $r('app.string.alert_remove_confirm_msg'),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          primaryButton: {
            defaultFocus: false,
            value: $r('app.string.dialog_btn_cancel'),
            action: () => {
              return;
            }
          },
          secondaryButton: {
            value: $r('app.string.dialog_btn_delete'),
            fontColor: Color.Red,
            action: async () => {
              tkStore.deleteToken(vm.config.TokenUUID);
            }
          }
        })
      })
    }
    .margin({ left: 10, right: this.token_preference.app_appearance_token_list_item_suffix_padding })
  }
}
