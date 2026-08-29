import { ScanBarCode } from 'common';
import { url } from "@kit.ArkTS";
import { otpType, TokenConfig } from 'common';
import { readFileContent, showSelectFilePicker } from 'common';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Preview
@CustomDialog
export struct URIConfigDialog {
  controller?: CustomDialogController;
  @State otp_uris: Array<string> = [];
  @State btn_camera_clicked: number = 0;
  @State btn_folder_clicked: number = 0;
  @StorageLink('background_blur_flag') backgroundBlurFlag: boolean = false;

  cancel?: () => void;
  confirm: (tokens: Array<TokenConfig>) => Promise<boolean> = async () => false;

  createTokens(uris: Array<string>): Array<TokenConfig> {
    let tokens: Array<TokenConfig> = [];
    let otp_url: url.URL;

    uris.forEach((uri) => {
      let token = new TokenConfig();
      try {
        otp_url = url.URL.parseURL(uri)
      } catch (error) {
        hilog.error(0, 'URIConfigDialog', 'Invalid OTPAuth URL:', error);
        return;
      }

      if (otp_url.protocol !== 'otpauth:') {
        hilog.error(0, 'URIConfigDialog', 'Invalid protocol');
        return;
      }

      const type = otp_url.host.toLowerCase();

      if (type === 'totp') {
        token.TokenType = otpType.TOTP;
      } else if (type == 'hotp') {
        token.TokenType = otpType.HOTP;
      } else {
        hilog.error(0, 'URIConfigDialog', 'Invalid type');
        return;
      }

      const pathParts = otp_url.pathname.slice(1).split('/');
      const labelParts = decodeURIComponent(pathParts[0]).split(':');
      token.TokenIssuer = labelParts[0];
      token.TokenName = labelParts[1];

      const parameters: Record<string, string> = {};
      const query = otp_url.href.split('?')[1].toLowerCase();
      if (query) {
        query.split('&').forEach(part => {
          const kv: string[] = part.split('=');
          parameters[kv[0]] = kv[1];
        });
      }
      token.TokenSecret = parameters['secret'];
      token.TokenPeriod = parseInt(parameters['period'] ?? '30');
      token.TokenCounter = parseInt(parameters['counter'] ?? '0');
      token.TokenDigits = parseInt(parameters['digits'] ?? '6');

      // otpauth://totp/Steam:xxx?secret=XXXXXXXXXXXXXXXXXXXXXXX&issuer=Steam
      if(token.TokenIssuer.toLowerCase()=='steam'){
        token.TokenType = otpType.Steam;
        token.TokenAlgorithm = 'SHA1'
        token.TokenPeriod = 30
        token.TokenDigits = 10
      }

      tokens.push(token);
    });

    return tokens;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text($r('app.string.tab_token_add_uri_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
        Blank()
        SymbolGlyph($r('sys.symbol.camera'))
          .fontSize(30)
          .fontColor([$r('app.color.item_fg')])
          .fontWeight(FontWeight.Medium)
          .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
            this.btn_camera_clicked)
          .onClick(() => {
            this.btn_camera_clicked++
            ScanBarCode().then((code) => {
              this.otp_uris.push(code);
            });
          })
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(30)
          .fontColor([$r('app.color.item_fg')])
          .fontWeight(FontWeight.Medium)
          .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
            this.btn_folder_clicked)
          .onClick(() => {
            this.btn_folder_clicked++
            showSelectFilePicker(1, ['Text File|.txt,.json']).then((uris) => {
              readFileContent(uris[0]).then((str) => {
                this.otp_uris = this.otp_uris.concat(str.split('\n'))
              })
            });
          })
      }
      .margin({ top: 10, left: 10, right: 10 })
      .width('100%')
      .justifyContent(FlexAlign.SpaceAround)

      TextArea({ placeholder: $r('app.string.tab_token_add_uri_desc'), text: this.otp_uris.join('\n') })
        .width('100%')
        .layoutWeight(1)
        .onChange((value: string) => {
          this.otp_uris = value.split('\n')
        })
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
          .fontColor(Color.Red)
          .backgroundColor(Color.Transparent)
          .onClick(async () => {
            if (this.controller != undefined) {
              const ok = await this.confirm(this.createTokens(this.otp_uris))
              if (ok) {
                this.controller.close()
              }
            }
          })
          .width('100%')
      }
    }
    .height('50%')
    .margin(10)
    .foregroundBlurStyle(this.backgroundBlurFlag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}
