/**
 * 材质策略单例（API 26 沉浸光感基础设施）
 *
 * 统一判定当前设备/应用的材质能力档位，业务组件只依赖本类的判定结果，
 * 不直接散落调用 uiMaterial / hdsMaterial，保证 API 23~25 老设备与
 * 低算力设备的安全回退。
 *
 * 三级回退：
 * - immersive：API >= 26 且应用级材质未被全局禁用，使用原生 uiMaterial.ImmersiveMaterial
 * - hds：API >= 23 且设备支持 HDS 材质，使用 hdsMaterial 效果（不支持 IMMERSIVE 类型时降级 SMOOTH）
 * - solid：其余设备，使用实体背景
 *
 * 应用级开关：entry/src/main/module.json5 metadata "ohos.arkui.UIMaterial.state"，
 * 仅在 entry 模块生效，可通过 uiMaterial.getMaterialInfo() 读取。
 *
 * @module MaterialPolicy
 */

import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'MaterialPolicy';
const DOMAIN = 0xFF00;

/** 支持原生 ImmersiveMaterial 的最低 API 版本 */
const API_LEVEL_IMMERSIVE = 26;
/** 支持 HDS 材质的最低 API 版本 6.1.0(23) */
const API_LEVEL_HDS = 23;

/**
 * 材质能力档位
 * - immersive：原生沉浸式系统材质（API 26+）
 * - hds：HDS 材质（API 23+）
 * - solid：实体背景回退
 */
export type MaterialTier = 'immersive' | 'hds' | 'solid';

/**
 * 材质策略
 *
 * 使用示例：
 * ```ts
 * // 应用启动时初始化（EntryAbility.onCreate，紧随 DeviceInfoHelper 之后）
 * MaterialPolicy.getInstance().init();
 *
 * // 组件侧按档位渲染
 * if (MaterialPolicy.getInstance().isImmersive()) {
 *   // .systemMaterial(new uiMaterial.ImmersiveMaterial({...}))，背景必须透明
 * }
 * ```
 */
export class MaterialPolicy {
  /** 单例实例 */
  private static instance: MaterialPolicy | null = null;
  /** 当前材质档位 */
  private tier: MaterialTier = 'solid';
  /** 应用级材质状态（uiMaterial.MaterialState，未初始化或不支持时为 -1） */
  private appMaterialState: number = -1;
  /** HDS 材质等级（tier 为 hds 时有效） */
  private hdsLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  /** 设备是否支持 HDS IMMERSIVE 类型（用于 EXQUISITE/GENTLE 与 SMOOTH 的选择） */
  private hdsImmersiveSupported: boolean = false;
  /** 是否已初始化 */
  private initialized: boolean = false;

  private constructor() {
  }

  /**
   * 获取 MaterialPolicy 单例实例
   * @returns MaterialPolicy 实例
   */
  static getInstance(): MaterialPolicy {
    if (!MaterialPolicy.instance) {
      MaterialPolicy.instance = new MaterialPolicy();
    }
    return MaterialPolicy.instance;
  }

  /**
   * 初始化材质能力判定
   *
   * 在应用启动时调用一次。判定过程全部包裹在 canIUse + try/catch 中，
   * 保证 API 23~25 设备上引用 API 26 符号不会崩溃。
   */
  init(): void {
    if (this.initialized) {
      hilog.info(DOMAIN, TAG, 'init: already initialized');
      return;
    }
    const apiVersion: number = deviceInfo.distributionOSApiVersion || 0;
    hilog.info(DOMAIN, TAG, `init: distributionOSApiVersion=${apiVersion}`);

    // 第一档：原生沉浸式系统材质（API 26+）
    if (apiVersion >= API_LEVEL_IMMERSIVE && canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
      try {
        const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
        this.appMaterialState = info.state;
        if (info.state !== uiMaterial.MaterialState.DISABLE) {
          this.tier = 'immersive';
          this.initialized = true;
          hilog.info(DOMAIN, TAG, `init: tier=immersive, appMaterialState=${info.state}`);
          return;
        }
        hilog.info(DOMAIN, TAG, 'init: app-level material DISABLE, fall through to hds/solid');
      } catch (e) {
        hilog.error(DOMAIN, TAG, `init: uiMaterial check failed, error=${JSON.stringify(e)}`);
      }
    }

    // 第二档：HDS 材质（API 23+）
    if (apiVersion >= API_LEVEL_HDS && canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
      try {
        const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
        this.hdsImmersiveSupported = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
        // 不支持 IMMERSIVE 类型的设备使用 SMOOTH，降低卡顿和发热风险（官方建议）
        this.hdsLevel = this.hdsImmersiveSupported ?
          hdsMaterial.MaterialLevel.EXQUISITE : hdsMaterial.MaterialLevel.SMOOTH;
        this.tier = 'hds';
        this.initialized = true;
        hilog.info(DOMAIN, TAG, `init: tier=hds, immersiveSupported=${this.hdsImmersiveSupported}`);
        return;
      } catch (e) {
        hilog.error(DOMAIN, TAG, `init: hdsMaterial check failed, error=${JSON.stringify(e)}`);
      }
    }

    // 第三档：实体背景回退
    this.tier = 'solid';
    this.initialized = true;
    hilog.info(DOMAIN, TAG, 'init: tier=solid');
  }

  /**
   * 获取当前材质档位
   * @returns MaterialTier
   */
  getTier(): MaterialTier {
    return this.tier;
  }

  /**
   * 是否可使用原生 ImmersiveMaterial
   * @returns tier 为 immersive 时返回 true
   */
  isImmersive(): boolean {
    return this.tier === 'immersive';
  }

  /**
   * 获取应用级材质状态
   * @returns uiMaterial.MaterialState 值，不支持或未初始化时返回 -1
   */
  getAppMaterialState(): number {
    return this.appMaterialState;
  }

  /**
   * 获取 HDS 材质等级
   *
   * 用于 HdsNavigation / HdsTabs 等 systemMaterialEffect 的 materialLevel。
   * 设备不支持 IMMERSIVE 类型时为 SMOOTH（官方建议，降低卡顿发热风险）。
   *
   * @returns hdsMaterial.MaterialLevel
   */
  getHdsMaterialLevel(): hdsMaterial.MaterialLevel {
    return this.hdsLevel;
  }

  /**
   * 设备是否支持 HDS IMMERSIVE 材质类型
   * @returns 支持时返回 true
   */
  isHdsImmersiveSupported(): boolean {
    return this.hdsImmersiveSupported;
  }

  /**
   * HDS 组件 systemMaterialEffect 的自适应材质等级（Phase 5.8）
   *
   * 保留现有 ADAPTIVE 自适应行为，仅在设备不支持 HDS IMMERSIVE 类型时
   * 回退 SMOOTH（官方建议，降低卡顿发热风险）：
   * - tier 为 immersive（API 26 原生材质设备）：ADAPTIVE
   * - tier 为 hds 且设备支持 IMMERSIVE 类型：ADAPTIVE
   * - 其余（hds 不支持 IMMERSIVE 类型 / solid / 未初始化）：SMOOTH
   *
   * @returns hdsMaterial.MaterialLevel
   */
  getHdsAdaptiveMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.tier === 'immersive' || this.hdsImmersiveSupported) {
      return hdsMaterial.MaterialLevel.ADAPTIVE;
    }
    return hdsMaterial.MaterialLevel.SMOOTH;
  }

  /**
   * 检查是否已初始化
   * @returns 是否已初始化
   */
  isInitialized(): boolean {
    return this.initialized;
  }
}
