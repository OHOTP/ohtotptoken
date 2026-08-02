import { TokenItem } from "../components/TokenItem";
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
import { AppStorageV2, window } from "@kit.ArkUI";
import { AppWindowInfo } from 'common';
import { GenericDataSource } from 'common';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { common } from "@kit.AbilityKit";
import { NfcSessionTokens } from "../oath/NfcSessionTokens";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { HdsListItem } from '@kit.UIDesignKit';

let tkStore = TokenStore.getInstance();

/** 将纯数据 TokenConfig[] 转为带刷新标识的 ViewModel 数组，供 LazyForEach 消费 */
function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

@Preview
@ComponentV2
export struct TokenListPage {
  @Require @Param Tokens: TokenConfig[] = [];
  @Require @Param appBottomAvoidHeight: number = 0;
  @Require @Param appTopAvoidHeight: number = 0;
  @Require @Param appWindowSize: window.Size = { width: 0, height: 0 };
  @Require @Param TabBarVisible: boolean = true;
  @Param listScroller: Scroller = new Scroller();
  @Event updateTokenConfig: (conf: TokenConfig, toast: boolean) => Promise<boolean> = async () => false;
  @Event updateTokenConfigs: (tokens: Array<TokenConfig>) => void = () => {};

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local token_copy_guide_popup: boolean = false;

  @Local dataSource: GenericDataSource<TokenConfigVM> = new GenericDataSource([]);

  /** 全量刷新：父组件 Tokens 变化时重建整个 ViewModel 数组 */
  @Monitor("Tokens")
  onTokensChange(monitor: IMonitor): void {
    this.dataSource.updateData(toVMs(monitor.value()?.now as TokenConfig[]));
  }

  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onSingleTokenUpdatedHandler: (token: TokenConfig) => void = () => {};

  aboutToAppear(): void {
    this.dataSource = new GenericDataSource(toVMs(this.Tokens));
    if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
      this.token_copy_guide_popup = true;
    }
    this.onSingleTokenUpdatedHandler = (token: TokenConfig) => this.handleTokenSingleUpdated(token);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  private async updateSingleToken(conf: TokenConfig, toast: boolean): Promise<boolean> {
    try {
      await tkStore.updateToken(conf);
      if (toast) {
        showSnackBar($r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName), SnackBarNotifyType.SUCCESS);
      }
      return true;
    } catch (e) {
      hilog.error(0, 'TokenListPage', `updateSingleToken failed: ${e}`);
      return false;
    }
  }

  /**
   * 单条 Token 精准刷新（由 TOKEN_SINGLE_UPDATED 事件驱动）。
   *
   * 流程：替换 vm.config 引用 + 刷新 objid → updateItem 触发 notifyDataChange
   * → LazyForEach 检测到 key 变化 → 销毁旧行并创建新行 → aboutToAppear 重新初始化。
   *
   * 对于尚未加载到 LazyForEach 可视区域的 Token（滚动范围之外），
   * 底层数组已在 TokenStore 中更新，下次滚动至此处时会自然使用新数据。
   */
  private handleTokenSingleUpdated(token: TokenConfig): void {
    const index = this.dataSource.findIndex((vm: TokenConfigVM) => vm.config.TokenUUID === token.TokenUUID);
    if (index >= 0) {
      const vm = this.dataSource.getData(index);
      vm.config = token;
      vm.refreshObjId();
      this.dataSource.updateItem(index, vm);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.Tokens.length === 0) {
        Row() {
          Text($r('app.string.app_guide_msg'))
            .textAlign(TextAlign.Center)
            .fontSize(20)
            .width('100%')
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .height('100%')

      }
      Column() {
        List({ space: this.token_preference.app_appearance_item_space, initialIndex: 0, scroller: this.listScroller }) {
          // key = vm.objid：变更 objid 后 LazyForEach 视为"新数据"，销毁旧组件并创建新实例
          // HdsListItem 内部封装 ListItem：内容走 customItemBuilder 自绘（宽度/边距自控），
          // 侧滑走 swipeActionOptions（spike 已验证自定义 builder 行为与 ListItem.swipeAction 一致）
          LazyForEach(this.dataSource, (vm: TokenConfigVM) => {
            HdsListItem({
              customItemBuilder: (): void => { this.TokenItemContentBuilder(vm) },
              swipeActionOptions: {
                end: {
                  builder: (): void => {
                    this.TokenItemSwipeEnd(vm)
                  },
                }
              }
            })
          }, (vm: TokenConfigVM) => vm.objid) // keyGenerator: objid 变化 = 组件重建
        }
        .contentEndOffset(this.TabBarVisible ? (80 + this.appBottomAvoidHeight) : (20 + this.appBottomAvoidHeight))
        .alignListItem(ListItemAlign.Center)
        .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(false)
        .cachedCount(3, true)
      }
      .alignItems(HorizontalAlign.Center)
    }
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.dialog_qrcode = new CustomDialogController({
      systemMaterial: dialogSystemMaterial(),
      builder: QRCodeDialog({
        content: convertToken2URI(conf),
        winSize: this.appWindowSize
      })
    });
    this.dialog_qrcode.open();
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

  @Builder
  TokenItemSwipeEnd(vm: TokenConfigVM) {
    Row({ space: 10 }) {
      // 侧滑操作按钮(Phase 5.7): MaterialSurface 承载语义色材质 + 光感反馈
      // + 按压形变; 按钮背景按档位映射(沉浸档透明透出材质, 其余档语义色)
      // NFC 外部令牌无持久化 URI，不提供二维码入口
      if (vm.config.TokenType !== otpType.NFC_external) {
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
      }

      if (this.TabBarVisible && vm.config.TokenType !== otpType.NFC_external) {
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
                return
              }
            },
            secondaryButton: {
              value: $r('app.string.dialog_btn_delete'),
              fontColor: Color.Red,
              action: async () => {
                if (vm.config.TokenType === otpType.NFC_external) {
                  // 外部令牌仅存于会话存储，从会话中移除
                  NfcSessionTokens.getInstance().remove(vm.config.TokenUUID);
                } else {
                  tkStore.deleteToken(vm.config.TokenUUID);
                }
              }
            }
          })
        })
      }
    }
    .margin({ left: 10, right: this.token_preference.app_appearance_token_list_item_suffix_padding })
  }
}
