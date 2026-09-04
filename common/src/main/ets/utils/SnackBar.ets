import { dialogSystemMaterial } from './MaterialStyleBridge';
import { AppStorageV2 } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppWindowInfo } from '../models/AppWindowInfo';

export enum SnackBarNotifyType {
  INFO = 'INFO',
  WARNING = 'WARNING',
  ERROR = 'ERROR',
  SUCCESS = 'SUCCESS'
}

export interface SnackBarNotifyOptions {
  title?: ResourceStr;
  duration?: number;
}

export type ShowSnackBarImpl = (
  message: ResourceStr,
  type: SnackBarNotifyType,
  options: SnackBarNotifyOptions
) => void;

/**
 * 默认实现: 系统 toast 兜底。
 * 手表(wearable)等无 com.huawei.hmos.hdscomponent 系统 HSP 的环境不能加载
 * @kit.UIDesignKit, 手机端 HdsSnackBar 实现由 entry 在启动时通过
 * setSnackBarImpl() 注入替换。
 */
let impl: ShowSnackBarImpl = (message: ResourceStr, _type: SnackBarNotifyType, options: SnackBarNotifyOptions) => {
  try {
    const windowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
    windowInfo.uiContext?.getPromptAction().showToast({
      systemMaterial: dialogSystemMaterial(),
      message,
      duration: options.duration ?? 2000
    });
  } catch (e) {
    hilog.error(0, 'SnackBar', `fallback toast failed: ${e}`);
  }
};

export function setSnackBarImpl(fn: ShowSnackBarImpl): void {
  impl = fn;
}

export function showSnackBar(
  message: ResourceStr,
  type: SnackBarNotifyType = SnackBarNotifyType.INFO,
  options: SnackBarNotifyOptions = {}
): void {
  impl(message, type, options);
}
