import { generateCardOTP } from '../utils/CardOTPUtils';

let cardStorage2x2 = new LocalStorage();

@Entry(cardStorage2x2)
@Component
struct TokenCard_2x2 {
  @LocalStorageProp('hasToken') hasToken: string = 'false';
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('formName') formName: string = 'tokenCard_2x2';
  @LocalStorageProp('token0_issuer') token0Issuer: string = '';
  @LocalStorageProp('token0_name') token0Name: string = '';
  @LocalStorageProp('token0_secret') token0Secret: string = '';
  @LocalStorageProp('token0_algorithm') token0Algorithm: string = '';
  @LocalStorageProp('token0_digits') token0Digits: string = '6';
  @LocalStorageProp('token0_period') token0Period: string = '30';
  @LocalStorageProp('token0_type') token0Type: string = '0';
  @LocalStorageProp('token0_counter') token0Counter: string = '0';
  @LocalStorageProp('token0_uuid') token0UUID: string = '';
  @LocalStorageProp('token1_issuer') token1Issuer: string = '';
  @LocalStorageProp('token1_name') token1Name: string = '';
  @LocalStorageProp('token1_secret') token1Secret: string = '';
  @LocalStorageProp('token1_algorithm') token1Algorithm: string = '';
  @LocalStorageProp('token1_digits') token1Digits: string = '6';
  @LocalStorageProp('token1_period') token1Period: string = '30';
  @LocalStorageProp('token1_type') token1Type: string = '0';
  @LocalStorageProp('token1_counter') token1Counter: string = '0';
  @LocalStorageProp('token1_uuid') token1UUID: string = '';
  @LocalStorageProp('token0_next_margin') token0NextMargin: string = '5';
  @LocalStorageProp('token1_next_margin') token1NextMargin: string = '5';
  @State flippedIndex: number = -1;
  @State currentCode0: string = '';
  @State currentCode1: string = '';
  @State localCounterOffset0: number = 0;
  @State localCounterOffset1: number = 0;
  @State remaining: number = 30;
  private timerController: TextTimerController = new TextTimerController();
  private lastTimeStep: number = -1;

  private isHOTP(index: number): boolean {
    return index === 0 ? this.token0Type === '2' : this.token1Type === '2';
  }

  private updateCountdown(): void {
    const index = this.flippedIndex;
    if (index < 0 || this.isHOTP(index)) return;
    const period = parseInt(index === 0 ? this.token0Period : this.token1Period) || 30;
    const seconds = Math.floor(Date.now() / 1000);
    this.remaining = period - (seconds % period);
    const timeStep = Math.floor(seconds / period);
    if (timeStep !== this.lastTimeStep) {
      if (index === 0) {
        this.currentCode0 = this.computeOTP(0);
      } else {
        this.currentCode1 = this.computeOTP(1);
      }
      this.lastTimeStep = timeStep;
    }
  }

  private computeOTP(index: number): string {
    const secret = index === 0 ? this.token0Secret : this.token1Secret;
    if (secret === '') return '';
    const algorithm = (index === 0 ? this.token0Algorithm : this.token1Algorithm) || 'SHA1';
    const digits = parseInt(index === 0 ? this.token0Digits : this.token1Digits) || 6;
    const period = parseInt(index === 0 ? this.token0Period : this.token1Period) || 30;
    const tokenType = index === 0 ? this.token0Type : this.token1Type;
    const baseCounter = parseInt(index === 0 ? this.token0Counter : this.token1Counter);
    const offset = index === 0 ? this.localCounterOffset0 : this.localCounterOffset1;
    const counter = this.isHOTP(index) ? baseCounter + offset : -1;
    return generateCardOTP(secret, algorithm, digits, period, tokenType, counter);
  }

  build() {
    Column() {
      if (this.hasToken !== 'true') {
        Column() {
          SymbolGlyph($r('sys.symbol.key_fill'))
            .fontSize(32)
            .fontColor([$r('app.color.card_text_primary')])
          Text('OTP令牌')
            .fontSize(16)
            .fontColor($r('app.color.card_text_primary'))
            .fontWeight(FontWeight.Bold)
            .margin({ top: 8 })
          Text('点击配置令牌')
            .fontSize(12)
            .fontColor($r('app.color.card_text_secondary'))
            .margin({ top: 4 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
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
        Column({ space: 8 }) {
          if (this.token0Issuer !== '') {
            Column() {
              if (this.flippedIndex !== 0) {
                this.TokenFrontView(this.token0Issuer, this.token0Name, 0)
              } else {
                this.TokenBackView()
              }
            }
            .width('100%')
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_content_bg'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.flippedIndex !== 0) {
                this.currentCode0 = this.computeOTP(0);
                this.flippedIndex = 0;
                if (this.isHOTP(0)) {
                  this.localCounterOffset0++;
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
              } else {
                this.flippedIndex = -1;
              }
            })
          }

          if (this.token1Issuer !== '') {
            Column() {
              if (this.flippedIndex !== 1) {
                this.TokenFrontView(this.token1Issuer, this.token1Name, 1)
              } else {
                this.TokenBackView()
              }
            }
            .width('100%')
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_content_bg'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.flippedIndex !== 1) {
                this.currentCode1 = this.computeOTP(1);
                this.flippedIndex = 1;
                if (this.isHOTP(1)) {
                  this.localCounterOffset1++;
                  postCardAction(this, {
                    action: 'call',
                    bundleName: 'smartcityshenzhen.yylx.totptoken',
                    abilityName: 'EntryFormAbility',
                    params: {
                      action: 'increment_counter',
                      tokenUUID: this.token1UUID,
                      formId: this.formId,
                    }
                  });
                }
              } else {
                this.flippedIndex = -1;
              }
            })
          } else {
            Column() {
              Text('+')
                .fontSize(20)
                .fontColor($r('app.color.card_text_secondary'))
            }
            .width('100%')
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_content_bg'))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
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
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .padding(12)
  }

  @Builder
  TokenFrontView(issuer: string, name: string, index: number) {
    Row() {
      // 注: 卡片环境对动态 $rawfile 路径支持受限, 运行时拼接可能致整卡渲染空白,
      // 图标暂用系统符号, 静态 rawfile 图标待卡片侧验证后接入
      SymbolGlyph($r('sys.symbol.key_fill'))
        .fontSize(18)
        .fontColor([$r('app.color.card_text_primary')])
      Column() {
        Text(issuer)
          .fontSize(13)
          .fontColor($r('app.color.card_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(name)
          .fontSize(11)
          .fontColor($r('app.color.card_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .margin({ left: 8 })
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TokenBackView() {
    Column({ space: 3 }) {
      Stack() {
        Text(this.flippedIndex === 0 ? this.currentCode0 : this.currentCode1)
          .fontSize(24)
          .minFontSize(10)
          .maxFontSize(24)
          .maxLines(1)
          .fontColor(!this.isHOTP(this.flippedIndex) &&
            this.remaining <= Number(this.flippedIndex === 0 ? this.token0NextMargin : this.token1NextMargin)
            ? $r('app.color.card_code_warning') : $r('app.color.card_code'))
          .fontWeight(FontWeight.Bold)
          .letterSpacing(2)
          .fontFamily('monospace')
          .width('100%')
          .height('100%')
        if (!this.isHOTP(this.flippedIndex)) {
          // 透明计时组件仅驱动自动换码和临期变色，不占用额外布局空间。
          TextTimer({ controller: this.timerController })
            .format('ss')
            .width(1)
            .height(1)
            .opacity(0)
            .accessibilityLevel('no')
            .onTimer(() => this.updateCountdown())
            .onAppear(() => {
              this.lastTimeStep = -1;
              this.updateCountdown();
              this.timerController.start();
            })
            .onDisAppear(() => {
              this.timerController.pause();
            })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      Text(this.flippedIndex === 0 ? this.token0Issuer : this.token1Issuer)
        .fontSize(10)
        .fontColor($r('app.color.card_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .height(14)
        .clip(true)

    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
