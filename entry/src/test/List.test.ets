import localUnitTest from './LocalUnit.test';
import smokeTest from './Smoke.test';
import base32Test from './Base32.test';

export default function testsuite() {
  localUnitTest();
  smokeTest();
  base32Test();
}