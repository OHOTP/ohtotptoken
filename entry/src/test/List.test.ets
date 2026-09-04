import localUnitTest from './LocalUnit.test';
import smokeTest from './Smoke.test';
import base32Test from './Base32.test';
import cardOTPUtilsTest from './CardOTPUtils.test';
import tokenUtilsExtraTest from './TokenUtilsExtra.test';
import steamUtilsTest from './SteamUtils.test';
import syncTimeHelperTest from './SyncTimeHelper.test';
import colorUtilsTest from './ColorUtils.test';
import commonUtilsTest from './CommonUtils.test';
import genericDataSourceTest from './GenericDataSource.test';
import otpAuthParserTest from './OtpAuthParser.test';
import twoFaBackupTest from './TwoFABackup.test';

export default function testsuite() {
  localUnitTest();
  smokeTest();
  base32Test();
  cardOTPUtilsTest();
  tokenUtilsExtraTest();
  steamUtilsTest();
  syncTimeHelperTest();
  colorUtilsTest();
  commonUtilsTest();
  genericDataSourceTest();
  otpAuthParserTest();
  twoFaBackupTest();
}