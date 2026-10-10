import { CloudFileCacher, FsStatInfo } from 'common';
import { MemoryFs } from './BackupFakes';

export class MissingCloudFileError extends Error {
  code: number = 13900002;
}

export class DownloadAwareFs extends MemoryFs {
  failList: boolean = false;
  failStatFor: Set<string> = new Set();
  failDeleteFor: Set<string> = new Set();
  readPaths: string[] = [];

  async listFiles(dir: string): Promise<string[]> {
    if (this.failList) {
      throw new Error('list unavailable');
    }
    return super.listFiles(dir);
  }

  async stat(path: string): Promise<FsStatInfo> {
    if (this.failStatFor.has(path)) {
      throw new Error('stat unavailable');
    }
    if (!this.files.has(path) && !this.dirs.has(path)) {
      throw new MissingCloudFileError('missing cloud file');
    }
    return super.stat(path);
  }

  async readTextFile(path: string): Promise<string> {
    this.readPaths.push(path);
    if (this.locationOverride.get(path) === 2) {
      throw new Error('download not completed');
    }
    return super.readTextFile(path);
  }

  async deleteFile(path: string): Promise<void> {
    if (this.failDeleteFor.has(path) || this.locationOverride.get(path) === 2) {
      throw new Error('delete unavailable');
    }
    await super.deleteFile(path);
  }
}

export class FakeFileCacher implements CloudFileCacher {
  calls: string[] = [];
  fail: boolean = false;
  hang: boolean = false;
  private fs: MemoryFs;
  private release: (() => void) | null = null;

  constructor(fs: MemoryFs) {
    this.fs = fs;
  }

  async cache(path: string): Promise<void> {
    this.calls.push(path);
    if (this.fail) {
      throw new Error('cache failed');
    }
    if (this.hang) {
      await new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
    }
    this.fs.locationOverride.set(path, 3);
  }

  complete(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}

export function cloudTestTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 1);
  });
}
