import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import {
  AppPreference,
  PREF_KEYS,
  SettingValuePair,
  TokenConfig,
  TokenStore,
  WEAR_SYNC_PREF_KEYS,
  applyWearSettings,
  saveTokensBatch,
  TransferFrameBuilder,
  TransferFrameEventKind,
  TransferFrameOptions,
  TransferFrameReceiver,
  concatenateChunks,
  otpType,
} from 'common';

/**
 * 真机 WearEngine 通道冒烟（Phase 3，docs/TEST_PLAN.md 第 4 节出口条件）。
 *
 * P2P 设备发现/拉起手表应用/消息收发归真机手工与页面联调（需真实手表）；
 * 本套件在真机验证手机/手表两端共享的入库与应用逻辑：
 * 设置白名单过滤写入真实 preferences、令牌批次 issuer+name UUID 复用防重复、
 * OTPW 分帧协议重组回路。
 */

const WEAR_PREFIX = 'OTPW';

function wearReceiver(): TransferFrameReceiver {
  return new TransferFrameReceiver({ headerPrefix: WEAR_PREFIX, maxTotal: 0 } as TransferFrameOptions);
}

export default function wearEngineSmokeTest(): void {
  describe('WearEngineSmokeDeviceTest', () => {
    let context: common.UIAbilityContext;
    const ownedIds: string[] = [];

    const makeToken = (secret: string, name: string): TokenConfig => {
      const token = new TokenConfig(secret, otpType.TOTP, name, 'WearSmokeIssuer');
      ownedIds.push(token.TokenUUID);
      return token;
    };

    beforeAll(async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({
        bundleName: abilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility'
      });
      const ability = await delegator.waitAbilityMonitor(monitor, 20000);
      context = ability.context as common.UIAbilityContext;
      await delegator.removeAbilityMonitor(monitor);
      AppStorage.setOrCreate('appContext', context);
      await AppPreference.loadSettings();
      await TokenStore.getInstance().initTokenStore();
      await TokenStore.getInstance().LoadTokenByDataBase();
    });

    it('wear_settings_whitelist_filters_and_applies', 0, async () => {
      // 白名单键真实写入 preferences；白名单外键被拒。偏好改动在 finally 还原
      const keepKey = PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE;
      const original = AppPreference.getPreference(keepKey);
      try {
        const pairs: Array<SettingValuePair> = [
          { key: keepKey, value: true },
          { key: 'NOT_IN_WHITELIST', value: 'should-be-ignored' },
        ];
        const applied = await applyWearSettings(pairs);
        expect(applied).assertEqual(1);
        expect(AppPreference.getPreference(keepKey)).assertEqual(true);
      } finally {
        AppPreference.setPreference(keepKey, original);
      }
    });

    it('wear_sync_pref_keys_unique_and_nonempty', 0, () => {
      // 白名单键非空且无重复（手表端按这些键刷新 UI；键与 TokenPreference 字段的一致性由代码评审保证）
      expect(WEAR_SYNC_PREF_KEYS.length > 0).assertTrue();
      const seen: Set<string> = new Set();
      for (const key of WEAR_SYNC_PREF_KEYS) {
        expect(key.length > 0).assertTrue();
        seen.add(key);
      }
      expect(seen.size).assertEqual(WEAR_SYNC_PREF_KEYS.length);
    });

    it('wear_token_batch_reuses_local_uuid_no_duplicates', 0, async () => {
      // 本地已有 A 令牌；批次携带同 issuer+name、不同 UUID 的 B 令牌。
      // 真实写入 TokenStore/ASSET，清理放 finally 保证断言失败也不留测试数据
      const store = TokenStore.getInstance();

      const local = makeToken('JBSWY3DPEHPK3PXP', 'WearSmokeA');
      try {
        await store.updateToken(local);

        const incoming = new TokenConfig('JBSWY3DPEHPK3PXP', otpType.TOTP, 'WearSmokeA', 'WearSmokeIssuer');
        incoming.TokenUUID = 'wear-side-generated-uuid';
        const saved = await saveTokensBatch([incoming]);

        expect(saved).assertEqual(1);
        const after = await store.getTokens();
        const matches = after.filter(t => t.TokenIssuer === 'WearSmokeIssuer' && t.TokenName === 'WearSmokeA');
        // UUID 复用：同名令牌只有一条，且保留本地 UUID（防手机/手表双 UUID 重复）
        expect(matches.length).assertEqual(1);
        expect(matches[0].TokenUUID).assertEqual(local.TokenUUID);
      } finally {
        for (const uuid of ownedIds) {
          try {
            await store.deleteToken(uuid);
          } catch (_) {
            // 清理失败不掩盖用例结果（TokenBatch 套件同约定）
          }
        }
      }
    });

    it('wear_frame_protocol_roundtrip_with_prefix', 0, () => {
      // OTPW 分帧协议（首帧前缀 + 4000B 分片）真机重组回路
      const cipher = new Uint8Array(5200);
      for (let i = 0; i < cipher.length; i++) {
        cipher[i] = (i * 17) % 256;
      }
      const frames = new TransferFrameBuilder(WEAR_PREFIX, 4000).buildFrames(cipher, 26, 'settings');
      const receiver = wearReceiver();
      let done = false;
      let batchTotal = -1;
      let batchType = '';
      const chunks: Array<Uint8Array> = [];
      for (let i = 0; i < frames.length; i++) {
        const event = receiver.onFrame(frames[i].bytes);
        if (event.kind === TransferFrameEventKind.BATCH_COMPLETE) {
          done = true;
          batchTotal = event.batch!.total;
          batchType = event.batch!.type;
          for (let j = 0; j < event.batch!.chunks.length; j++) {
            chunks.push(event.batch!.chunks[j]);
          }
        }
      }
      expect(done).assertTrue();
      expect(batchTotal).assertEqual(5200);
      expect(batchType).assertEqual('settings');
      const reassembled = concatenateChunks(batchTotal, chunks);
      let identical = true;
      for (let i = 0; i < cipher.length; i++) {
        if (reassembled[i] !== cipher[i]) {
          identical = false;
          break;
        }
      }
      expect(identical).assertTrue();
    });
  });
}
