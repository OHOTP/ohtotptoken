import { TokenItem } from "../components/TokenItem";
import { MaterialSurface } from "../components/MaterialSurface";
import { MaterialThickness } from "../components/MaterialTheme";
import { QRCodeDialog } from 'uikit';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from 'common';
import { otpType, TokenConfig, TokenConfigVM } from 'common';
import { TokenStore } from 'common';
import { convertToken2URI } from 'common';
import { AppStorageV2, ListItemModifier, window } from "@kit.ArkUI";
import { AppWindowInfo } from 'common';
import { GenericDataSource } from 'common';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { common } from "@kit.AbilityKit";
import { NfcSessionTokens } from "../oath/NfcSessionTokens";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsListItem } from '@kit.UIDesignKit';

let tkStore = TokenStore.getInstance();

/** PC 主令牌列表最多容纳 3 个 400vp 的 lane。 */
const PC_TOKEN_LIST_MAX_WIDTH: number = 1200;

/** 将纯数据 TokenConfig[] 转为带刷新标识的 ViewModel 数组，供 LazyForEach 消费 */
function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

/** 让 HdsListItem 的系统选中背板与令牌卡片使用同一边距、圆角和裁剪区域。 */
class TokenListItemModifier extends ListItemModifier {
  constructor(left: number, right: number, radius: number) {
    super();
    this.margin({ left: left, right: right });
    this.borderRadius(radius);
    this.clip(true);
  }
}

@Preview
@ComponentV2
export struct TokenListPage {
  @Require @Param Tokens: TokenConfig[] = [];
  @Require @Param appBottomAvoidHeight: number = 0;
  @Require @Param appTopAvoidHeight: number = 0;
  @Require @Param appWindowSize: window.Size = { width: 0, height: 0 };
  @Require @Param pageInfos: NavPathStack = new NavPathStack();
  @Require @Param TabBarVisible: boolean = true;
  @Param listScroller: Scroller = new Scroller();
  @Param splitSelectionMode: boolean = false;
  @Param selectedTokenUUID: string = '';
  @Event onSelectToken: (conf: TokenConfig) => void = () => {};
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
              listItemModifier: new TokenListItemModifier(
                this.token_preference.app_appearance_token_list_item_prefix_padding,
                this.token_preference.app_appearance_token_list_item_suffix_padding,
                this.token_preference.app_appearance_item_radius),
              isSelected: this.splitSelectionMode && vm.config.TokenUUID === this.selectedTokenUUID,
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
        // ArkUI 链式动效要求显式单列且不能使用自动 lanes；仅 PC 保持自适应多列。
        .lanes(this.window.IsPc ?
          { minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width } : 1)
        .layoutWeight(1)
        .width('100%')
        .constraintSize({
          // 平板恢复使用原令牌项最大宽度；PC 保持最多 3 列，手机占满可用宽度。
          maxWidth: this.window.IsPc ? PC_TOKEN_LIST_MAX_WIDTH :
            (this.window.IsPcOrTablet ? this.token_preference.app_appearance_item_max_width : '100%')
        })
        .height('100%')
        .chainAnimation(!this.window.IsPc &&
          this.token_preference.app_appearance_chain_animation_enable)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(false)
        // 至少缓存 5 行，UI 空闲时扩展到 10 行；配合 clip(false)+show=true，
        // 避免令牌项滚入标题栏渐变模糊区时尚未创建或未参与绘制。
        // 计量单位是行：多列（lanes）设备行高不变。
        .cachedCount({ minCount: 5, maxCount: 10 }, true)
      }
      .alignItems(HorizontalAlign.Center)
    }
  }

  @Builder
  QRCodeDialogBuilder(conf: TokenConfig): void {
    QRCodeDialog({
      content: convertToken2URI(conf),
      winSize: this.appWindowSize
    })
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.QRCodeDialogBuilder(conf);
      }
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'TokenListPage', `open QR code dialog failed: ${error.message}`);
    });
  }

  private openEditPage(conf: TokenConfig): void {
    this.onSelectToken(conf);
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
      selectionMode: this.splitSelectionMode,
      selected: this.splitSelectionMode && vm.config.TokenUUID === this.selectedTokenUUID,
      hdsCardMode: true,
      Select: (conf: TokenConfig) => this.onSelectToken(conf),
      Edit: (conf: TokenConfig) => this.openEditPage(conf),
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
      // 侧滑操作按钮：透明背景完整透出沉浸材质与光感反馈；
      // 删除操作使用红色光感，其余操作沿用默认白色光感。
      // NFC 外部令牌无持久化 URI，不提供二维码入口
      if (vm.config.TokenType !== otpType.NFC_external) {
        MaterialSurface({
          thickness: MaterialThickness.THIN,
          lightEffect: true,
          interactive: true,
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
          .backgroundColor(Color.Transparent)
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
          .backgroundColor(Color.Transparent)
          .padding(10)
          .onClick(() => {
            this.openEditPage(vm.config);
          })
        }
      }

      MaterialSurface({
        thickness: MaterialThickness.THIN,
        lightEffect: true,
        lightEffectColor: Color.Red,
        interactive: true,
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
        .backgroundColor(Color.Transparent)
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
