import { describe, it, expect } from '@ohos/hypium';
import { AppStorageV2 } from '@kit.ArkUI';
import {
  AppPreference,
  AVAILABLE_BOTTOM_TABS_TYPES,
  AVAILABLE_HIDDEN_TOKEN_TYPES,
  AVAILABLE_IMMERSIVE_STYLES,
  AVAILABLE_TOKEN_PROGRESS_TYPES,
  AVAILABLE_TOKEN_SEPARATORS,
  AVAILABLE_TOP_EFFECT_TYPES,
  BUILTIN_DEFAULT_PACK_ID,
  EVENT_NAMES,
  EXTERNAL_URLS,
  PREF_KEYS,
  ROUTE_NAMES,
  SettingBottomTabsType,
  SettingColorMode,
  SettingHiddenTokenType,
  SettingImmersiveStyle,
  SettingTokenProgressType,
  SettingTokenSeparator,
  SettingTopEffectType,
  TokenPreference,
} from 'common';

/**
 * AppPreference 纯部分测试：默认值缓存、枚举/选项数组一致性、路由与外链常量。
 *
 * LocalUnit 下 PreferenceManager 未初始化（无 appContext），
 * getValueSync 恒返回 null——因此仅默认值 Map 内的键可离线读取，
 * 走 setPreference 的用例必须留给真机（会触发 preferences API）。
 */
export default function appPreferenceTest() {
  describe('appPreferenceTest', () => {
    it('enum_numeric_values_are_stable_contract', 0, () => {
      // 这些值会持久化到 preferences，变化等于用户设置错乱
      expect(SettingColorMode.System).assertEqual(0);
      expect(SettingColorMode.Dark).assertEqual(1);
      expect(SettingColorMode.Light).assertEqual(2);

      expect(SettingTokenSeparator.NONE).assertEqual(0);
      expect(SettingTokenSeparator.SPACE).assertEqual(1);
      expect(SettingTokenSeparator.DOT).assertEqual(2);

      expect(SettingHiddenTokenType.COMPACT).assertEqual(0);
      expect(SettingHiddenTokenType.STANDARD).assertEqual(1);

      expect(SettingTokenProgressType.LINEAR).assertEqual(0);
      expect(SettingTokenProgressType.RING).assertEqual(1);
      expect(SettingTokenProgressType.SCALE_RING).assertEqual(3);

      expect(SettingTopEffectType.DISABLE).assertEqual(0);
      expect(SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR).assertEqual(4);

      expect(SettingBottomTabsType.FLATTEN).assertEqual(0);
      expect(SettingBottomTabsType.SUSPENSION).assertEqual(1);

      expect(SettingImmersiveStyle.ULTRA_THIN).assertEqual(0);
      expect(SettingImmersiveStyle.THICK).assertEqual(3);
      expect(SettingImmersiveStyle.ULTRA_THICK).assertEqual(4);
    });

    it('get_preference_returns_defaults_from_cache', 0, () => {
      expect(AppPreference.getPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE) as boolean).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE) as boolean).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE) as boolean).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean).assertTrue();
      expect(AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.WANT_URI) as string).assertEqual('');
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string).assertEqual('0');
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_COLOR_MODE) as number)
        .assertEqual(SettingColorMode.System);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_IMMERSIVE_ENABLE) as boolean).assertTrue();
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_IMMERSIVE_STYLE) as number)
        .assertEqual(SettingImmersiveStyle.THICK);
    });

    it('appearance_defaults_match_design_baseline', 0, () => {
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_HEIGHT) as number).assertEqual(60);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_SPACE) as number).assertEqual(10);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_RADIUS) as number).assertEqual(16);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_MAX_WIDTH) as number).assertEqual(800);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_FONT_SIZE) as number).assertEqual(30);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_LONG_PRESS_DURATION) as number).assertEqual(300);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR) as number).assertEqual(0xFF254ff7);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR_DARK) as number).assertEqual(0xFF638FF6);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_SEPARATOR) as number)
        .assertEqual(SettingTokenSeparator.NONE);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_HIDDEN_TOKEN_TYPE) as number)
        .assertEqual(SettingHiddenTokenType.STANDARD);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_PROGRESS_TYPE) as number)
        .assertEqual(SettingTokenProgressType.LINEAR);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE) as number)
        .assertEqual(SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR);
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_BOTTOM_TABS_TYPE) as number)
        .assertEqual(SettingBottomTabsType.SUSPENSION);
    });

    it('option_arrays_cover_their_enums_exactly', 0, () => {
      expect(AVAILABLE_TOKEN_SEPARATORS.map(o => o.value).join(',')).assertEqual(
        [SettingTokenSeparator.NONE, SettingTokenSeparator.SPACE, SettingTokenSeparator.DOT].join(','));
      expect(AVAILABLE_HIDDEN_TOKEN_TYPES.map(o => o.value).join(',')).assertEqual(
        [SettingHiddenTokenType.COMPACT, SettingHiddenTokenType.STANDARD].join(','));
      expect(AVAILABLE_TOKEN_PROGRESS_TYPES.map(o => o.value).join(',')).assertEqual(
        [SettingTokenProgressType.LINEAR, SettingTokenProgressType.RING,
          SettingTokenProgressType.SCALE_RING].join(','));
      expect(AVAILABLE_BOTTOM_TABS_TYPES.map(o => o.value).join(',')).assertEqual(
        [SettingBottomTabsType.FLATTEN, SettingBottomTabsType.SUSPENSION].join(','));
      expect(AVAILABLE_IMMERSIVE_STYLES.map(o => o.value).join(',')).assertEqual(
        [SettingImmersiveStyle.ULTRA_THIN, SettingImmersiveStyle.THIN, SettingImmersiveStyle.REGULAR,
          SettingImmersiveStyle.THICK, SettingImmersiveStyle.ULTRA_THICK].join(','));
      // 顶部模糊当前只暴露 4 项（DISABLE 不进设置列表）
      expect(AVAILABLE_TOP_EFFECT_TYPES.map(o => o.value).join(',')).assertEqual(
        [SettingTopEffectType.COMMON_BLUR, SettingTopEffectType.GRADUAL_BLUR,
          SettingTopEffectType.GRADIENT_BLUR, SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR].join(','));
      // 每个选项必须带非空文案
      for (const option of AVAILABLE_TOKEN_SEPARATORS.concat(AVAILABLE_HIDDEN_TOKEN_TYPES)
        .concat(AVAILABLE_TOKEN_PROGRESS_TYPES).concat(AVAILABLE_TOP_EFFECT_TYPES)
        .concat(AVAILABLE_BOTTOM_TABS_TYPES).concat(AVAILABLE_IMMERSIVE_STYLES)) {
        expect(option.label !== undefined && option.label !== '').assertTrue();
      }
    });

    it('pref_keys_have_no_value_collisions', 0, () => {
      // 键名冲突会让两个设置共享同一存储槽
      const keys = [
        PREF_KEYS.DEBUG_MODE_ON, PREF_KEYS.SAFETY_LOCK_ENABLE, PREF_KEYS.SAFETY_PRIVACY_ENABLE,
        PREF_KEYS.APPEARANCE_COLOR_MODE, PREF_KEYS.APPEARANCE_ITEM_HEIGHT, PREF_KEYS.WANT_URI,
        PREF_KEYS.DB_RDS_SYNC_ENABLE, PREF_KEYS.CLOUD_SYNC_LAST_TIME, PREF_KEYS.SHOW_GUIDE_TIPS,
        PREF_KEYS.APPEARANCE_IMMERSIVE_ENABLE, PREF_KEYS.APPEARANCE_IMMERSIVE_STYLE,
        PREF_KEYS.MASTER_KEY_DEPRECATION_ACKNOWLEDGED, PREF_KEYS.ASSET_MIGRATION_DONE,
      ];
      const unique = new Set<string>(keys);
      expect(unique.size).assertEqual(keys.length);
      for (const key of keys) {
        expect(key.startsWith('app_')).assertTrue();
      }
    });

    it('event_names_are_unique_snake_actions', 0, () => {
      const names = [
        EVENT_NAMES.TOKEN_CHANGED, EVENT_NAMES.KV_STORE_SYNC_COMPLETE, EVENT_NAMES.FILE_DROP,
        EVENT_NAMES.ICON_PACK_CHANGED, EVENT_NAMES.OPEN_STEAM_CONFIRMATIONS,
        EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED, EVENT_NAMES.DEBUG_MODE_CHANGED,
      ];
      const unique = new Set<string>(names);
      expect(unique.size).assertEqual(names.length);
    });

    it('route_names_and_external_urls_are_well_formed', 0, () => {
      expect(ROUTE_NAMES.AppearancePage.length > 0).assertTrue();
      expect(ROUTE_NAMES.IndexPage).assertEqual('pages/Index');
      expect(ROUTE_NAMES.SettingBackup).assertEqual('setting/backup');
      expect(ROUTE_NAMES.AddSteamTokenPage).assertEqual('AddSteamTokenPage');

      expect(EXTERNAL_URLS.FEEDBACK_GITHUB.startsWith('https://github.com/OHOTP/')).assertTrue();
      expect(EXTERNAL_URLS.REPO_HOME.startsWith('https://')).assertTrue();
      expect(EXTERNAL_URLS.OSS_LIBCOTP.startsWith('https://')).assertTrue();
    });

    it('enabled_packs_default_to_builtin_without_migration', 0, () => {
      // LocalUnit 下未持久化过图标包键 → 默认仅内置包
      expect(AppPreference.loadEnabledPacks().join(',')).assertEqual(BUILTIN_DEFAULT_PACK_ID);
      expect(AppPreference.hasEnabledPacksMigrated()).assertFalse();
      expect(AppPreference.getLegacySelectedPack()).assertEqual(0);
    });

    it('unknown_key_without_default_reads_empty_in_localunit', 0, () => {
      // APPEARANCE_ICON_PACK_ENABLED 不在默认值 Map 中：
      // 生产走 preferences 读取；LocalUnit 下 PreferenceManager 未初始化，返回空串
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string).assertEqual('');
    });

    it('load_settings_pushes_defaults_into_token_preference_state', 0, async () => {
      // LocalUnit 无持久化偏好：loadSettings 等价于“全新安装”，
      // 默认值 Map 应原样流入 AppStorageV2 的 TokenPreference（UI 绑定源）。
      await AppPreference.loadSettings();

      const appearance = AppStorageV2.connect(TokenPreference, () => new TokenPreference())!;
      expect(appearance.app_appearance_item_height).assertEqual(60);
      expect(appearance.app_appearance_item_radius).assertEqual(16);
      expect(appearance.app_appearance_token_font_size).assertEqual(30);
      expect(appearance.app_appearance_issuer_font_size).assertEqual(18);
      expect(appearance.app_appearance_token_separator).assertEqual(SettingTokenSeparator.NONE);
      expect(appearance.app_appearance_hidden_token_type).assertEqual(SettingHiddenTokenType.STANDARD);
      expect(appearance.app_appearance_token_progress_type).assertEqual(SettingTokenProgressType.LINEAR);
      expect(appearance.app_appearance_token_color).assertEqual(0xFF254ff7);
      expect(appearance.app_appearance_chain_animation_enable).assertTrue();
      // 长按时长夹取到 [200, 1000]
      expect(appearance.app_appearance_long_press_duration).assertEqual(300);
    });
  });
}
