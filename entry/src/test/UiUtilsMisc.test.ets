import { describe, it, expect } from '@ohos/hypium';
import { throttle } from 'common';
import { delay, nowUnixSeconds, padZero } from 'common';
import {
  reportTokenBatchProgress,
  TokenBatchProgress,
  TokenBatchStage,
} from 'common';

/**
 * UI 旁路纯函数测试：UiUtils.throttle、TokenBatchProgress 观察者协议、
 * CommonUtils 时间/延时工具。均不依赖 UI 上下文。
 */

function waitMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

export default function uiUtilsMiscTest() {
  describe('uiUtilsMiscTest', () => {
    it('throttle_executes_once_per_window', 0, async () => {
      let count = 0;
      const handler = (event: ClickEvent): void => {
        count++;
      };
      const throttled = throttle(handler, 60);

      throttled({} as ClickEvent);
      throttled({} as ClickEvent);
      throttled({} as ClickEvent);
      expect(count).assertEqual(1);

      await waitMs(80);
      throttled({} as ClickEvent);
      expect(count).assertEqual(2);
    });

    it('default_throttle_window_is_one_second', 0, async () => {
      let count = 0;
      const throttled = throttle((event: ClickEvent): void => {
        count++;
      });

      throttled({} as ClickEvent);
      throttled({} as ClickEvent);
      expect(count).assertEqual(1);
      // 默认 1000ms 窗口内不重放；不真正等 1 秒，只验证仍处于抑制期
      await waitMs(50);
      throttled({} as ClickEvent);
      expect(count).assertEqual(1);
    });

    it('token_batch_stage_enum_order', 0, () => {
      expect(TokenBatchStage.PREPARING).assertEqual(0);
      expect(TokenBatchStage.SAVING).assertEqual(5);
      expect(TokenBatchStage.DONE).assertEqual(10);
    });

    it('report_progress_invokes_observer_with_snapshot', 0, () => {
      const seen: TokenBatchProgress[] = [];
      reportTokenBatchProgress((progress: TokenBatchProgress): void => {
        seen.push(progress);
      }, TokenBatchStage.SAVING, 64, 128);

      expect(seen.length).assertEqual(1);
      expect(seen[0].stage).assertEqual(TokenBatchStage.SAVING);
      expect(seen[0].completed).assertEqual(64);
      expect(seen[0].total).assertEqual(128);
    });

    it('missing_or_throwing_observer_never_breaks_persistence', 0, () => {
      // 无观察者：静默返回
      reportTokenBatchProgress(undefined, TokenBatchStage.COMMITTING);

      // 观察者抛异常不得向事务传播（UI 已销毁时不能回滚数据）
      let reached = false;
      try {
        reportTokenBatchProgress((progress: TokenBatchProgress): void => {
          throw new Error('observer gone');
        }, TokenBatchStage.ROLLING_BACK);
        reached = true;
      } catch (e) {
        reached = false;
      }
      expect(reached).assertTrue();
    });

    it('common_utils_delay_resolves', 0, async () => {
      // LocalUnit 下 Date.now() 同样被 stub（不推进），无法断言真实耗时；
      // 契约锁定为：delay 返回的 Promise 在定时器触发后 resolve。
      let resolved = false;
      await delay(5).then(() => {
        resolved = true;
      });
      expect(resolved).assertTrue();
    });

    it('common_utils_now_unix_seconds_returns_finite_number', 0, () => {
      const now = nowUnixSeconds();
      // LocalUnit 下 systemDateTime 被 stub（不与真实时钟对齐），真机回归校准时钟一致性；
      // 这里只锁定契约：返回有限数值，供 TOTP 计算取模使用。
      expect(typeof now === 'number' && !isNaN(now) && isFinite(now)).assertTrue();
      expect(padZero(5)).assertEqual('05');
    });
  });
}
