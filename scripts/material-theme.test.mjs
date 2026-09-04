import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';

// Exercise the production helper with SDK mocks; visual effects still require a device.
const source = readFileSync(new URL('../entry/src/main/ets/components/MaterialTheme.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '')
  .replace('export class MaterialTheme', 'class MaterialTheme');
const code = stripTypeScriptTypes(source) + '\nMaterialTheme;';
const styles = { ULTRA_THIN: 0, THIN: 1, REGULAR: 2, THICK: 3, ULTRA_THICK: 4 };

function fixture(api = 26) {
  const preference = { app_appearance_immersive_enable: true, app_appearance_immersive_style: 2 };
  const empty = {};
  const sdk = {
    Material: { empty },
    ImmersiveStyle: styles,
    ImmersiveMaterial: class { constructor(options) { this.options = options; } }
  };
  const theme = runInNewContext(code, {
    MaterialPreference: class {},
    SettingImmersiveStyle: styles,
    AppStorageV2: { connect: () => preference },
    deviceInfo: { sdkApiVersion: api },
    // Regression: a startup HDS fallback must not veto API 26 native material.
    MaterialPolicy: { getInstance: () => ({ getTier: () => 'hds', isImmersive: () => false }) },
    hdsMaterial: { MaterialType: { IMMERSIVE: 2, NONE: 0 } },
    Color: { Transparent: 'transparent', White: 'white' },
    get uiMaterial() {
      assert.ok(api >= 26, 'must not access API 26 material symbols on older devices');
      return sdk;
    }
  });
  return { theme, preference, empty };
}

test('API 26 native material ignores cached startup fallback', () => {
  const { theme } = fixture();
  assert.equal(theme.supportsNativeMaterial(), true);
  assert.equal(theme.isImmersiveEffective(), true);
  assert.equal(theme.systemMaterial().options.style, styles.REGULAR);
  assert.equal(theme.surfaceBackground('solid'), 'transparent');
});

test('all five thicknesses follow the current preference', () => {
  const { theme, preference } = fixture();
  for (const value of Object.values(styles)) {
    preference.app_appearance_immersive_style = value;
    assert.equal(theme.systemMaterial().options.style, value);
  }
});

test('disable uses empty, then re-enable restores selected thickness', () => {
  const { theme, preference, empty } = fixture();
  preference.app_appearance_immersive_style = styles.THIN;
  preference.app_appearance_immersive_enable = false;
  assert.equal(theme.systemMaterial(), empty);
  assert.equal(theme.dialogSystemMaterial(), empty);
  assert.equal(theme.surfaceBackground('solid'), 'solid');
  assert.equal(theme.hdsMaterialType(), 0);
  preference.app_appearance_immersive_enable = true;
  assert.equal(theme.systemMaterial().options.style, styles.THIN);
  assert.equal(theme.hdsMaterialType(), 2);
});

test('API 23–25 returns undefined without touching native material symbols', () => {
  for (const api of [23, 24, 25]) {
    const { theme } = fixture(api);
    assert.equal(theme.supportsNativeMaterial(), false);
    assert.equal(theme.systemMaterial(), undefined);
    assert.equal(theme.surfaceBackground('solid'), 'solid');
  }
});

test('interactive search material retains light feedback', () => {
  const { theme } = fixture();
  assert.equal(theme.systemMaterial(true).options.interactive, true);
  assert.equal(theme.systemMaterial(true).options.lightEffect.color, 'white');
  assert.equal(theme.systemMaterial().options.lightEffect, undefined);
});
