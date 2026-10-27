import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import test from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const load = path => readFileSync(join(root, path), 'utf8');
function sources(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(item => {
    const path = join(dir, item.name);
    return item.isDirectory() ? sources(path) : path.endsWith('.ets') ? [path] : [];
  });
}

test('input dialogs use bottom alignment; confirmation, selection and display dialogs use center', () => {
  let inputCount = 0;
  let displayCount = 0;
  for (const dir of ['entry/src/main/ets', 'common/src/main/ets', 'uikit/src/main/ets']) {
    for (const path of sources(join(root, dir))) {
      const text = readFileSync(path, 'utf8');
      assert.doesNotMatch(text, /DialogAlignment\.(?:Top|Default)\b/, path);
      assert.doesNotMatch(text, /showActionMenu\(/, `${path}: choice dialogs must support centered alignment`);
      for (const match of text.matchAll(/(?:showAlertDialog|AlertDialog\.show|openCustomDialog|CustomDialogController)\(\{/g)) {
        const start = match.index + match[0].length;
        let depth = 1;
        let end = start;
        for (; end < text.length && depth; end++) {
          if (text[end] === '{') depth++;
          if (text[end] === '}') depth--;
        }
        const options = text.slice(start, end);
        const input = /(?:NameDialogBuilder|NewGroupDialogBuilder|EncryptionPasswordDialogBuilder|PasswordBuilder|ColorSelectDialog|DropFilesDialog)\(/.test(options);
        if (input) inputCount++; else displayCount++;
        assert.match(options, input ? /alignment:\s*DialogAlignment.Bottom\b/ : /alignment:\s*DialogAlignment.Center\b/, `${path}:${match.index}`);
        if (!input) assert.doesNotMatch(options, /offset:\s*\{/, path);
      }
    }
  }
  assert.ok(inputCount >= 5);
  assert.ok(displayCount >= 20);
});

test('password presentation keeps keyboard scrolling without a visible scrollbar', () => {
  const text = load('entry/src/main/ets/dialogs/EncryptionPassWordDialog.ets');
  assert.match(text, /Scroll\(\)/);
  assert.match(text, /maxHeight: this.contentLimit.*scrollBar\(BarState.Off\)/);
  assert.match(text, /main.on\('keyboardHeightChange', this.keyboardChanged\)/);
  assert.match(text, /off\('keyboardHeightChange', this.keyboardChanged\)/);
  assert.match(text, /onEditChange/);
  assert.match(text, /windowHeight \* 0.28/);
  const buttons = text.slice(text.indexOf('Row() {'), text.indexOf(".width('100%')", text.indexOf('Row() {')));
  assert.ok(buttons.indexOf('local-backup-password-cancel') < buttons.indexOf('local-backup-password-submit'));
  assert.equal((buttons.match(/layoutWeight\(1\)/g) ?? []).length, 2);
  assert.equal((buttons.match(/backgroundColor\(Color.Transparent\)/g) ?? []).length, 2);
  assert.match(buttons, /Divider\(\)/);
  assert.match(buttons, /enabled\(!this.busy\).onClick\(\(\) => this.submitPassword\(\)\)/);
  assert.match(text, /if \(this.busy \|\| !this.isActive\(\)\)/);
  assert.match(text, /this.textValue !== this.confirmTextValue/);
  assert.match(text, /await this.submit\(password\)/);
  assert.match(text, /if \(!this.mounted \|\| !this.isActive\(\)\)/);
  const page = load('entry/src/main/ets/pages/setting/BackupAndMigrationSheet.ets');
  assert.match(page, /keyboardAvoidMode: KeyboardAvoidMode.DEFAULT/);
  assert.match(page, /alignment: DialogAlignment.Bottom,\s*offset: \{ dx: 0, dy: -Math.max\(20, this.window.AvoidBottomHeight\) \}/);
});

test('global menu and context-menu popup layers explicitly receive material without enabling content controls', () => {
  const index = load('entry/src/main/ets/pages/Index.ets');
  assert.match(index, /openMenu\(contentNode, \{ id: this.sortTokenMenuTargetId \}, \{\s*systemMaterial: dialogSystemMaterial\(\)/);
  assert.match(load('entry/src/main/ets/components/TokenItem.ets'), /bindContextMenuWithResponse\(this.TokenRightCtxMenu, \{\s*systemMaterial: MaterialTheme.systemMaterial\(\)/);
  assert.match(load('entry/src/main/ets/components/TokenGroupSidePanel.ets'), /bindContextMenu\([^\n]+ResponseType.LongPress, \{\s*systemMaterial: dialogSystemMaterial\(\)/);
  assert.match(load('entry/src/main/module.json5'), /"name": "ohos.arkui.UIMaterial.state",\s*"value": "default"/);
});

function exportFixture({ active = true, begin = true, failOpen = false } = {}) {
  const source = load('entry/src/main/ets/pages/setting/BackupAndMigrationSheet.ets');
  const method = source.slice(source.indexOf('  async callFilePickerSaveFile()'), source.indexOf('  async callFilePickerSaveMigrationFile()'));
  const Fixture = runInNewContext(stripTypeScriptTypes(`class Fixture { ${method} }\nFixture`, { mode: 'transform' }), {
    $r: value => value, dialogSystemMaterial: () => 'material',
    DialogAlignment: { Center: 'center' }, DialogButtonDirection: { VERTICAL: 'vertical' },
    LocalBackupStage: { CHOOSING: 'choosing' }
  });
  const host = new Fixture();
  const calls = [];
  let options;
  host.flow = { stage: 'choosing', isCurrent: generation => active && generation === 1 };
  host.beginExport = () => begin ? 1 : undefined;
  host.getUIContext = () => ({ showAlertDialog(value) { if (failOpen) throw new Error('SYNTHETIC_PRIVATE'); options = value; } });
  host.cancel = generation => { calls.push(['cancel', generation]); active = false; };
  host.fail = (generation, message) => calls.push(['fail', generation, message]);
  host.openPassword = (...args) => calls.push(['password', ...args]);
  host.confirmStep = (...args) => calls.push(['confirm', ...args]);
  host.prepareExport = (...args) => calls.push(['prepare', ...args]);
  return { host, calls, get options() { return options; }, invalidate() { active = false; } };
}

test('export choice uses centered system-colored buttons and waits for dismissal before password', async () => {
  const f = exportFixture();
  await f.host.callFilePickerSaveFile();
  assert.equal(f.options.alignment, 'center');
  assert.equal(f.options.systemMaterial, 'material');
  assert.equal(f.options.buttons.length, 3);
  for (const button of f.options.buttons) {
    assert.equal(button.fontColor, undefined);
    assert.equal(button.color, undefined);
  }
  f.options.buttons[0].action();
  assert.deepEqual(f.calls, []);
  f.options.onDidDisappear();
  assert.deepEqual(f.calls, [['password', 1, true]]);
});

test('plain export retains the warning and explicit confirmation before preparing data', async () => {
  const f = exportFixture();
  await f.host.callFilePickerSaveFile();
  f.options.buttons[1].action();
  f.options.onDidDisappear();
  assert.equal(f.calls[0][0], 'confirm');
  assert.equal(f.calls[0][3], 'app.string.local_backup_plain_warning');
  assert.equal(f.calls[0][5], true);
  assert.equal(f.calls.length, 1);
  f.calls[0][6]();
  assert.deepEqual(f.calls[1], ['prepare', 1, false]);
});

for (const kind of ['cancel-button', 'outside', 'invalidated', 'stage-changed']) {
  test(`export choice never continues after ${kind}`, async () => {
    const f = exportFixture();
    await f.host.callFilePickerSaveFile();
    f.options.buttons[0].action();
    if (kind === 'cancel-button') f.options.buttons[2].action();
    if (kind === 'outside') f.options.cancel();
    if (kind === 'invalidated') f.invalidate();
    if (kind === 'stage-changed') f.host.flow.stage = 'preparing';
    f.options.onDidDisappear();
    assert.ok(f.calls.every(call => call[0] === 'cancel'));
  });
}

test('cloud cleanup choice stays guarded until dismissal and still requires a second confirmation', () => {
  const source = load('entry/src/main/ets/pages/ShowCloudSyncDetailsPage.ets');
  const method = source.slice(source.indexOf('  private showClearCloudStorageDialog()'), source.indexOf('  private showClearConfirmDialog('));
  const Fixture = runInNewContext(stripTypeScriptTypes(`class Fixture { ${method} }\nFixture`, { mode: 'transform' }), {
    $r: value => value, dialogSystemMaterial: () => 'material',
    DialogAlignment: { Center: 'center' }, DialogButtonDirection: { VERTICAL: 'vertical' },
    ClearCloudType: { DEVICE: 0, DEVICE_NAME: 1, ALL: 2 }
  });
  for (const selection of [undefined, 0, 1, 2]) {
    for (const mounted of [true, false]) {
      const host = new Fixture();
      let options;
      const confirms = [];
      host.canStartAction = () => true;
      host.isMounted = mounted;
      host.getUIContext = () => ({ showAlertDialog(value) { options = value; } });
      host.showClearConfirmDialog = value => confirms.push(value);
      host.showClearCloudStorageDialog();
      assert.equal(host.confirmationOpen, true);
      assert.equal(options.alignment, 'center');
      if (selection !== undefined) options.buttons[selection].action();
      assert.deepEqual(confirms, []);
      options.onDidDisappear();
      assert.equal(host.confirmationOpen, false);
      assert.deepEqual(confirms, mounted && selection !== undefined ? [selection] : []);
    }
  }
});

test('unavailable export opens no dialog; dialog-open failure reports a fixed safe error', async () => {
  const blocked = exportFixture({ begin: false });
  await blocked.host.callFilePickerSaveFile();
  assert.equal(blocked.options, undefined);
  const failed = exportFixture({ failOpen: true });
  await failed.host.callFilePickerSaveFile();
  assert.deepEqual(failed.calls, [['fail', 1, 'app.string.local_backup_prepare_failed']]);
});
