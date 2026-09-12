import { fileIo as fs, picker } from "@kit.CoreFileKit";
import { common } from '@kit.AbilityKit';
import { intArrayToString } from "./TokenUtils";
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer } from '@kit.ArkTS';

const BUFFER_SIZE = 4096;

/** 分块读取端口：生产包装 fs.readSync，测试注入内存分块。 */
export interface ChunkedTextReader {
  /** 读取一个 BUFFER_SIZE 块到内部缓冲，返回实际字节数 */
  readChunk(offset: number): number;
  /** 当前块缓冲（readChunk 之后有效） */
  chunkBuffer(): ArrayBuffer;
  close(): void;
}

/** 固定块循环读取拼接文本（读满一块才继续）。从 readFileContent 抽出的可测核心。 */
export async function readTextViaChunks(reader: ChunkedTextReader): Promise<string> {
  let content = '';
  let offset = 0;
  let readOut = 0;
  do {
    readOut = reader.readChunk(offset);
    content += intArrayToString(reader.chunkBuffer().slice(0, readOut));
    offset += BUFFER_SIZE;
  } while (readOut == BUFFER_SIZE)
  reader.close();
  return content;
}

class FsChunkedTextReader implements ChunkedTextReader {
  private fd: number;
  private chunk: ArrayBuffer = new ArrayBuffer(BUFFER_SIZE);

  constructor(fd: number) {
    this.fd = fd;
  }

  readChunk(offset: number): number {
    this.chunk = new ArrayBuffer(BUFFER_SIZE);
    return fs.readSync(this.fd, this.chunk, { offset: offset });
  }

  chunkBuffer(): ArrayBuffer {
    return this.chunk;
  }

  close(): void {
    fs.close(this.fd);
  }
}

export async function readFileContent(uri: string): Promise<string> {
  const f = await fs.open(uri, fs.OpenMode.READ_ONLY);
  return await readTextViaChunks(new FsChunkedTextReader(f.fd));
}

export async function readFileContentAndCheckSize(uri: string, MaxSize: number): Promise<string> {
  const f = await fs.open(uri, fs.OpenMode.READ_ONLY);
  const stat = fs.statSync(f.fd);
  if (stat.size > MaxSize) {
    fs.close(f.fd);
    return '';
  }
  return await readTextViaChunks(new FsChunkedTextReader(f.fd));
}

export async function writeFileContent(uri: string, content: string): Promise<void> {
  //调整为覆盖写入 只写入 并且创建新文件
  fs.open(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.CREATE).then((f) => {
    fs.write(f.fd, content).then(() => {
      fs.close(f.fd);
    });
  }).catch((reason: BusinessError) => {
    hilog.error(reason.code, 'FileUtils', reason.message)
  });
}

/** 哈希防重写入端口：生产实现走 fs + Sha256Hash。 */
export interface HashCompareWriteIo {
  fileExists(uri: string): Promise<boolean>;
  readText(uri: string): Promise<string>;
  writeText(uri: string, content: string): Promise<void>;
}

//固定使用sha256比对是否相同hash 暂不考虑不同hash长度比对
export function constantTimeCompare(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }

  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i]; // 按位异或后累积差异
  }

  return result === 0;
}

/**
 * 内容哈希相同则跳过写入（可测核心）。
 * 文件不存在 → 直接写入；存在且哈希一致 → 跳过；不一致 → 覆盖写入。
 */
export async function writeTextIfHashDiffers(io: HashCompareWriteIo,
  hash: (content: string) => Promise<Uint8Array>,
  uri: string, content: string): Promise<void> {
  let isWrite = true;
  if (await io.fileExists(uri)) {
    let fileContent = await io.readText(uri);
    let fileHash = await hash(fileContent);
    let contentHash = await hash(content);
    isWrite = !constantTimeCompare(fileHash, contentHash);//比对哈希不同才写入
  }
  // 比对哈希不同才写入
  if (isWrite) {
    await io.writeText(uri, content);
  }
}

class FsHashCompareWriteIo implements HashCompareWriteIo {
  async fileExists(uri: string): Promise<boolean> {
    return await fs.access(uri);
  }

  async readText(uri: string): Promise<string> {
    return readFileContent(uri);
  }

  async writeText(uri: string, content: string): Promise<void> {
    //调整为覆盖写入 只写入 并且创建新文件（与历史行为一致：写失败仅记日志不上抛）
    await fs.open(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.CREATE).then((f) => {
      fs.write(f.fd, content).then(() => {
        fs.close(f.fd);
      });
    }).catch((reason: BusinessError) => {
      hilog.error(reason.code, 'FileUtils', reason.message)
    });
  }
}

//写入文件确认文件是否重复 如果重复放弃写入
export async function writeFileContentCheckHashEqual(uri: string, content: string): Promise<void> {
  await writeTextIfHashDiffers(new FsHashCompareWriteIo(), Sha256Hash, uri, content);
}

export async function Sha256Hash(content: string) {
  let mdAlgName = 'SHA256'; // 摘要算法名。
  let md = cryptoFramework.createMd(mdAlgName);
  // 数据量较少时，可以只做一次update，将数据全部传入，接口未对入参长度做限制。
  await md.update({ data: new Uint8Array(buffer.from(content, 'utf-8').buffer) });
  let mdResult = await md.digest();
  hilog.info(0, 'FileUtils', 'Md result:' + mdResult.data);
  return mdResult.data;
}

export async function showSelectFilePicker(max_num: number, filters: string[]): Promise<string[]> {
  const documentSelectOptions = new picker.DocumentSelectOptions();
  documentSelectOptions.maxSelectNumber = max_num;
  documentSelectOptions.fileSuffixFilters = filters;
  let context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  const documentViewPicker = new picker.DocumentViewPicker(context);
  return documentViewPicker.select(documentSelectOptions);
}

export async function showSaveFilePicker(name: string[], filters: string[]): Promise<string[]> {
  const documentSaveOptions = new picker.DocumentSaveOptions();
  documentSaveOptions.newFileNames = name;
  documentSaveOptions.fileSuffixChoices = filters;
  let context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  const documentViewPicker = new picker.DocumentViewPicker(context);
  return documentViewPicker.save(documentSaveOptions);
}
