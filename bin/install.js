#!/usr/bin/env node
// hpx-telemetry: wrapper npx que dispara o instalador PowerShell.
const { spawnSync } = require('child_process');
const path = require('path');

if (process.platform !== 'win32') {
  console.error('hpx-telemetry roda somente em Windows.');
  process.exit(1);
}

const script = path.join(__dirname, '..', 'install.ps1');
const result = spawnSync(
  'powershell.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...process.argv.slice(2)],
  { stdio: 'inherit' }
);
process.exit(result.status === null ? 1 : result.status);
