import { describe, it, expect } from '@ohos/hypium';
import {
  CloudCacheClient, CloudCacheFactory, CloudCacheListener, CloudCacheState, CloudCacheTimer,
  CloudFileCacheLoader, waitForCloudFileCache,
} from 'common';
import { cloudTestTurn } from './fakes/CloudCacheFakes';

class ManualCacheTimer implements CloudCacheTimer {
  callbacks: Map<number, () => void> = new Map();
  nextId: number = 0;

  schedule(callback: () => void, _milliseconds: number): number {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id;
  }

  cancel(id: number): void {
    this.callbacks.delete(id);
  }

  expire(): void {
    const callbacks = Array.from(this.callbacks.values());
    for (const callback of callbacks) {
      callback();
    }
  }
}

class FakeCacheClient implements CloudCacheClient {
  listener: CloudCacheListener | null = null;
  offCalls: number = 0;
  stopCalls: number = 0;
  startCalls: number = 0;
  failOn: boolean = false;
  failStart: boolean = false;
  failOff: boolean = false;
  failStop: boolean = false;
  holdStart: boolean = false;
  holdStop: boolean = false;
  private releaseStop: (() => void) | null = null;
  completeDuringStart: boolean = false;
  private release: (() => void) | null = null;

  onProgress(listener: CloudCacheListener): void {
    if (this.failOn) {
      throw new Error('on failed');
    }
    this.listener = listener;
  }

  offProgress(): void {
    this.offCalls++;
    this.listener = null;
    if (this.failOff) {
      throw new Error('off failed');
    }
  }

  async start(uri: string): Promise<void> {
    this.startCalls++;
    if (this.completeDuringStart) {
      this.emit(CloudCacheState.COMPLETED, uri);
    }
    if (this.failStart) {
      throw new Error('start failed');
    }
    if (this.holdStart) {
      await new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
    }
  }

  async stop(_uri: string): Promise<void> {
    this.stopCalls++;
    if (this.failStop) {
      throw new Error('stop failed');
    }
    if (this.holdStop) {
      await new Promise<void>((resolve: () => void) => { this.releaseStop = resolve; });
    }
  }

  acceptStop(): void {
    if (this.releaseStop !== null) {
      this.releaseStop();
      this.releaseStop = null;
    }
  }

  acceptStart(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }

  emit(state: CloudCacheState, uri: string = 'file:///backup', error: number = 0): void {
    if (this.listener !== null) {
      this.listener({ uri: uri, state: state, error: error });
    }
  }
}

class FakeCacheFactory implements CloudCacheFactory {
  clients: FakeCacheClient[] = [];
  holdFirstStart: boolean = false;
  holdFirstStop: boolean = false;
  failFirstStop: boolean = false;

  create(): CloudCacheClient {
    const client = new FakeCacheClient();
    if (this.clients.length === 0) {
      client.holdStart = this.holdFirstStart;
      client.holdStop = this.holdFirstStop;
      client.failStop = this.failFirstStop;
    }
    this.clients.push(client);
    return client;
  }

  toUri(path: string): string {
    return `file://${path}`;
  }
}

async function rejected(promise: Promise<void>): Promise<boolean> {
  try {
    await promise;
    return false;
  } catch (_) {
    return true;
  }
}

export default function cloudFileCacheLoaderTest() {
  describe('cloudFileCacheLoaderTest', () => {
    it('cache_waits_for_matching_completed_not_start_or_running', 0, async () => {
      const client = new FakeCacheClient();
      const timer = new ManualCacheTimer();
      let done = false;
      const pending = waitForCloudFileCache(client, 'file:///backup', timer, 1000).then(() => { done = true; });
      await cloudTestTurn();
      expect(done).assertFalse();
      client.emit(CloudCacheState.COMPLETED, 'file:///other');
      client.emit(CloudCacheState.RUNNING);
      await cloudTestTurn();
      expect(done).assertFalse();
      client.emit(CloudCacheState.COMPLETED);
      await pending;
      expect(done).assertTrue();
      expect(client.offCalls).assertEqual(1);
      expect(timer.callbacks.size).assertEqual(0);
    });

    it('cache_handles_completion_before_start_acknowledgment', 0, async () => {
      const client = new FakeCacheClient();
      client.holdStart = true;
      client.completeDuringStart = true;
      const timer = new ManualCacheTimer();
      let done = false;
      const pending = waitForCloudFileCache(client, 'file:///backup', timer, 1000).then(() => { done = true; });
      await cloudTestTurn();
      expect(done).assertFalse();
      client.acceptStart();
      await pending;
      expect(done).assertTrue();
    });

    it('cache_rejects_failed_stopped_and_error_progress', 0, async () => {
      for (const state of [CloudCacheState.FAILED, CloudCacheState.STOPPED, CloudCacheState.COMPLETED]) {
        const client = new FakeCacheClient();
        const timer = new ManualCacheTimer();
        const pending = rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000));
        client.emit(state, 'file:///backup', state === CloudCacheState.COMPLETED ? 1 : 0);
        expect(await pending).assertTrue();
        expect(client.offCalls).assertEqual(1);
        expect(timer.callbacks.size).assertEqual(0);
      }
    });

    it('cache_rejects_subscription_and_start_errors', 0, async () => {
      for (const subscriptionFailure of [true, false]) {
        const client = new FakeCacheClient();
        client.failOn = subscriptionFailure;
        client.failStart = !subscriptionFailure;
        const timer = new ManualCacheTimer();
        expect(await rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000))).assertTrue();
        expect(timer.callbacks.size).assertEqual(0);
        expect(client.offCalls).assertEqual(1);
      }
    });

    it('cache_timeout_cancels_and_handles_late_start_ack', 0, async () => {
      const client = new FakeCacheClient();
      client.holdStart = true;
      client.failStop = true;
      client.failOff = true;
      const timer = new ManualCacheTimer();
      const pending = rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000));
      timer.expire();
      expect(await pending).assertTrue();
      expect(client.stopCalls).assertEqual(0);
      client.acceptStart();
      await cloudTestTurn();
      expect(client.stopCalls).assertEqual(1);
      expect(timer.callbacks.size).assertEqual(0);
    });


    it('cache_timeout_blocks_queued_and_new_requests_until_native_cleanup', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.holdFirstStart = true;
      factory.holdFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = rejected(loader.cache('/backup'));
      const queued = rejected(loader.cache('/other'));
      await cloudTestTurn();
      timer.expire();
      expect(await first).assertTrue();
      expect(await queued).assertTrue();
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].acceptStart();
      await cloudTestTurn();
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].acceptStop();
      await cloudTestTurn();
      const retry = loader.cache('/backup');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(2);
      factory.clients[1].emit(CloudCacheState.COMPLETED);
      await retry;
    });

    it('cache_stop_failure_keeps_loader_closed_without_new_downloads', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.failFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      timer.expire();
      expect(await first).assertTrue();
      await cloudTestTurn();
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(await rejected(loader.cache('/different'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
    });

    it('cache_queues_and_deduplicates_and_recovers_after_failure', 0, async () => {
      const factory = new FakeCacheFactory();
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = loader.cache('/backup');
      expect(loader.cache('/backup') === first).assertTrue();
      const firstResult = rejected(first);
      const second = loader.cache('/second');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].emit(CloudCacheState.FAILED);
      expect(await firstResult).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(2);
      factory.clients[1].emit(CloudCacheState.COMPLETED, 'file:///second');
      await second;
      const retry = loader.cache('/backup');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(3);
      factory.clients[2].emit(CloudCacheState.COMPLETED);
      await retry;
      expect(timer.callbacks.size).assertEqual(0);
    });
  });
}
