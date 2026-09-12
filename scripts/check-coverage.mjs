#!/usr/bin/env node
/**
 * 逻辑层覆盖率门禁（Phase 1 起，见 docs/TEST_PLAN.md 第 5 节）。
 *
 * 用法（LocalUnit 测试跑完后执行）：
 *   hvigorw test -p module=entry@default --no-daemon
 *   node scripts/check-coverage.mjs
 *
 * 口径（与 TEST_PLAN 三分法一致）：
 * - 逻辑层 = common 全部 + entry 的 crypto/steam/oath/utils
 * - 剔除真机 only 责任区（asset/ble/wearEngine/distributedKVStore/NFC/RDB 等
 *   文件级剔除，归 ohosTest）与 UI 胶水（HdsSnackBarUtils）
 *
 * 四道检查：
 * 1. 行/分支覆盖不得低于 baseline（0.1pp 容差）；
 * 2. coverageReport.json 不得遗漏口径内文件（分母逃逸：测试导入图树裁掉后
 *    报告里没有的文件对覆盖率完全不可见）——豁免清单冻结在 baseline 的
 *    expectedAbsentFromReport，只允许缩小不允许增长；
 * 3. 磁盘口径内文件数不得少于 baseline.fileCount（防止删文件静默缩分母；
 *    有意删除/新增文件后请重新生成 baseline 并随代码提交）；
 * 4. baseline 自身的可诊断性：报告或基线缺失时给出可操作的报错。
 */
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const path = require('node:path');

const REPORT = path.resolve('entry/.test/default/outputs/test/reports/coverageReport.json');
const BASELINE = path.resolve('scripts/coverage-baseline.json');
const PCT_EPSILON = 0.1;

const LOGIC_ROOTS = [
  'common/src/main/ets',
  'entry/src/main/ets/crypto',
  'entry/src/main/ets/steam',
  'entry/src/main/ets/oath',
  'entry/src/main/ets/utils',
];

// 真机 only 责任区（docs/TEST_PLAN.md 第 2 节）+ UI 胶水，按文件名剔除。
// Phase 2 起 SteamSecretStore 已解耦（NamedSecretStore 端口注入），逻辑可测，移出本清单。
const DEVICE_ONLY_OR_UI = [
  'PermissionManager', 'DlpAntiPeepManager', 'PhotoPickerUtils', 'IconThumbnailTask',
  'RdbManager', 'HuaweiAccountManager', 'BleTokenTransfer', 'WearEngineTransfer',
  'KvManager', 'AssetSecretStore',
  'NfcOathReader', 'NfcTagTransport', 'NetworkHttpTransport', 'TokenSwitchPerf',
  'EntryAbility', 'HdsSnackBarUtils',
];

export function isLogicLayerFile(reportPath) {
  const normalized = reportPath.replace(/\\/g, '/');
  return LOGIC_ROOTS.some(p => normalized.includes(p))
    && !DEVICE_ONLY_OR_UI.some(p => normalized.includes(p));
}

function listLogicFilesOnDisk() {
  const out = [];
  for (const root of LOGIC_ROOTS) {
    walk(path.resolve(root), out);
  }
  return out
    .map(p => p.replace(/\\/g, '/'))
    .filter(p => !DEVICE_ONLY_OR_UI.some(x => p.includes(x)));
}

function walk(dir, acc) {
  if (!existsSync(dir)) {
    return acc;
  }
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, acc);
    } else if (entry.name.endsWith('.ets')) {
      acc.push(full);
    }
  }
  return acc;
}

export function summarize(report, filter = isLogicLayerFile) {
  const files = report.files.filter(f => filter(f.path));
  const sum = (kind) => files.reduce((acc, f) => {
    const s = f.summary[kind] ?? { covered: 0, total: 0 };
    acc.covered += s.covered;
    acc.total += s.total;
    return acc;
  }, { covered: 0, total: 0 });
  const pct = (x) => x.total === 0 ? 100 : (100 * x.covered) / x.total;
  return {
    fileCount: files.length,
    lines: sum('lines'),
    branches: sum('branches'),
    pctOf: pct,
    reportedPaths: files.map(f => f.path.replace(/\\/g, '/')),
    worstFiles: files
      .map(f => ({ name: path.basename(f.path), ...f.summary.lines }))
      .sort((a, b) => (a.covered / (a.total || 1)) - (b.covered / (b.total || 1)))
      .slice(0, 8),
  };
}

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function readJsonOrDie(file, hint) {
  if (!existsSync(file)) {
    fail(`${path.relative(process.cwd(), file)} 不存在。${hint}`);
  }
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`${path.relative(process.cwd(), file)} 不是合法 JSON：${e.message}`);
  }
}

const report = readJsonOrDie(REPORT, '请先运行 hvigorw test -p module=entry@default --no-daemon 生成覆盖率报告。');
const baseline = readJsonOrDie(BASELINE, '仓库被损坏或不完整，scripts/coverage-baseline.json 必须随仓库存在。');
const current = summarize(report);
const diskLogicFiles = listLogicFilesOnDisk();

console.log(`逻辑层可测基数（${current.fileCount} 个文件在报告中 / ${diskLogicFiles.length} 个在磁盘上，口径冻结于本脚本）:`);
console.log(`  行覆盖:   ${current.lines.covered}/${current.lines.total} = ${(current.pctOf(current.lines)).toFixed(2)}%（基线 ${baseline.lines.pct}%）`);
console.log(`  分支覆盖: ${current.branches.covered}/${current.branches.total} = ${(current.pctOf(current.branches)).toFixed(2)}%（基线 ${baseline.branches.pct}%）`);
console.log('  覆盖最差文件:');
for (const f of current.worstFiles) {
  console.log(`    ${f.name.padEnd(32)} ${f.covered}/${f.total}`);
}

let failed = false;
const linePct = current.pctOf(current.lines);
const branchPct = current.pctOf(current.branches);
if (linePct < baseline.lines.pct - PCT_EPSILON) {
  fail(`逻辑层行覆盖 ${(linePct).toFixed(2)}% 低于基线 ${baseline.lines.pct}%（容差 ${PCT_EPSILON}pp）。` +
    '新增/修改的逻辑代码必须带 LocalUnit 用例；有意重排口径需更新 coverage-baseline.json 并说明。');
  failed = true;
}
if (branchPct < baseline.branches.pct - PCT_EPSILON) {
  fail(`逻辑层分支覆盖 ${(branchPct).toFixed(2)}% 低于基线 ${baseline.branches.pct}%。`);
  failed = true;
}

// 检查 2：分母逃逸——报告里必须能找到磁盘上的每个口径内文件（豁免清单除外）。
const allowlist = baseline.expectedAbsentFromReport ?? [];
const missing = diskLogicFiles.filter(p => !current.reportedPaths.some(rp => rp.endsWith(p)));
const unexpectedMissing = missing.filter(p => !allowlist.some(a => p.endsWith(a)));
if (unexpectedMissing.length > 0) {
  fail(`以下口径内文件未出现在 coverageReport.json（未被任何测试加载，覆盖率完全不可见）：\n` +
    unexpectedMissing.map(p => `  - ${path.relative(process.cwd(), p)}`).join('\n') +
    `\n为新增文件补 LocalUnit 用例（哪怕只是导入触达），或将其移入 DEVICE_ONLY_OR_UI 剔除清单并说明理由。`);
  failed = true;
}
const staleAllowlist = allowlist.filter(a => !missing.some(p => p.endsWith(a)));
if (staleAllowlist.length > 0) {
  console.log(`  ℹ 豁免清单中 ${staleAllowlist.length} 个文件已进入报告，请从 coverage-baseline.json 的 expectedAbsentFromReport 移除：`);
  for (const s of staleAllowlist) {
    console.log(`    - ${s}`);
  }
}

// 检查 3：磁盘口径内文件数不得少于基线（删文件静默缩分母）。
if (diskLogicFiles.length < baseline.fileCount) {
  fail(`口径内文件数 ${diskLogicFiles.length} 少于基线 ${baseline.fileCount}。` +
    '删除逻辑文件会静默缩小覆盖率分母；若属有意重构，请重新生成 scripts/coverage-baseline.json 并随代码提交。');
  failed = true;
}

console.log('  ⚠ 未守护目录（三分法有意排除，逻辑写进去不受本门禁约束）: entry 的 pages/dialogs/components/shell/widget、entryability/entryformability 系、uikit/wearable 模块。');

if (!failed) {
  console.log('✓ 逻辑层覆盖率未回退');
}
