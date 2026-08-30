import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

@Concurrent
export async function generateIconThumbnails(sourcePaths: string[], cacheDir: string): Promise<string[]> {
  const thumbnailSize = 64;
  if (!fileIo.accessSync(cacheDir)) {
    fileIo.mkdirSync(cacheDir);
  }

  const results: string[] = [];
  for (const sourcePath of sourcePaths) {
    try {
      const localPath = sourcePath.startsWith('file://') ? sourcePath.slice(7) : sourcePath;
      const stat = fileIo.statSync(localPath);
      if (!stat.isFile()) {
        results.push('');
        continue;
      }

      let hash = 5381;
      for (let index = 0; index < localPath.length; index++) {
        hash = ((hash << 5) + hash) ^ localPath.charCodeAt(index);
      }
      const outputPath = `${cacheDir}/${(hash >>> 0).toString(16)}_${stat.mtime}_${stat.size}.png`;
      if (fileIo.accessSync(outputPath)) {
        results.push(`file://${outputPath}`);
        continue;
      }

      const imageSource = image.createImageSource(localPath);
      const imageInfo = await imageSource.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      if (width <= 0 || height <= 0) {
        await imageSource.release();
        results.push('');
        continue;
      }

      const scale = Math.min(thumbnailSize / width, thumbnailSize / height);
      const pixelMap = await imageSource.createPixelMap({
        desiredSize: {
          width: Math.max(1, Math.round(width * scale)),
          height: Math.max(1, Math.round(height * scale))
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      await imageSource.release();

      const imagePacker = image.createImagePacker();
      const data = await imagePacker.packToData(pixelMap, { format: 'image/png', quality: 100 });
      await imagePacker.release();
      pixelMap.release();

      const output = fileIo.openSync(outputPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(output.fd, data);
      fileIo.closeSync(output);
      results.push(`file://${outputPath}`);
    } catch (_) {
      results.push('');
    }
  }
  return results;
}
