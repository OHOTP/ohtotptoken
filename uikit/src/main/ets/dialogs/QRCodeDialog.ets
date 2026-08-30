import { scanCore, generateBarcode } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { copyText } from 'common';
import { CustomContentDialogV2, window } from '@kit.ArkUI';

@Preview
@ComponentV2
export struct QRCodeDialog {
  @Require @Param content: string = '';
  @Require @Param winSize: window.Size = { width: 0, height: 0 };
  @Local pixelMap: image.PixelMap | undefined = undefined;
  @Local qrSize: number = 0;

  // onDidBuild 时 getUIContext() 已可用；仅初始化一次，避免状态刷新后重复生成二维码。
  onDidBuild(): void {
    if (this.qrSize > 0) {
      return;
    }
    this.qrSize = this.getUIContext().px2vp(Math.min(this.winSize.width, this.winSize.height)) * 0.8;
    this.createQRCode();
  }

  aboutToDisappear(): void {
    this.pixelMap?.release();
    this.pixelMap = undefined;
  }

  private createQRCode(): void {
    this.pixelMap = undefined;
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        height: this.qrSize,
        width: this.qrSize
      };
      generateBarcode.createBarcode(this.content, options).then((pixelMap: image.PixelMap) => {
        this.pixelMap = pixelMap;
      }).catch((error: BusinessError) => {
        hilog.error(0x0001, '[generateBarcode]',
          `Failed to get PixelMap by promise with options. Code: ${error.code}, message: ${error.message}`);
      });
    } catch (error) {
      hilog.error(0x0001, '[generateBarcode]',
        `Failed to createBarcode by promise with options. Code: ${error.code}, message: ${error.message}`);
    }
  }

  @Builder
  contentBuilder(): void {
    Column({ space: 10 }) {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .objectFit(ImageFit.Contain)
          .constraintSize({ maxHeight: this.qrSize })
          .layoutWeight(1)
      } else {
        Row() {
          Column() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .fontColor([Color.Gray])
              .onClick(() => {
                this.createQRCode();
              })
          }
          .width('100%')
          .align(Alignment.Center)
        }
        .align(Alignment.Center)
        .width(this.qrSize)
        .height(this.qrSize)
      }
      Text() {
        Span(this.content)
      }
      .fontSize(10)
      .fontColor($r('app.color.str_gray'))
      .onClick(() => {
        copyText(this.content, 'uri copied');
      })
    }
    .width('100%')
  }

  build() {
    CustomContentDialogV2({
      contentBuilder: () => {
        this.contentBuilder();
      }
    })
  }
}
