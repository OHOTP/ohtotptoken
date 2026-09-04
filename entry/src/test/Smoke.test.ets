import { describe, it, expect } from '@ohos/hypium';

/**
 * Framework sanity checks: no project imports, no @ohos.* APIs.
 * If anything here fails, the LocalUnit runtime itself is broken.
 */
export default function smokeTest() {
  describe('smokeTest', () => {
    it('math_basics', 0, () => {
      expect(2 + 2).assertEqual(5);
      expect(Math.floor(7 / 2)).assertEqual(3);
      expect(0x66).assertEqual(102);
    });

    it('string_utf8_codepoints', 0, () => {
      let s = 'foo';
      expect(s.charCodeAt(0)).assertEqual(0x66);
      expect(s.charCodeAt(1)).assertEqual(0x6f);
      expect(s.toUpperCase().replace(/=+$/, '')).assertEqual('FOO');
    });

    it('json_roundtrip', 0, () => {
      interface OtpInfo {
        issuer: string;
        digits: number;
        period: number;
      }
      let obj: OtpInfo = { issuer: 'GitHub', digits: 6, period: 30 };
      let parsed = JSON.parse(JSON.stringify(obj)) as OtpInfo;
      expect(parsed.issuer).assertEqual('GitHub');
      expect(parsed.digits).assertEqual(6);
    });

    it('uint8array_bit_ops', 0, () => {
      let value = 0x66;
      let out = new Uint8Array(2);
      out[0] = (value >>> 2) & 31;
      out[1] = (value << 3) & 255;
      expect(out[0]).assertEqual(25);
      expect(out[1]).assertEqual(48);
      expect(Array.from(out).join(',')).assertEqual('25,48');
    });

    it('promise_await', 0, async () => {
      let result = await Promise.resolve(42);
      expect(result).assertEqual(42);
    });
  });
}
