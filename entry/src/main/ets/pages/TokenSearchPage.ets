import { TokenItem } from "../components/TokenItem";
import { PageScaffold } from "../components/PageScaffold";
import { MaterialSurface } from "../components/MaterialSurface";
import { MaterialTheme, MaterialThickness } from "../components/MaterialTheme";
import { FortiConfigDialog } from 'uikit';
import { TOTPConfigDialog } from 'uikit';
import { QRCodeDialog } from 'uikit';
import { SteamConfigDialog } from 'uikit';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS, dialogSystemMaterial } from 'common';
import { otpType, TokenConfig, TokenConfigVM } from 'common';
import { TokenStore } from 'common';
import { convertToken2URI } from 'common';
import { AppStorageV2 } from "@kit.ArkUI";
import { AppWindowInfo } from 'common';
import { GenericDataSource } from 'common';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { common } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  BottomBuilderShowType,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from "@kit.UIDesignKit";
import { CommonConstants } from 'common';

let tkStore = TokenStore.getInstance();

function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

@Preview
@ComponentV2
export struct TokenSearchPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfigVM> = new GenericDataSource([]);
  @Local tokenSearchText: string = '';
  @Local token_copy_guide_popup: boolean = false;

  private searchListScroller: Scroller = new Scroller();
  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;
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
      if (MaterialTheme.isImmersiveEffective()) {
        // 沉浸材质档：搜索框套 MaterialSurface，THIN 厚度（官方搜索框推荐档位）
        // + 光感反馈；Search 背景置透明透出材质层（材质化契约第 1 条）
        MaterialSurface({
          thickness: MaterialThickness.THIN,
          lightEffect: true,
          radius: $r('sys.float.ohos_id_search_text_field_border_radius')
        }) {
          Search({
            placeholder: $r('app.string.token_search_placeholder'),
            value: this.tokenSearchText
          })
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.tokenSearchText = value;
              this.filterCurrentTokens(value);
            })
            .onSubmit((value: string) => {
              this.tokenSearchText = value;
              this.filterCurrentTokens(value);
            })
        }
      } else {
        // hds/solid 档：保持现有系统默认样式，不套材质表面
        Search({
          placeholder: $r('app.string.token_search_placeholder'),
          value: this.tokenSearchText
        })
          .width('100%')
          .height(40)
          .onChange((value: string) => {
            this.tokenSearchText = value;
            this.filterCurrentTokens(value);
          })
          .onSubmit((value: string) => {
            this.tokenSearchText = value;
            this.filterCurrentTokens(value);
          })
      }
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
            ListItem() {
              TokenItem({
                Config: vm.config,
                Update: async (conf_new): Promise<boolean> => {
                  return await this.updateSingleToken(conf_new, false);
                }
              })
                .bindPopup(this.token_copy_guide_popup && vm.config.TokenUUID === this.dataSource.getData(0)?.config.TokenUUID, {
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
            .swipeAction({
              end: {
                builder: () => {
                  this.TokenItemSwipeEnd(vm);
                },
              }
            })
          }, (vm: TokenConfigVM) => vm.objid)
        }
        .clip(false)
        .alignListItem(ListItemAlign.Center)
        .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .contentStartOffset(this.window.AvoidTopHeight + CommonConstants.AVOID_TOP_WITH_SEARCHBAR_HEIGHT)
        .contentEndOffset(this.window.AvoidBottomHeight)
      }
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
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
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
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
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.dialog_qrcode = new CustomDialogController({
      systemMaterial: dialogSystemMaterial(),
      builder: QRCodeDialog({
        content: convertToken2URI(conf),
        winSize: this.window.Size
      })
    });
    this.dialog_qrcode.open();
  }

  @Builder
  TokenItemSwipeEnd(vm: TokenConfigVM) {
    Row({ space: 10 }) {
      // 侧滑操作按钮(Phase 5.7): MaterialSurface 承载语义色材质 + 光感反馈
      // + 按压形变; 按钮背景按档位映射(沉浸档透明透出材质, 其余档语义色)
      MaterialSurface({
        thickness: MaterialThickness.THIN,
        lightEffect: true,
        interactive: true,
        materialColor: Color.Orange,
        radius: '50%',
        solidColor: Color.Transparent,
        fillWidth: false
      }) {
        Button({ type: ButtonType.Circle }) {
          Text() {
            SymbolSpan($r('sys.symbol.qrcode'))
              .fontSize(30)
              .fontWeight(FontWeight.Medium)
              .fontColor([Color.White])
          }
        }
        .backgroundColor(MaterialTheme.surfaceBackground(Color.Orange))
        .padding(10)
        .onClick(() => {
          this.showQRCodeDialog(vm.config);
        })
      }

      MaterialSurface({
        thickness: MaterialThickness.THIN,
        lightEffect: true,
        interactive: true,
        materialColor: Color.Gray,
        radius: '50%',
        solidColor: Color.Transparent,
        fillWidth: false
      }) {
        Button({ type: ButtonType.Circle }) {
          Text() {
            SymbolSpan($r('sys.symbol.square_and_pencil_fill'))
              .fontSize(30)
              .fontWeight(FontWeight.Medium)
              .fontColor([Color.White])
          }
        }
        .backgroundColor(MaterialTheme.surfaceBackground(Color.Gray))
        .padding(10)
        .onClick(() => {
        if (vm.config.TokenType === otpType.TOTP || vm.config.TokenType === otpType.HOTP ||
          vm.config.TokenType === undefined) {
          this.dialog_totp_config = new CustomDialogController({
            systemMaterial: dialogSystemMaterial(),
            builder: TOTPConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_totp_config.open()
        } else if (vm.config.TokenType === otpType.Forti) {
          this.dialog_forti_config = new CustomDialogController({
            systemMaterial: dialogSystemMaterial(),
            builder: FortiConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_forti_config.open()
        } else if (vm.config.TokenType === otpType.Steam) {
          this.dialog_steam_config = new CustomDialogController({
            systemMaterial: dialogSystemMaterial(),
            builder: SteamConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_steam_config.open()
        }
        })
      }

      MaterialSurface({
        thickness: MaterialThickness.THIN,
        lightEffect: true,
        interactive: true,
        materialColor: Color.Red,
        radius: '50%',
        solidColor: Color.Transparent,
        fillWidth: false
      }) {
        Button({ type: ButtonType.Circle }) {
          Text() {
            SymbolSpan($r('sys.symbol.trash_fill'))
              .fontSize(30)
              .fontWeight(FontWeight.Medium)
              .fontColor([Color.White])
          }
        }
        .backgroundColor(MaterialTheme.surfaceBackground(Color.Red))
        .padding(10)
        .onClick(async () => {
          AlertDialog.show({
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
    }
    .margin({ left: 10, right: this.token_preference.app_appearance_token_list_item_suffix_padding })
  }
}
