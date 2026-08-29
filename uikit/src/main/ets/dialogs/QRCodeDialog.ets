import { scanCore, generateBarcode } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { copyText } from 'common';
import { window } from '@kit.ArkUI';

@Preview
@CustomDialog
export struct QRCodeDialog {
  controller?: CustomDialogController;
  @Prop content: string = '';
  @Prop winSize: window.Size;
  @State pixelMap: image.PixelMap | undefined = undefined
  @State qrSize: number = 0;
  @StorageLink('background_blur_flag') backgroundBlurFlag: boolean = false;

  aboutToAppear(): void {
  }

  // onDidBuild 在 build() 完成后调用，此时 getUIContext() 保证可用；qrSize 计算完毕后再生成二维码
  onDidBuild(): void {
    this.qrSize = this.getUIContext().px2vp(Math.min(this.winSize.width, this.winSize.height)) * 0.8;
    this.createQRCode();
  }

  aboutToDisappear(): void {
    this.pixelMap?.release();
  }

  createQRCode() {
    this.pixelMap = undefined;
    try {
      let options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        height: this.qrSize,
        width: this.qrSize
      }
      // 码图生成接口，成功返回PixelMap格式图片
      generateBarcode.createBarcode(this.content, options).then((pixelMap: image.PixelMap) => {
        this.pixelMap = pixelMap;
      }).catch((error: BusinessError) => {
        hilog.error(0x0001, '[generateBarcode]',
          `Failed to get PixelMap by promise with options. Code: ${error.code}, message: ${error.message}`);
      })
    } catch (error) {
      hilog.error(0x0001, '[generateBarcode]',
        `Failed to createBarcode by promise with options. Code: ${error.code}, message: ${error.message}`);
    }
  }

  build() {
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
        copyText(this.content, "uri copied");
      })

    }
    .padding(20)
    .width('100%')
    .foregroundBlurStyle(this.backgroundBlurFlag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}
