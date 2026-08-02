import { otpType, TokenConfig, dialogSystemMaterial } from 'common';
import { JSON, url } from '@kit.ArkTS';
import { ScanBarCode } from 'common';
import { TokenIcon } from '../components/TokenIcon';
import { readFileContent, showSelectFilePicker } from 'common';
import { maFile } from 'common';
import { SelectIconDialog } from './SelectIconDialog';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Preview
@CustomDialog
export struct SteamConfigDialog {
  controller?: CustomDialogController;
  @Prop conf_json?: string = '';
  @State conf: TokenConfig = new TokenConfig('', otpType.Steam, 'Steam', 'User', 'SHA1', 30, 10);
  @State btn_camera_clicked: number = 0;

  cancel?: () => void;
  confirm: (new_conf: string) => Promise<boolean> = async () => false;

  dialog_icon_config = new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: SelectIconDialog({
      issuer: this.conf.TokenIssuer,
      currentIconPath: this.conf.TokenIconPath,
      confirm: (path) => {
        this.conf.TokenIconPath = path;
      }
    })
  });

  aboutToAppear(): void {
    if (this.conf_json != undefined && this.conf_json.length > 0) {
      this.conf = JSON.parse(this.conf_json!) as TokenConfig;
    }
  }

  addNewConfigOTP(uri: string): void {
    let otp_url: url.URL
    try {
      otp_url = url.URL.parseURL(uri)
    } catch (error) {
      hilog.error(0, 'SteamConfigDialog', 'Invalid OTPAuth URL:', error);
      return;
    }

    if (otp_url.protocol !== 'otpauth:') {
      hilog.error(0, 'SteamConfigDialog', 'Invalid protocol');
      return;
    }

    const type = otp_url.host;
    if (type.toLowerCase() !== 'totp') {
      hilog.error(0, 'SteamConfigDialog', 'Invalid type');
      return;
    }
    const pathParts = otp_url.pathname.slice(1).split('/');
    const labelParts = decodeURIComponent(pathParts[0]).split(':');

    if (labelParts.length > 1) {
      this.conf.TokenIssuer = labelParts[0];
      this.conf.TokenName = labelParts[1];
    }

    const parameters: Record<string, string> = {};
    const tail_part = otp_url.href.split('?');
    if (tail_part.length > 1) {
      const query = tail_part[1].toLowerCase();
      if (query) {
        query.split('&').forEach(part => {
          const kv: string[] = part.split('=');
          parameters[kv[0]] = kv[1];
        });
      }
      this.conf.TokenSecret = parameters['secret'];
      this.conf.TokenPeriod = parseInt(parameters['period'] ?? '30');
      this.conf.TokenDigits = parseInt(parameters['digits'] ?? '10');
    }
  }

  build() {
    Column({ space: 10 }) {
      Row() {

      }
      .height(10)
      Row() {
        TokenIcon({ issuer: this.conf.TokenIssuer, icon_path: this.conf.TokenIconPath })
          .onClick(() => {
            this.dialog_icon_config.open()
          })
        Text($r('app.string.tab_token_add_stream_key'))
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
        SymbolGlyph($r('sys.symbol.camera'))
          .fontSize(30)
          .fontColor([$r('app.color.item_fg')])
          .fontWeight(FontWeight.Medium)
          .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
            this.btn_camera_clicked)
          .onClick(() => {
            this.btn_camera_clicked++
            ScanBarCode().then((code) => {
              this.addNewConfigOTP(code)
            });
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      Row(){

      }
      .width('100%')
      .borderRadius(1)
      .backgroundColor($r('app.color.item_fg'))
      .height(2)
      Column({ space: 10 }) {
        Row() {
          Text($r("app.string.dialog_cfg_tk_secret"))
            .width('30%')
          TextInput({ text: this.conf.TokenSecret, placeholder: $r("app.string.dialog_cfg_tk_secret") })
            .onChange((value) => {
              this.conf.TokenSecret = value
            })
            .type(InputType.Password)
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Button($r('app.string.dialog_cfg_steam_from_mafile'))
            .onClick(() => {
              showSelectFilePicker(1, ['maFile|.mafile']).then((uris) => {
                readFileContent(uris[0]).then((content) => {
                  this.conf.SteamMaFile = JSON.parse(content) as maFile;
                  this.addNewConfigOTP(this.conf.SteamMaFile.uri ?? '')
                });
              });
            })
            .backgroundColor($r("app.color.item_bg"))
            .fontColor($r('app.color.str_main'))
            .border({ width: 1 })
            .width('100%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r("app.string.dialog_cfg_tk_issuer"))
            .width('30%')
          TextInput({ text: this.conf.TokenIssuer, placeholder: $r("app.string.dialog_cfg_tk_issuer") })
            .onChange((value) => {
              this.conf.TokenIssuer=value;
            })
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r("app.string.dialog_cfg_tk_name"))
            .width('30%')
          TextInput({ text: this.conf.TokenName, placeholder: $r("app.string.dialog_cfg_tk_name") })
            .onChange((value) => {
              this.conf.TokenName = value
            })
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .padding({left: 10, right: 10})

      .width('100%')

      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor($r('app.color.item_fg'))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })
          .width('100%')
        Button($r('app.string.dialog_btn_confirm'))
          .enabled(!!(this.conf.TokenSecret && this.conf.TokenIssuer && this.conf.TokenName))
          .fontColor(Color.Red)
          .backgroundColor(Color.Transparent)
          .onClick(async () => {
            if (this.controller != undefined) {
              const ok = await this.confirm(JSON.stringify(this.conf))
              if (ok) {
                this.controller.close()
              }
            }
          })
          .width('100%')

      }
    }
    .padding(10)
    .width('100%')
  }
}
