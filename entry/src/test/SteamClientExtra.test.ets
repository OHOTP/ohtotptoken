import { describe, it, expect } from '@ohos/hypium';
import { HttpRequestSpec, HttpResult, HttpTransport, SteamTransport } from '../main/ets/steam/SteamHttp';
import { ProtoReader, ProtoWriter } from 'common';
import {
  Sleeper,
  SteamAccessToken,
  SteamAuthSession,
  SteamClient,
  SteamQrChallenge,
} from '../main/ets/steam/SteamClient';
import { base64Decode, base64Encode, utf8ToBytes } from '../main/ets/steam/SteamCrypto';
import { EAuthSessionGuardType } from '../main/ets/steam/proto/SteamMessages';

/**
 * Steam 客户端补充测试：接续 SteamClient.test.ets（轮询/确认已覆盖），
 * 这里覆盖 RSA 公钥解析、BeginAuthSession 响应解码（含 float interval）、
 * newClientId 迁移分支、迁移/撤销/状态查询全链路与请求体字段回读。
 * 全部走假传输层，无网络。
 */

const STEAMID = 76561198000000000n;
const SECRET_B64 = 'MDEyMzQ1Njc4OWFiY2RlZg==';

class FakeSleeper implements Sleeper {
  sleep(ms: number): Promise<void> {
    return Promise.resolve();
  }
}

class FakeTransport implements HttpTransport {
  specs: HttpRequestSpec[] = [];
  private queue: HttpResult[] = [];

  push(result: HttpResult): void {
    this.queue.push(result);
  }

  send(spec: HttpRequestSpec): Promise<HttpResult> {
    this.specs.push(spec);
    const next: HttpResult | undefined = this.queue.shift();
    return Promise.resolve(next === undefined ? new HttpResult() : next);
  }
}

function okResult(bytes: Uint8Array): HttpResult {
  const result = new HttpResult();
  result.statusCode = 200;
  result.headers = { 'x-eresult': '1' };
  result.bytes = bytes;
  return result;
}

function okText(text: string): HttpResult {
  const result = new HttpResult();
  result.statusCode = 200;
  result.headers = { 'x-eresult': '1' };
  result.text = text;
  return result;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) {
    total += p.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

/** ProtoWriter 不支持写 float（fixed32 LE），这里手工编码 field tag + IEEE754 LE */
function fieldFloat32(field: number, value: number): Uint8Array {
  const dv = new DataView(new ArrayBuffer(4));
  dv.setFloat32(0, value, true);
  const tagByte = (field << 3) | 5;
  const tagBytes: Uint8Array = tagByte < 0x80
    ? new Uint8Array([tagByte])
    : new Uint8Array([0x80 | (tagByte & 0x7f), tagByte >> 7]);
  return concatBytes([tagBytes, new Uint8Array(dv.buffer)]);
}

function beginAuthBytes(includeInterval: boolean): Uint8Array {
  const w = new ProtoWriter();
  w.writeUint64(1, 987654321n);
  w.writeBytes(2, Uint8Array.from([9, 8, 7]));
  const confirm = new ProtoWriter();
  confirm.writeInt32(1, EAuthSessionGuardType.DEVICE_CODE);
  confirm.writeString(2, 'check your device');
  w.writeMessage(4, confirm);
  const confirm2 = new ProtoWriter();
  confirm2.writeInt32(1, EAuthSessionGuardType.EMAIL_CODE);
  w.writeMessage(4, confirm2);
  w.writeUint64(5, STEAMID);
  if (includeInterval) {
    return concatBytes([w.finish(), fieldFloat32(3, 7.0)]);
  }
  return w.finish();
}

function pollBytesAuthorized(newClientId: bigint): Uint8Array {
  const w = new ProtoWriter();
  // field 1: newClientId —— 迁移分支只有拿到凭证后才会执行
  w.writeUint64(1, newClientId);
  w.writeString(3, 'refresh-xyz');
  w.writeString(4, 'access-xyz');
  w.writeString(6, 'account');
  return w.finish();
}

/** 回读请求体：input_protobuf_encoded=<percent(base64(payload))> → 原始 protobuf 字节 */
function decodeProtoFromBody(body: string): Uint8Array {
  const prefix = 'input_protobuf_encoded=';
  expect(body.startsWith(prefix)).assertTrue();
  return base64Decode(decodeURIComponent(body.substring(prefix.length)));
}

function readFieldString(buf: Uint8Array, fieldNo: number): string {
  const r = new ProtoReader(buf);
  while (r.next()) {
    if (r.field() === fieldNo) {
      return r.readString();
    }
    r.skip();
  }
  return '';
}

function readFieldBool(buf: Uint8Array, fieldNo: number): boolean {
  const r = new ProtoReader(buf);
  while (r.next()) {
    if (r.field() === fieldNo) {
      return r.readBool();
    }
    r.skip();
  }
  return false;
}

const RSA_JSON = '{"response":{"publickey_mod":"EFCDAB8974523011234567890ABCDEF0",'
  + '"publickey_exp":"010001","timestamp":"1700000001"}}';

export default function steamClientExtraTest() {
  describe('steamClientExtraTest', () => {
    it('get_password_rsa_public_key_parses_response', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okText(RSA_JSON));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const key = await client.getPasswordRsaPublicKey('gabe');

      expect(key.publickeyMod).assertEqual('EFCDAB8974523011234567890ABCDEF0');
      expect(key.publickeyExp).assertEqual('010001');
      expect(key.timestamp.toString()).assertEqual('1700000001');
      expect(transport.specs[0].method).assertEqual('GET');
      expect(transport.specs[0].url.indexOf('account_name=gabe') > 0).assertTrue();
    });

    it('begin_auth_session_decodes_interval_and_confirmations', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okText(RSA_JSON));
      transport.push(okResult(beginAuthBytes(true)));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const session = await client.beginAuthSession('gabe', 'pw', 'My Device');

      expect(session.clientId.toString()).assertEqual('987654321');
      expect(Array.from(session.requestId).join(',')).assertEqual('9,8,7');
      // 服务端 interval（float 字段）优先生效
      expect(session.intervalSeconds).assertEqual(7);
      expect(session.steamid.toString()).assertEqual(STEAMID.toString());
      expect(session.preferredConfirmation()!.confirmationType)
        .assertEqual(EAuthSessionGuardType.DEVICE_CODE);
      expect(session.requiresCode()).assertTrue();
    });

    it('begin_auth_session_defaults_interval_when_missing', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okText(RSA_JSON));
      transport.push(okResult(beginAuthBytes(false)));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const session = await client.beginAuthSession('gabe', 'pw', 'dev');
      expect(session.intervalSeconds).assertEqual(5);
    });

    it('poll_migrates_client_id_when_server_assigns_new_one', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okResult(pollBytesAuthorized(424242n)));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const session = new SteamAuthSession();
      session.clientId = 1n;
      session.requestId = new Uint8Array(0);
      session.intervalSeconds = 1;

      // 拿到凭证且服务端下发了 newClientId → 会话被迁移
      const done = await client.pollAuthSessionStatus(session);
      expect(done).assertTrue();
      expect(session.clientId.toString()).assertEqual('424242');
      expect(session.refreshToken).assertEqual('refresh-xyz');
      expect(session.accountName).assertEqual('account');
    });

    it('submit_steam_guard_code_posts_protobuf', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okResult(new Uint8Array(0)));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const session = new SteamAuthSession();
      session.clientId = 55n;
      session.steamid = STEAMID;

      await client.submitSteamGuardCode(session, 'ABC123', EAuthSessionGuardType.DEVICE_CODE);

      expect(transport.specs[0].url.indexOf('UpdateAuthSessionWithSteamGuardCode') > 0).assertTrue();
      const payload = decodeProtoFromBody(transport.specs[0].body);
      // 回读全部请求字段：clientId=varint(1)、steamid=fixed64(2)、code=string(3)、codeType=int32(4)
      const r = new ProtoReader(payload);
      let clientId = 0n;
      let steamid = 0n;
      let code = '';
      let codeType = -1;
      while (r.next()) {
        switch (r.field()) {
          case 1: clientId = r.readUint64(); break;
          case 2: steamid = r.readFixed64(); break;
          case 3: code = r.readString(); break;
          case 4: codeType = r.readInt32(); break;
          default: r.skip(); break;
        }
      }
      expect(clientId.toString()).assertEqual('55');
      expect(steamid.toString()).assertEqual(STEAMID.toString());
      expect(code).assertEqual('ABC123');
      expect(codeType).assertEqual(EAuthSessionGuardType.DEVICE_CODE);
    });

    it('finalize_add_authenticator_parses_response_and_request_fields', 0, async () => {
      const transport = new FakeTransport();
      const w = new ProtoWriter();
      w.writeBool(1, true);
      w.writeUint64(3, 1788953926n);
      w.writeInt32(4, 1);
      transport.push(okResult(w.finish()));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const response = await client.finalizeAddAuthenticator(STEAMID, 'access-1', '5digit',
        1788953925.7, 'SMS-999');

      expect(response.success).assertTrue();
      expect(response.serverTime.toString()).assertEqual('1788953926');
      expect(response.status).assertEqual(1);
      expect(transport.specs[0].url.indexOf('access_token=access-1') > 0).assertTrue();
      const payload = decodeProtoFromBody(transport.specs[0].body);
      expect(readFieldString(payload, 2)).assertEqual('5digit');
      expect(readFieldString(payload, 4)).assertEqual('SMS-999');
      expect(readFieldBool(payload, 6)).assertTrue();
    });

    it('transfer_start_and_sms_code_roundtrip', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okResult(new Uint8Array(0)));
      const response = new ProtoWriter();
      response.writeBool(1, true);
      const replacement = new ProtoWriter();
      replacement.writeBytes(1, Uint8Array.from([1, 2, 3]));
      replacement.writeString(3, 'R0V0C0DE');
      replacement.writeString(6, 'account');
      response.writeMessage(2, replacement);
      transport.push(okResult(response.finish()));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      expect(await client.startTransferAuthenticator(STEAMID, 'access-1')).assertTrue();

      const result = await client.submitTransferSmsCode(STEAMID, 'access-1', '12345');
      expect(result.success).assertTrue();
      expect(result.replacementToken!.revocationCode).assertEqual('R0V0C0DE');
      expect(result.replacementToken!.accountName).assertEqual('account');
      expect(Array.from(result.replacementToken!.sharedSecret).join(',')).assertEqual('1,2,3');

      const smsPayload = decodeProtoFromBody(transport.specs[1].body);
      expect(readFieldString(smsPayload, 1)).assertEqual('12345');
      expect(readFieldBool(smsPayload, 2)).assertTrue();
      expect(transport.specs[1].url.indexOf('access_token=access-1') > 0).assertTrue();
    });

    it('revoke_authenticator_sends_revocation_code', 0, async () => {
      const transport = new FakeTransport();
      const w = new ProtoWriter();
      w.writeBool(1, true);
      w.writeUint64(3, 42n);
      transport.push(okResult(w.finish()));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const response = await client.revokeAuthenticator(STEAMID, 'access-1', 'R0V0C0DE');

      expect(response.success).assertTrue();
      const payload = decodeProtoFromBody(transport.specs[0].body);
      expect(readFieldString(payload, 2)).assertEqual('R0V0C0DE');
    });

    it('query_status_parses_state_and_request_steamid', 0, async () => {
      const transport = new FakeTransport();
      const w = new ProtoWriter();
      w.writeUint32(1, 2);
      w.writeString(6, 'gid-88');
      w.writeBool(7, true);
      transport.push(okResult(w.finish()));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const status = await client.queryStatus(STEAMID, 'access-1');

      expect(status.state).assertEqual(2);
      expect(status.tokenGid).assertEqual('gid-88');
      expect(status.emailValidated).assertTrue();
      // steamid 在 CTwoFactor_Status_Request 里是 fixed64 字段 1
      const payload = decodeProtoFromBody(transport.specs[0].body);
      const r = new ProtoReader(payload);
      let foundSteamid = 0n;
      while (r.next()) {
        if (r.field() === 1) {
          foundSteamid = r.readFixed64();
        } else {
          r.skip();
        }
      }
      expect(foundSteamid.toString()).assertEqual(STEAMID.toString());
    });

    it('approve_qr_login_builds_signed_body_both_persistence_modes', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okResult(new Uint8Array(0)));
      transport.push(okResult(new Uint8Array(0)));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const challenge = new SteamQrChallenge();
      challenge.version = 2;
      challenge.clientId = 1234567890123456789n;

      await client.approveQrLogin(STEAMID, 'access-1', SECRET_B64, challenge, true);
      await client.approveQrLogin(STEAMID, 'access-1', SECRET_B64, challenge, false);

      const body1 = transport.specs[0].body;
      expect(body1.indexOf('confirm=true') > 0).assertTrue();
      expect(body1.indexOf('persistence=1') > 0).assertTrue();
      expect(body1.indexOf('version=2') > 0).assertTrue();
      expect(body1.indexOf('client_id=1234567890123456789') > 0).assertTrue();
      expect(body1.indexOf('signature=') > 0).assertTrue();
      expect(transport.specs[0].url.indexOf('access_token=access-1') > 0).assertTrue();

      expect(transport.specs[1].body.indexOf('persistence=0') > 0).assertTrue();
    });

    it('get_confirmations_returns_empty_when_conf_field_missing', 0, async () => {
      const transport = new FakeTransport();
      transport.push(okText('{"success":true,"message":""}'));
      const client = new SteamClient(new SteamTransport(transport), new FakeSleeper());

      const list = await client.getConfirmations(STEAMID, 'access-1', SECRET_B64, 'dev', 1788953926);
      expect(list.length).assertEqual(0);
    });

    it('access_token_validity_requires_margin_and_token', 0, () => {
      const empty = new SteamAccessToken();
      expect(empty.isValid(1000)).assertFalse();

      const shortLived = new SteamAccessToken();
      shortLived.token = 't';
      shortLived.expiresAtSeconds = 1120;
      // 余量不足 120 秒 → 视为过期，触发刷新
      expect(shortLived.isValid(1000)).assertFalse();
      expect(shortLived.isValid(999)).assertTrue();
    });

    it('base64_roundtrip_for_proto_payloads', 0, () => {
      const payload = Uint8Array.from([0, 1, 2, 250, 251, 252, 253, 254, 255]);
      expect(Array.from(base64Decode(base64Encode(payload))).join(','))
        .assertEqual(Array.from(payload).join(','));
      expect(base64Encode(utf8ToBytes('foobar'))).assertEqual('Zm9vYmFy');
    });
  });
}
