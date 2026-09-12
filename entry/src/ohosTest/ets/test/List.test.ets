import GoogleAuthUtilsTest from './GoogleAuthUtils.test'
import abilityTest from './Ability.test';
import tokenBatchTest from './TokenBatch.test';
import assetConcurrencyTest from './AssetConcurrency.test';
import tokenProgressDialogTest from './TokenProgressDialog.test';
import steamSecretStoreTest from './SteamSecretStore.test';
import backupRoundTripTest from './BackupRoundTrip.test';
import deviceMigrationTest from './DeviceMigration.test';
import bleTransferSmokeTest from './BleTransferSmoke.test';
import wearEngineSmokeTest from './WearEngineSmoke.test';

export default function testsuite() {
  abilityTest();
  GoogleAuthUtilsTest()
  tokenBatchTest();
  assetConcurrencyTest();
  tokenProgressDialogTest();
  steamSecretStoreTest();
  backupRoundTripTest();
  deviceMigrationTest();
  bleTransferSmokeTest();
  wearEngineSmokeTest();
}
