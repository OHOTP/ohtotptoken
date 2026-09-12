import { PreferenceManager } from "./PreferenceManager";
import { TokenConfig, otpType } from "./TokenConfig";
import { TokenStore } from "./TokenStore";
import { generateOTP } from "./TokenUtils";
import { AppPreference, PREF_KEYS } from "./AppPreference";
import { KeyValueStore } from "./StoragePorts";
import { systemDateTime } from "@kit.BasicServicesKit";

export interface CardConfig {
  formId: string;
  formName: string;
  tokenUUIDs: string[];
}

const CARD_CONFIG_PREFIX = "card_config_";
const CARD_CONFIGS_KEY = "card_configs_list";

/**
 * 空卡片数据（无令牌时的绑定数据）。
 *
 * entry 的 EntryFormAbility 与 TokenCardStore 内部都使用，导出避免两处各写一份。
 */
export function emptyCardData(formId: string, formName: string): Record<string, Object> {
  const data: Record<string, Object> = {
    'hasToken': 'false',
    'formId': formId,
    'formName': formName,
  };
  for (let i = 0; i < 2; i++) {
    data[`token${i}_issuer`] = '';
    data[`token${i}_name`] = '';
    data[`token${i}_secret`] = '';
    data[`token${i}_algorithm`] = '';
    data[`token${i}_digits`] = '';
    data[`token${i}_period`] = '';
    data[`token${i}_type`] = '';
    data[`token${i}_counter`] = '';
  }
  return data;
}

export class TokenCardStore {
  private static instance: TokenCardStore;
  // 卡片配置的 KV 端口：生产 PreferenceManager（preferences），测试注入内存实现。
  private prefStore: KeyValueStore = PreferenceManager.getInstance();

  private constructor() {}

  public static getInstance(): TokenCardStore {
    if (!TokenCardStore.instance) {
      TokenCardStore.instance = new TokenCardStore();
    }
    return TokenCardStore.instance;
  }

  /** 测试注入：LocalUnit 下 preferences 不可用，替换为内存 KV。 */
  useStoreForTest(store: KeyValueStore): void {
    this.prefStore = store;
  }

  async saveCardConfig(config: CardConfig): Promise<void> {
    await this.prefStore.setValue<string>(`${CARD_CONFIG_PREFIX}${config.formId}`, JSON.stringify(config));
    const configs = await this.prefStore.getValue<string[]>(CARD_CONFIGS_KEY) ?? [];
    if (!configs.includes(config.formId)) {
      configs.push(config.formId);
      await this.prefStore.setValue<string[]>(CARD_CONFIGS_KEY, configs);
    }
  }

  async getCardConfig(formId: string): Promise<CardConfig | null> {
    const raw = await this.prefStore.getValue<string>(`${CARD_CONFIG_PREFIX}${formId}`);
    if (raw) {
      return JSON.parse(raw) as CardConfig;
    }
    return null;
  }

  async removeCardConfig(formId: string): Promise<void> {
    await this.prefStore.deleteValue(`${CARD_CONFIG_PREFIX}${formId}`);
    const configs = await this.prefStore.getValue<string[]>(CARD_CONFIGS_KEY) ?? [];
    const idx = configs.indexOf(formId);
    if (idx >= 0) {
      configs.splice(idx, 1);
      await this.prefStore.setValue<string[]>(CARD_CONFIGS_KEY, configs);
    }
  }

  async getCardConfigList(): Promise<string[]> {
    const configs = await this.prefStore.getValue<string[]>(CARD_CONFIGS_KEY);
    return configs ?? [];
  }

  async incrementTokenCounter(tokenUUID: string): Promise<number> {
    const tkStore = TokenStore.getInstance();
    await tkStore.LoadTokenByDataBase();
    const allTokens = await tkStore.getTokens();
    const token = allTokens.find(t => t.TokenUUID === tokenUUID);
    if (token) {
      token.TokenCounter++;
      await tkStore.updateToken(token);
      return token.TokenCounter;
    }
    return -1;
  }

  async generateCardData(formId: string, config?: CardConfig): Promise<Record<string, Object>> {
    if (!config) {
      config = await this.getCardConfig(formId) ?? undefined;
    }
    if (!config || config.tokenUUIDs.length === 0) {
      return emptyCardData(formId, config?.formName ?? '');
    }

    const tkStore = TokenStore.getInstance();
    await tkStore.LoadTokenByDataBase();
    const allTokens = await tkStore.getTokens();

    const formData = emptyCardData(formId, config.formName);

    let hasAnyToken = false;
    for (let i = 0; i < Math.min(config.tokenUUIDs.length, 2); i++) {
      const token = allTokens.find(t => t.TokenUUID === config!.tokenUUIDs[i]);
      if (token) {
        hasAnyToken = true;
        formData[`token${i}_issuer`] = token.TokenIssuer;
        formData[`token${i}_name`] = token.TokenName;
        formData[`token${i}_secret`] = token.TokenSecret;
        formData[`token${i}_algorithm`] = token.TokenAlgorithm;
        formData[`token${i}_digits`] = String(token.TokenDigits);
        formData[`token${i}_period`] = String(token.TokenPeriod);
        formData[`token${i}_type`] = String(token.TokenType ?? otpType.TOTP);
        formData[`token${i}_counter`] = String(token.TokenCounter ?? 0);
        // 即将过期阈值(用户设置): 卡片进度条剩余时间低于该值变红
        const nextMargin = AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN);
        formData[`token${i}_next_margin`] = String(typeof nextMargin === 'number' ? nextMargin : 5);
      }
    }

    formData['hasToken'] = hasAnyToken ? 'true' : 'false';
    return formData;
  }
}
