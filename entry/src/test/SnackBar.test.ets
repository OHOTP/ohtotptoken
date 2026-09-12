import { describe, it, expect } from '@ohos/hypium';
import {
  setSnackBarImpl,
  showSnackBar,
  SnackBarNotifyOptions,
  SnackBarNotifyType,
} from 'common';

/**
 * SnackBar 注入点测试：LocalUnit 无 UI，注入记录函数验证分发行为。
 * 注意：impl 是模块级单例，注入后会影响后续用例——保持断言不依赖默认实现。
 */
export default function snackBarTest() {
  describe('snackBarTest', () => {
    it('notify_type_enum_values', 0, () => {
      expect(SnackBarNotifyType.INFO).assertEqual('INFO');
      expect(SnackBarNotifyType.WARNING).assertEqual('WARNING');
      expect(SnackBarNotifyType.ERROR).assertEqual('ERROR');
      expect(SnackBarNotifyType.SUCCESS).assertEqual('SUCCESS');
    });

    it('show_snackbar_delegates_to_injected_impl', 0, () => {
      const calls: string[] = [];
      setSnackBarImpl((message: ResourceStr, type: SnackBarNotifyType,
        options: SnackBarNotifyOptions) => {
        calls.push(`${String(message)}|${type}|${options.duration ?? -1}`);
      });

      showSnackBar('saved', SnackBarNotifyType.SUCCESS, { duration: 1500 });
      expect(calls.length).assertEqual(1);
      expect(calls[0]).assertEqual('saved|SUCCESS|1500');

      // 默认参数：INFO 类型 + 空 options
      showSnackBar('plain');
      expect(calls.length).assertEqual(2);
      expect(calls[1]).assertEqual('plain|INFO|-1');
    });
  });
}
