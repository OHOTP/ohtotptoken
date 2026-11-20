import { common } from '@kit.AbilityKit';
import { wearEngine } from '@kit.WearEngine';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BleTokenServer, WearEngineServer } from 'common';

const TAG: string = 'ReceiveChannels';

/**
 * 启动手表端令牌接收通道（Wear Engine P2P + BLE GATT Server）。
 *
 * **调用前提：ACCESS_BLUETOOTH 已授予。** 本方法自身不申请权限：
 * 审核要求权限必须由用户主动点击对应功能时申请，启动阶段不得弹窗，
 * 因此这里只负责「权限已具备后」把两条通道拉起来。
 *
 * 两条通道相互独立：任一失败只记日志，不影响另一条。
 */
export async function startReceiveChannels(context: common.UIAbilityContext): Promise<void> {
  // P2P：取已配对（已连接）手机，注册消息接收
  try {
    const deviceClient: wearEngine.DeviceClient = wearEngine.getDeviceClient(context);
    const connected: Array<wearEngine.Device> = await deviceClient.getConnectedDevices();
    const randomIds: Array<string> = connected.map((device: wearEngine.Device) => device.randomId);
    await WearEngineServer.getInstance().registerReceiver(randomIds);
  } catch (err) {
    hilog.error(0x0000, TAG, `start P2P receive failed: ${JSON.stringify(err)}`);
  }
  // BLE：启动 GATT Server 与广播（内部幂等，含重试）
  try {
    await BleTokenServer.getInstance().start();
  } catch (err) {
    hilog.error(0x0000, TAG, `start BLE receive failed: ${JSON.stringify(err)}`);
  }
}
