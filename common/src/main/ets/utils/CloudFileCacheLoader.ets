import { cloudSync, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xFF00;
const TAG = 'CloudFileCacheLoader';

export enum CloudCacheState {
  RUNNING = 0,
  COMPLETED = 1,
  FAILED = 2,
  STOPPED = 3,
}

export interface CloudCacheProgress {
  uri: string;
  state: CloudCacheState;
  error: number;
}

export type CloudCacheListener = (progress: CloudCacheProgress) => void;

export interface CloudCacheClient {
  onProgress(listener: CloudCacheListener): void;
  offProgress(): void;
  start(uri: string): Promise<void>;
  stop(uri: string): Promise<void>;
}

export interface CloudCacheFactory {
  create(): CloudCacheClient;
  toUri(filePath: string): string;
}

export interface CloudCacheTimer {
  schedule(callback: () => void, milliseconds: number): number;
  cancel(id: number): void;
}

export interface CloudFileCacher {
  cache(filePath: string): Promise<void>;
}

class NativeCloudCacheClient implements CloudCacheClient {
  private client: cloudSync.CloudFileCache = new cloudSync.CloudFileCache();
  private callback: ((progress: cloudSync.DownloadProgress) => void) | undefined = undefined;

  onProgress(listener: CloudCacheListener): void {
    this.callback = (progress: cloudSync.DownloadProgress): void => {
      listener({ uri: progress.uri, state: progress.state as number as CloudCacheState, error: progress.error });
    };
    this.client.on('progress', this.callback);
  }

  offProgress(): void {
    if (this.callback !== undefined) {
      this.client.off('progress', this.callback);
      this.callback = undefined;
    }
  }

  start(uri: string): Promise<void> {
    return this.client.start(uri);
  }

  stop(uri: string): Promise<void> {
    return this.client.stop(uri);
  }
}

class NativeCloudCacheFactory implements CloudCacheFactory {
  create(): CloudCacheClient {
    return new NativeCloudCacheClient();
  }

  toUri(filePath: string): string {
    return fileUri.getUriFromPath(filePath);
  }
}

class SystemCloudCacheTimer implements CloudCacheTimer {
  schedule(callback: () => void, milliseconds: number): number {
    return setTimeout(callback, milliseconds);
  }

  cancel(id: number): void {
    clearTimeout(id);
  }
}

interface CloudCacheOperation {
  result: Promise<void>;
  drained: Promise<boolean>;
}

/** start() 只确认任务启动；内容可用须等待同一实例、同一 URI 的 COMPLETED。 */
function beginCloudFileCache(client: CloudCacheClient, uri: string,
  timer: CloudCacheTimer, timeoutMs: number): CloudCacheOperation {
  let drain: (safe: boolean) => void = (_safe: boolean): void => {};
  const drained = new Promise<boolean>((resolve: (safe: boolean) => void) => { drain = resolve; });
  const result = new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
    let settled = false;
    let started = false;
    let downloaded = false;
    let needsStop = false;
    let terminalFailure = false;
    let subscribed = false;
    let timerId = -1;
    const stopAndDrain = async (): Promise<void> => {
      try {
        await client.stop(uri);
        drain(true);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, `stop failed: ${JSON.stringify(error)}`);
        drain(false);
      }
    };
    const finish = (error?: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timerId >= 0) {
        timer.cancel(timerId);
      }
      if (subscribed) {
        try {
          client.offProgress();
        } catch (offError) {
          hilog.warn(DOMAIN, TAG, `offProgress failed: ${JSON.stringify(offError)}`);
        }
      }
      if (!needsStop && !terminalFailure) {
        drain(true);
      }
      if (error !== undefined) {
        reject(error);
      } else {
        resolve();
      }
    };
    const listener: CloudCacheListener = (progress: CloudCacheProgress): void => {
      if (settled || progress.uri !== uri) {
        return;
      }
      if (progress.error !== 0 || progress.state === CloudCacheState.FAILED ||
        progress.state === CloudCacheState.STOPPED) {
        terminalFailure = progress.state === CloudCacheState.FAILED || progress.state === CloudCacheState.STOPPED;
        needsStop = !terminalFailure;
        finish(new Error(`Cloud cache failed: state=${progress.state}, error=${progress.error}`));
        if (started) {
          if (needsStop) {
            stopAndDrain();
          } else {
            drain(true);
          }
        }
      } else if (progress.state === CloudCacheState.COMPLETED) {
        downloaded = true;
        if (started) {
          finish();
        }
      }
    };
    try {
      timerId = timer.schedule(() => {
        needsStop = true;
        finish(new Error('Cloud cache timed out'));
        if (started) {
          stopAndDrain();
        }
      }, timeoutMs);
      subscribed = true;
      client.onProgress(listener);
      client.start(uri).then(() => {
        started = true;
        if (needsStop) {
          // 等启动确认后取消；清理屏障完成前，不允许另一个原生下载启动。
          stopAndDrain();
        } else if (terminalFailure) {
          drain(true);
        } else if (downloaded) {
          finish();
        }
      }).catch((error: Error) => {
        finish(error);
        drain(true);
      });
    } catch (error) {
      finish(error as Error);
      drain(true);
    }
  });
  return { result: result, drained: drained };
}

export function waitForCloudFileCache(client: CloudCacheClient, uri: string,
  timer: CloudCacheTimer, timeoutMs: number): Promise<void> {
  return beginCloudFileCache(client, uri, timer, timeoutMs).result;
}

/** 令牌与图标包共用串行队列；无法确认取消完成时拒绝后续请求，避免超出原生并发上限。 */
export class CloudFileCacheLoader implements CloudFileCacher {
  private static instance: CloudFileCacheLoader | null = null;
  private queue: Promise<void> = Promise.resolve();
  private pending: Map<string, Promise<void>> = new Map();
  private cancellationPending: boolean = false;
  private factory: CloudCacheFactory;
  private timer: CloudCacheTimer;
  private timeoutMs: number;

  constructor(factory: CloudCacheFactory = new NativeCloudCacheFactory(),
    timer: CloudCacheTimer = new SystemCloudCacheTimer(), timeoutMs: number = 60000) {
    this.factory = factory;
    this.timer = timer;
    this.timeoutMs = timeoutMs;
  }

  static getInstance(): CloudFileCacheLoader {
    if (CloudFileCacheLoader.instance === null) {
      CloudFileCacheLoader.instance = new CloudFileCacheLoader();
    }
    return CloudFileCacheLoader.instance;
  }

  cache(filePath: string): Promise<void> {
    if (this.cancellationPending) {
      return Promise.reject(new Error('Cloud cache cancellation is pending; retry after cleanup or restart'));
    }
    const existing = this.pending.get(filePath);
    if (existing !== undefined) {
      return existing;
    }
    const task = this.queue.then(() => {
      if (this.cancellationPending) {
        throw new Error('Cloud cache cancellation is pending');
      }
      const operation = beginCloudFileCache(this.factory.create(), this.factory.toUri(filePath), this.timer, this.timeoutMs);
      return operation.result.catch((error: Error) => {
        this.cancellationPending = true;
        // 不阻塞错误返回；后续请求须等待原生任务确实停止。
        operation.drained.then((safe: boolean) => {
          if (safe) {
            this.cancellationPending = false;
          }
        });
        throw error;
      });
    });
    this.pending.set(filePath, task);
    this.queue = task.then(() => {
      this.pending.delete(filePath);
    }, () => {
      this.pending.delete(filePath);
    });
    return task;
  }
}
