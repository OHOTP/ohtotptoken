import { generateCardOTP } from '../utils/CardOTPUtils';

let cardStorage1x2 = new LocalStorage();

@Entry(cardStorage1x2)
@Component
struct TokenCard_1x2 {
  @LocalStorageProp('hasToken') hasToken: string = 'false';
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('formName') formName: string = 'tokenCard_1x2';
  @LocalStorageProp('token0_issuer') token0Issuer: string = '';
  @LocalStorageProp('token0_name') token0Name: string = '';
  @LocalStorageProp('token0_secret') token0Secret: string = '';
  @LocalStorageProp('token0_algorithm') token0Algorithm: string = '';
  @LocalStorageProp('token0_digits') token0Digits: string = '6';
  @LocalStorageProp('token0_period') token0Period: string = '30';
  @LocalStorageProp('token0_type') token0Type: string = '0';
  @LocalStorageProp('token0_counter') token0Counter: string = '0';
  @LocalStorageProp('token0_uuid') token0UUID: string = '';
  @LocalStorageProp('token0_next_margin') token0NextMargin: string = '5';
  @State isFlipped: boolean = false;
  @State currentCode: string = '';
  @State localCounterOffset: number = 0;

  private isHOTP(): boolean {
    return this.token0Type === '2';
  }

  /** 当前 TOTP 周期剩余秒数(渲染/翻转/刷新时计算; 卡片无定时器能力, 随刷新时机校正) */
  private remainingSeconds(): number {
    const period = parseInt(this.token0Period) || 30;
    return period - (Math.floor(Date.now() / 1000) % period);
  }

  private computeOTP(): string {
    if (this.token0Secret === '') return '';
    const counter = this.isHOTP() ? parseInt(this.token0Counter) + this.localCounterOffset : -1;
    return generateCardOTP(
      this.token0Secret,
      this.token0Algorithm || 'SHA1',
      parseInt(this.token0Digits) || 6,
      parseInt(this.token0Period) || 30,
      this.token0Type,
      counter,
    );
  }

  build() {
    Column() {
      if (this.hasToken !== 'true') {
        Row() {
          SymbolGlyph($r('sys.symbol.key_fill'))
            .fontSize(16)
            .fontColor([$r('app.color.card_text_primary')])
          Text('OTP令牌')
            .fontSize(12)
            .fontColor($r('app.color.card_text_primary'))
            .fontWeight(FontWeight.Bold)
            .margin({ left: 6 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          postCardAction(this, {
            action: 'router',
            bundleName: 'smartcityshenzhen.yylx.totptoken',
            abilityName: 'EntryAbility',
            params: {
              action: 'card_config',
              formId: this.formId,
              formName: this.formName,
            }
          });
        })
      } else {
        Column() {
          if (!this.isFlipped) {
            this.TokenFrontView()
          } else {
            this.TokenBackView()
          }
        }
        .width('100%')
        .height('100%')
        .borderRadius(8)
        .backgroundColor($r('app.color.card_content_bg'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .onClick(() => {
          if (!this.isFlipped) {
            this.currentCode = this.computeOTP();
            if (this.isHOTP()) {
              this.localCounterOffset++;
              postCardAction(this, {
                action: 'call',
                bundleName: 'smartcityshenzhen.yylx.totptoken',
                abilityName: 'EntryFormAbility',
                params: {
                  action: 'increment_counter',
                  tokenUUID: this.token0UUID,
                  formId: this.formId,
                }
              });
            }
          }
          this.isFlipped = !this.isFlipped;
        })
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .padding(8)
  }

  @Builder
  TokenFrontView() {
    Row() {
      // 注: 卡片环境对动态 $rawfile 路径支持受限, 运行时拼接可能致整卡渲染空白,
      // 图标暂用系统符号, 静态 rawfile 图标待卡片侧验证后接入
      SymbolGlyph($r('sys.symbol.key_fill'))
        .fontSize(14)
        .fontColor([$r('app.color.card_text_primary')])
      Column() {
        Text(this.token0Issuer)
          .fontSize(11)
          .fontColor($r('app.color.card_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.token0Name)
          .fontSize(9)
          .fontColor($r('app.color.card_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .margin({ left: 6 })
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TokenBackView() {
    Column() {
      Row() {
        Column() {
          Text(this.currentCode)
            .fontSize(18)
            .fontColor($r('app.color.card_code'))
            .fontWeight(FontWeight.Bold)
            .letterSpacing(1)
            .fontFamily('monospace')
          Text(this.token0Issuer)
            .fontSize(8)
            .fontColor($r('app.color.card_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)

      // TOTP 剩余时间进度条(底部): 剩余时间低于用户设置的即将过期阈值时变红
      Progress({ value: this.remainingSeconds(), total: parseInt(this.token0Period) || 30 })
        .width('100%')
        .height(3)
        .color(this.remainingSeconds() <= (parseInt(this.token0NextMargin) || 5)
          ? $r('app.color.card_code_warning') : $r('app.color.card_code'))
        .backgroundColor($r('app.color.card_text_secondary'))
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
  }
}
