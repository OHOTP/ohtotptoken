/**
 * 设备信息帮助类
 * 
 * 提供设备信息的获取和缓存功能。
 * 根据华为开发者文档，deviceInfo 模块返回设备常量信息，
 * 建议应用只调用一次，不需要频繁调用。
 * 
 * 本类采用单例模式，在应用启动时调用 init() 方法初始化设备信息，
 * 然后将设备信息缓存到 AppStorage，后续通过 getter 方法获取。
 * 
 * @module DeviceInfoHelper
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'DeviceInfoHelper';
const DOMAIN = 0xFF00;

/**
 * 设备信息缓存键
 */
const DEVICE_INFO_KEY = 'cached_device_info';

/**
 * 设备信息接口
 */
export interface DeviceInfoData {
  /** 开发者匿名设备标识符（可作为设备唯一标识） */
  odid: string;
  /** 设备类型 */
  deviceType: string;
  /** 设备厂家名称 */
  manufacture: string;
  /** 设备品牌名称 */
  brand: string;
  /** 外部产品系列 */
  marketName: string;
  /** 产品系列 */
  productSeries: string;
  /** 认证型号 */
  productModel: string;
  /** 内部软件子型号 */
  softwareModel: string;
  /** 硬件版本号 */
  hardwareModel: string;
  /** 应用二进制接口 */
  abiList: string;
  /** 安全补丁级别 */
  securityPatchTag: string;
  /** 产品版本 */
  displayVersion: string;
  /** 系统发布类型 */
  osReleaseType: string;
  /** 系统版本 */
  osFullName: string;
  /** 发行版系统名称 */
  distributionOSName: string;
  /** 发行版系统版本号 */
  distributionOSVersion: string;
  /** 发行版系统API版本 */
  distributionOSApiVersion: number;
  /** 发行版系统类型 */
  distributionOSReleaseType: string;
}

/**
 * 设备信息帮助类
 * 
 * 使用示例：
 * ```ts
 * // 应用启动时初始化
 * await DeviceInfoHelper.getInstance().init();
 * 
 * // 获取设备信息
 * const deviceInfo = DeviceInfoHelper.getInstance().getDeviceInfo();
 * console.log('Device ODID:', deviceInfo.odid);
 * console.log('Device Name:', deviceInfo.marketName);
 * ```
 */
export class DeviceInfoHelper {
  /** 单例实例 */
  private static instance: DeviceInfoHelper | null = null;
  /** 设备信息缓存 */
  private cachedDeviceInfo: DeviceInfoData | null = null;
  /** 是否已初始化 */
  private initialized: boolean = false;

  private constructor() {
  }

  /**
   * 获取 DeviceInfoHelper 单例实例
   * @returns DeviceInfoHelper 实例
   */
  static getInstance(): DeviceInfoHelper {
    if (!DeviceInfoHelper.instance) {
      DeviceInfoHelper.instance = new DeviceInfoHelper();
    }
    return DeviceInfoHelper.instance;
  }

  /**
   * 初始化设备信息
   * 
   * 从 deviceInfo 模块获取设备信息并缓存到 AppStorage。
   * 根据华为开发者文档，此方法应在应用启动时调用一次。
   * 
   * @returns Promise<void>
   */
  async init(): Promise<void> {
    if (this.initialized) {
      hilog.info(DOMAIN, TAG, 'init: already initialized');
      return;
    }

    try {
      hilog.info(DOMAIN, TAG, 'init: collecting device info');

      const deviceInfoData: DeviceInfoData = {
        odid: deviceInfo.ODID || 'unknown_odid',
        deviceType: deviceInfo.deviceType || 'unknown',
        manufacture: deviceInfo.manufacture || 'unknown',
        brand: deviceInfo.brand || 'unknown',
        marketName: deviceInfo.marketName || 'Unknown Device',
        productSeries: deviceInfo.productSeries || 'unknown',
        productModel: deviceInfo.productModel || 'unknown',
        softwareModel: deviceInfo.softwareModel || 'unknown',
        hardwareModel: deviceInfo.hardwareModel || 'unknown',
        abiList: deviceInfo.abiList || 'unknown',
        securityPatchTag: deviceInfo.securityPatchTag || 'unknown',
        displayVersion: deviceInfo.displayVersion || 'unknown',
        osReleaseType: deviceInfo.osReleaseType || 'unknown',
        osFullName: deviceInfo.osFullName || 'unknown',
        distributionOSName: deviceInfo.distributionOSName || 'unknown',
        distributionOSVersion: deviceInfo.distributionOSVersion || 'unknown',
        distributionOSApiVersion: deviceInfo.distributionOSApiVersion || 0,
        distributionOSReleaseType: deviceInfo.distributionOSReleaseType || 'unknown',
      };

      this.cachedDeviceInfo = deviceInfoData;
      this.initialized = true;

      // 缓存到 AppStorage
      AppStorage.setOrCreate(DEVICE_INFO_KEY, deviceInfoData);

      hilog.info(DOMAIN, TAG, `init: completed, ODID=${deviceInfoData.odid}, marketName=${deviceInfoData.marketName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init: error=${JSON.stringify(e)}`);
    }
  }

  /**
   * 获取设备信息
   * 
   * @returns 设备信息对象，如果未初始化则返回默认值
   */
  getDeviceInfo(): DeviceInfoData {
    if (this.cachedDeviceInfo) {
      return this.cachedDeviceInfo;
    }

    // 尝试从 AppStorage 获取
    const appStorageInfo = AppStorage.get<DeviceInfoData>(DEVICE_INFO_KEY);
    if (appStorageInfo) {
      this.cachedDeviceInfo = appStorageInfo;
      return appStorageInfo;
    }

    // 返回默认值
    hilog.warn(DOMAIN, TAG, 'getDeviceInfo: not initialized, returning default values');
    return {
      odid: 'unknown_odid',
      deviceType: 'unknown',
      manufacture: 'unknown',
      brand: 'unknown',
      marketName: 'Unknown Device',
      productSeries: 'unknown',
      productModel: 'unknown',
      softwareModel: 'unknown',
      hardwareModel: 'unknown',
      abiList: 'unknown',
      securityPatchTag: 'unknown',
      displayVersion: 'unknown',
      osReleaseType: 'unknown',
      osFullName: 'unknown',
      distributionOSName: 'unknown',
      distributionOSVersion: 'unknown',
      distributionOSApiVersion: 0,
      distributionOSReleaseType: 'unknown',
    };
  }

  /**
   * 获取设备唯一标识符
   * 
   * 使用 ODID 作为设备唯一标识，无需权限。
   * 
   * @returns 设备唯一标识符
   */
  getDeviceId(): string {
    return this.getDeviceInfo().odid;
  }

  /**
   * 获取设备名称
   * 
   * 使用 marketName 作为设备名称。
   * 
   * @returns 设备名称
   */
  getDeviceName(): string {
    return this.getDeviceInfo().marketName;
  }

  /**
   * 当前设备是否为 PC/2in1。
   */
  isPc(): boolean {
    return this.getDeviceInfo().deviceType === deviceInfo.DeviceTypes.TYPE_2IN1;
  }

  /**
   * 当前设备是否为 PC/2in1 或平板。
   */
  isPcOrTablet(): boolean {
    const deviceType = this.getDeviceInfo().deviceType;
    return deviceType === deviceInfo.DeviceTypes.TYPE_2IN1 ||
      deviceType === deviceInfo.DeviceTypes.TYPE_TABLET;
  }

  /**
   * 检查是否已初始化
   * 
   * @returns 是否已初始化
   */
  isInitialized(): boolean {
    return this.initialized;
  }
}
