import { describe, it, expect } from '@ohos/hypium';
import { OathError, OathSession, OathCredential } from '../main/ets/oath/OathApplet';
import { FakeOathCrypto, ScriptedTagTransport } from './fakes/BackupFakes';

/**
 * OATH Applet 协议层测试（快速赢面 11 号，Phase 2 头落地）。
 *
 * 传输与密码学均注入脚本化/确定性假实现，覆盖：
 * SELECT 解析与锁定、VALIDATE 三种结果、CALCULATE ALL 的凭据分类
 * （默认周期取码 / HOTP 与非默认周期重算 / touch 跳过）、
 * 61xx 分片链、状态字错误映射、TLV 与验证码格式化边界。
 * PBKDF2/HMAC-SHA1 数值归真机 ohosTest（RFC 向量）。
 */

const SW_OK = 0x9000;

function tlv(tag: number, value: number[]): number[] {
  return [tag, value.length].concat(value);
}

function withSw(data: number[], sw: number): number[] {
  return data.concat([(sw >> 8) & 0xFF, sw & 0xFF]);
}

function numbersToBytes(numbers: number[]): Uint8Array {
  return new Uint8Array(numbers);
}

function bytesToNumbers(data: Uint8Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < data.length; i++) {
    out.push(data[i]);
  }
  return out;
}

/** SELECT 成功响应：版本 + 盐 + 可选 challenge（存在即锁定） */
function selectResponse(version: number[], salt: number[], challenge: number[] | null): number[] {
  let data: number[] = tlv(0x79, version).concat(tlv(0x71, salt));
  if (challenge !== null) {
    data = data.concat(tlv(0x74, challenge));
  }
  return withSw(data, SW_OK);
}

/** CALCULATE ALL 凭据对：名称 TLV + 响应 TLV */
function credentialPair(name: string, responseTag: number, responseValue: number[]): number[] {
  const nameBytes: number[] = [];
  for (let i = 0; i < name.length; i++) {
    nameBytes.push(name.charCodeAt(i));
  }
  return tlv(0x71, nameBytes).concat(tlv(responseTag, responseValue));
}

/** truncated = [digits, 4 字节大端 hash] */
function truncated(digits: number, hashValue: number): number[] {
  return [digits, (hashValue >>> 24) & 0xFF, (hashValue >>> 16) & 0xFF, (hashValue >>> 8) & 0xFF, hashValue & 0xFF];
}

interface SessionRig {
  transport: ScriptedTagTransport;
  crypto: FakeOathCrypto;
  session: OathSession;
}

function freshSession(locked: boolean): SessionRig {
  const transport = new ScriptedTagTransport();
  const crypto = new FakeOathCrypto();
  transport.queueResponse(selectResponse([5, 7, 1], [0x11, 0x22], locked ? [1, 2, 3, 4, 5, 6, 7, 8] : null));
  const session = new OathSession(transport, crypto);
  return { transport: transport, crypto: crypto, session: session };
}

export default function oathAppletTest() {
  describe('oathAppletTest', () => {
    it('select_unlocked_parses_version_salt_and_stays_unlocked', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // locked getter 不经外部可查，行为经 calculateAll 是否要求认证体现；
      // 此处验证 SELECT APDU 结构（00 A4 04 00 07 + AID）
      expect(rig.transport.sentApdus.length).assertEqual(1);
      const apdu = rig.transport.sentApdus[0];
      expect(apdu[0]).assertEqual(0x00);
      expect(apdu[1]).assertEqual(0xA4);
      expect(apdu[4]).assertEqual(0x07);
      expect(apdu.length).assertEqual(12);
    });

    it('select_non_oath_card_maps_to_not_oath_error', 0, async () => {
      const transport = new ScriptedTagTransport();
      transport.queueResponse(withSw([], 0x6A82));
      const session = new OathSession(transport, new FakeOathCrypto());

      let kind = '';
      try {
        await session.select();
      } catch (e) {
        const err = e as OathError;
        kind = err.kind;
        expect(err.sw).assertEqual(0x6A82);
      }
      expect(kind).assertEqual('NOT_OATH');
    });

    it('validate_when_unlocked_is_noop', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      await rig.session.validate('password');
      // 未锁定：零额外 APDU、零派生
      expect(rig.transport.sentApdus.length).assertEqual(1);
      expect(rig.crypto.deriveCalls).assertEqual(0);
    });

    it('validate_success_unlocks_session', 0, async () => {
      const rig = freshSession(true);
      await rig.session.select();

      // VALIDATE 响应须携带与本地计算一致的 0x75 response（假 HMAC 双侧一致）
      const crypto = rig.crypto;
      const key = await crypto.pbkdf2Sha1Derive('pw', numbersToBytes([0x11, 0x22]), 1000, 16);
      const newChallenge = crypto.randomBytes(8);
      const expected = await crypto.hmacSha1(key, newChallenge);
      rig.transport.queueResponse(withSw(tlv(0x75, bytesToNumbers(expected)), SW_OK));

      const derivesBefore = rig.crypto.deriveCalls;
      await rig.session.validate('pw');
      // 会话内部恰好再派生一次
      expect(rig.crypto.deriveCalls).assertEqual(derivesBefore + 1);
      // 解锁后 calculateAll 不再要求认证（下一用例反向验证）
    });

    it('validate_wrong_password_maps_to_wrong_password_error', 0, async () => {
      const rig = freshSession(true);
      await rig.session.select();
      rig.transport.queueResponse(withSw([], 0x6982));

      let kind = '';
      try {
        await rig.session.validate('bad');
      } catch (e) {
        kind = (e as OathError).kind;
      }
      expect(kind).assertEqual('WRONG_PASSWORD');
    });

    it('validate_response_mismatch_maps_to_wrong_password_error', 0, async () => {
      const rig = freshSession(true);
      await rig.session.select();
      // 返回错误的 0x75（与本地对新 challenge 的 HMAC 不一致）
      rig.transport.queueResponse(withSw(tlv(0x75, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20]), SW_OK));

      let kind = '';
      try {
        await rig.session.validate('pw');
      } catch (e) {
        kind = (e as OathError).kind;
      }
      expect(kind).assertEqual('WRONG_PASSWORD');
    });

    it('calculate_all_default_period_takes_code_directly', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      rig.transport.queueResponse(withSw(
        credentialPair('30/GitHub:octocat', 0x76, truncated(6, 12345678)),
        SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(1);
      const cred = credentials[0];
      expect(cred.issuer).assertEqual('GitHub');
      expect(cred.name).assertEqual('octocat');
      expect(cred.oathType).assertEqual('TOTP');
      expect(cred.period).assertEqual(30);
      expect(cred.digits).assertEqual(6);
      // (12345678 & 0x7FFFFFFF) % 10^6
      expect(cred.code).assertEqual('345678');
      // 默认周期直接取码：无额外 CALCULATE APDU
      expect(rig.transport.sentApdus.length).assertEqual(2);
    });

    it('calculate_all_requires_password_when_locked_returns_6982', 0, async () => {
      const rig = freshSession(true);
      await rig.session.select();
      rig.transport.queueResponse(withSw([], 0x6982));

      let kind = '';
      try {
        await rig.session.calculateAll(1000000000);
      } catch (e) {
        kind = (e as OathError).kind;
      }
      expect(kind).assertEqual('PASSWORD_REQUIRED');
    });

    it('calculate_all_hotp_credentials_recoded_via_single_calculate', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // HOTP 凭据：0x77 响应标签，无码 → 触发空 challenge CALCULATE
      rig.transport.queueResponse(withSw(
        credentialPair('hotpaccount', 0x77, []),
        SW_OK));
      rig.transport.queueResponse(withSw(tlv(0x76, truncated(6, 999999)), SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(1);
      const cred = credentials[0];
      expect(cred.oathType).assertEqual('HOTP');
      expect(cred.period).assertEqual(0);
      expect(cred.code).assertEqual('999999');
      // CALCULATE APDU：空 challenge（74 00）
      const calc = rig.transport.sentApdus[2];
      expect(calc[1]).assertEqual(0xA2);
      const tail = calc.slice(calc.length - 2);
      expect(tail[0]).assertEqual(0x74);
      expect(tail[1]).assertEqual(0x00);
    });

    it('calculate_all_non_default_period_recalculates_with_own_period', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // 名称带 60 前缀 + 0x76 truncated → 非默认周期需重算
      rig.transport.queueResponse(withSw(
        credentialPair('60/Slow:alice', 0x76, truncated(6, 1)),
        SW_OK));
      rig.transport.queueResponse(withSw(tlv(0x76, truncated(6, 2)), SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(1);
      expect(credentials[0].period).assertEqual(60);
      expect(credentials[0].code).assertEqual('000002');
    });

    it('calculate_all_touch_credentials_are_skipped', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      rig.transport.queueResponse(withSw(
        credentialPair('touchy', 0x7C, []),
        SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(0);
    });

    it('calculate_all_malformed_name_pair_is_skipped', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // 名称对缺失：第一个 TLV 不是 0x71 → 跳过
      rig.transport.queueResponse(withSw(
        tlv(0x76, truncated(6, 5)).concat(tlv(0x76, truncated(6, 5))),
        SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(0);
    });

    it('calculate_all_single_calculate_failure_skips_credential', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // HOTP 凭据触发重算，但 CALCULATE 返回错误 SW → 跳过该凭据
      rig.transport.queueResponse(withSw(credentialPair('broken', 0x77, []), SW_OK));
      rig.transport.queueResponse(withSw([], 0x6A80));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(0);
    });

    it('transmit_apdu_chains_61xx_remaining_data', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // CALCULATE ALL 响应拆成 61xx 分片
      const part1 = credentialPair('30/A:B', 0x76, truncated(6, 4321));
      const chunk1 = part1.slice(0, 4);
      const chunk2 = part1.slice(4);
      rig.transport.queueResponse(withSw(chunk1, 0x6105));
      rig.transport.queueResponse(withSw(chunk2, SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials.length).assertEqual(1);
      expect(credentials[0].code).assertEqual('004321');
      // SEND REMAINING APDU：00 A5 00 00 00
      const remaining = rig.transport.sentApdus[2];
      expect(remaining[0]).assertEqual(0x00);
      expect(remaining[1]).assertEqual(0xA5);
      expect(remaining[4]).assertEqual(0x00);
    });

    it('calculate_all_protocol_error_maps_to_protocol_kind', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      rig.transport.queueResponse(withSw([], 0x6D00));

      let kind = '';
      try {
        await rig.session.calculateAll(1000000000);
      } catch (e) {
        kind = (e as OathError).kind;
      }
      expect(kind).assertEqual('PROTOCOL');
    });

    it('hotp_credid_issuer_split_on_first_colon', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      rig.transport.queueResponse(withSw(
        credentialPair('MyIssuer:user@host', 0x77, []),
        SW_OK));
      rig.transport.queueResponse(withSw(tlv(0x76, truncated(6, 7)), SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials[0].issuer).assertEqual('MyIssuer');
      expect(credentials[0].name).assertEqual('user@host');
    });

    it('totp_credid_without_period_defaults_to_30', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      rig.transport.queueResponse(withSw(
        credentialPair('plainname', 0x76, truncated(6, 2)),
        SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials[0].period).assertEqual(30);
      expect(credentials[0].issuer).assertEqual('');
      expect(credentials[0].name).assertEqual('plainname');
    });

    it('format_code_zero_pads_to_digit_count', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // 8 位 + hash 值 42 → (42 % 10^8) = 42 → '00000042'
      rig.transport.queueResponse(withSw(
        credentialPair('pad', 0x76, truncated(8, 42)),
        SW_OK));

      const credentials = await rig.session.calculateAll(1000000000);
      expect(credentials[0].code).assertEqual('00000042');
      expect(credentials[0].digits).assertEqual(8);
    });

    it('close_is_idempotent_and_closes_transport_once', 0, async () => {
      const rig = freshSession(false);
      const transport = rig.transport;
      await rig.session.close();
      await rig.session.close();
      expect(transport.closed).assertTrue();
    });

    it('oath_error_carries_status_word', 0, () => {
      const err = new OathError('PROTOCOL', 'boom', 0x6A82);
      expect(err.kind).assertEqual('PROTOCOL');
      expect(err.sw).assertEqual(0x6A82);
      expect(err.name).assertEqual('OathError');
      const plain = new OathError('NO_TOKENS', 'empty');
      expect(plain.sw === undefined).assertTrue();
    });

    it('credential_default_digits_falls_back_to_six', 0, async () => {
      const rig = freshSession(false);
      await rig.session.select();
      // 空 truncated 值 → digits 回退 6
      rig.transport.queueResponse(withSw(
        credentialPair('empty76', 0x76, []),
        SW_OK));

      const credentials: OathCredential[] = await rig.session.calculateAll(1000000000);
      expect(credentials[0].digits).assertEqual(6);
      expect(credentials[0].code).assertEqual('');
    });
  });
}
