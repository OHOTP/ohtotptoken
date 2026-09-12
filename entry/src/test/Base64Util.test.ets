import { describe, it, expect } from '@ohos/hypium';
import { Base64Util } from 'common';
import { utf8ToBytes } from '../main/ets/steam/SteamCrypto';

/**
 * Base64Util 测试——同时固化一项 LocalUnit 运行时实测结论：
 *
 * `util.Base64Helper`（@ohos.util）在 LocalUnit / Previewer 运行时下
 * **静默返回空数据**（不抛异常）：encodeToStringSync 返回 ''、decodeSync 返回空数组。
 *
 * 结论（2026-09-11 实测）：
 * - CloudBackupCrypto 的 base64 已改为注入 Base64Codec，测试注入纯 TS 实现；
 * - 纯 TS base64 语义由 SteamCrypto（base64Encode/base64Decode）的用例覆盖；
 * - Base64Helper 的真实编解码行为归 ohosTest 真机回归。
 *
 * 若未来 LocalUnit 支持了 Base64Helper，本套件中的
 * localunit_stub_* 用例会开始失败——届时应移除 stub 断言并补上真实向量。
 */
export default function base64UtilTest() {
  describe('base64UtilTest', () => {
    it('localunit_stub_encode_returns_empty_string', 0, () => {
      // LocalUnit 下 Base64Helper.encodeToStringSync 静默返回空
      expect(Base64Util.encodeToStrSync(utf8ToBytes('foobar'))).assertEqual('');
    });

    it('localunit_stub_decode_returns_empty_bytes', 0, () => {
      const decoded = Base64Util.decodeSync('Zm9vYmFy');
      expect(decoded.length).assertEqual(0);
    });

    it('null_and_undefined_encode_to_empty_string', 0, () => {
      // 空值守卫在触碰 Base64Helper 之前返回，真机/LocalUnit 行为一致
      expect(Base64Util.encodeToStrSync(null)).assertEqual('');
      expect(Base64Util.encodeToStrSync(undefined)).assertEqual('');
    });

    it('empty_string_decode_is_safe', 0, () => {
      expect(Base64Util.decodeSync('').length).assertEqual(0);
    });

    it('async_entrypoints_resolve_without_throwing', 0, async () => {
      // LocalUnit 下异步包装同样静默返回空；契约是 Promise 正常 resolve 不抛异常
      const encoded = await Base64Util.encode(utf8ToBytes('data'));
      const text = await Base64Util.encodeToStr(utf8ToBytes('data'));
      const decoded = await Base64Util.decode('Zm9vYmFy');
      expect(encoded.length).assertEqual(0);
      expect(text).assertEqual('');
      expect(decoded.length).assertEqual(0);
    });
  });
}
