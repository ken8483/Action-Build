#!/usr/bin/env node
/**
 * 端到端验证：从修好的 workflow YAML 里抽出 "Custom Kernel Suffix if set" 步骤，
 * 在模拟的真机目录（common + msm-kernel 两棵 setlocalversion）上真实执行，
 * 再跑一遍生成版本，检查 UTS_RELEASE 是否精确等于真机版本。
 */
const yaml = require('/tmp/node_modules/js-yaml');
const fs = require('fs');
const { execSync } = require('child_process');

const WF = '/workspace/output/Build Kernel OnePlus.yml';
const doc = yaml.load(fs.readFileSync(WF, 'utf8'));
const step = doc.jobs.build.steps.find(s => s.name === 'Custom Kernel Suffix if set');
if (!step) { console.error('❌ 找不到步骤'); process.exit(2); }
const RAW = step.run;

const EXPECT = '5.10.246-android12-9-0-g931a7e2ba585';
const REAL_SCRIPT = '/workspace/realme/setlocalversion'; // 真机(realme 5.10)真实 setlocalversion

function buildTree(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  for (const sub of ['common', 'msm-kernel']) {
    const base = `${dir}/kernel_workspace/kernel_platform/${sub}`;
    fs.mkdirSync(`${base}/scripts`, { recursive: true });
    fs.mkdirSync(`${base}/include/config`, { recursive: true });
    fs.copyFileSync(REAL_SCRIPT, `${base}/scripts/setlocalversion`);
    fs.writeFileSync(`${base}/include/config/auto.conf`,
      'CONFIG_LOCALVERSION="-gki"\nCONFIG_LOCALVERSION_AUTO=y\n');
  }
}

function runCase(fast) {
  const dir = `/workspace/e2e_${fast ? 'fast' : 'official'}`;
  buildTree(dir);

  // 模拟 GitHub Actions 的表达式替换
  const script = RAW
    .replace(/\$\{\{\s*github\.event\.inputs\.SUFFIX\s*\}\}/g, '9-0-g931a7e2ba585')
    .replace(/\$\{\{\s*github\.event\.inputs\.FAST_BUILD\s*\}\}/g, fast ? 'true' : 'false');

  const env = {
    ...process.env,
    KANDROID_VERSION: 'android12',
    SUFFIX: '9-0-g931a7e2ba585',
    KERNEL_REPOS: 'msm-kernel',
    FAST_BUILD: fast ? 'true' : 'false',
    GITHUB_ENV: `${dir}/github_env`,
    GITHUB_OUTPUT: `${dir}/github_out`,
  };
  fs.writeFileSync(env.GITHUB_ENV, '');
  fs.writeFileSync(env.GITHUB_OUTPUT, '');

  const shPath = `${dir}/step.sh`;
  fs.writeFileSync(shPath, script);
  execSync('bash step.sh', { cwd: dir, env, stdio: 'pipe' });

  const results = [];
  for (const sub of ['common', 'msm-kernel']) {
    const out = execSync('sh scripts/setlocalversion . android12-5.10 9',
      { cwd: `${dir}/kernel_workspace/kernel_platform/${sub}`, env, stdio: 'pipe' })
      .toString().trim();
    const final = `5.10.246${out}`;
    results.push({ tree: sub, final, ok: final === EXPECT });
  }
  console.log(`\n=== FAST_BUILD=${fast} ===`);
  for (const r of results) {
    console.log(`  ${r.tree.padEnd(12)} ${r.ok ? '✅' : '❌'} ${r.final}`);
  }
  return results.every(r => r.ok);
}

const a = runCase(true);
const b = runCase(false);
console.log(`\n目标版本: ${EXPECT}`);
if (a && b) {
  console.log('✅ 两条构建路径都产出与真机完全一致的版本串');
  process.exit(0);
}
console.log('❌ 存在不一致');
process.exit(1);
