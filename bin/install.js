#!/usr/bin/env node
// hpx-telemetry: wrapper npx que dispara o instalador PowerShell.
//
// Este wrapper NAO repassa argumento solto. Motivo real: ele repassava argv cru,
// e o primeiro parametro posicional do install.ps1 e o -Name. Quem rodou
// "npx hpx-telemetry version" gravou o nome "version" no cadastro por cima da
// identidade que ja estava certa. So flag nomeada e reconhecida passa adiante.
const { spawnSync } = require('child_process');
const path = require('path');

const pkg = require('../package.json');

const USAGE = [
  '',
  `hpx-telemetry v${pkg.version}`,
  'Telemetria de uso de IA da harpix (somente metadados).',
  '',
  'Uso:',
  '  npx hpx-telemetry                          instalacao interativa',
  '  npx hpx-telemetry -Name "Nome Completo" -Email nome@harpix.com.br [-Team Dados]',
  '  npx hpx-telemetry --version',
  '  npx hpx-telemetry --help',
  '',
].join('\n');

const argv = process.argv.slice(2);
const first = (argv[0] || '').toLowerCase();

if (['-v', '--version', 'version'].includes(first)) {
  console.log(pkg.version);
  process.exit(0);
}
if (['-h', '--help', 'help', '/?'].includes(first)) {
  console.log(USAGE);
  process.exit(0);
}

// Whitelist: nome da flag (minusculo) -> se consome o proximo argumento
const FLAGS = { '-name': true, '-email': true, '-team': true, '-silent': false };
const forward = [];
for (let i = 0; i < argv.length; i++) {
  const flag = argv[i].toLowerCase();
  if (!Object.prototype.hasOwnProperty.call(FLAGS, flag)) {
    console.error(`Argumento nao reconhecido: ${argv[i]}`);
    console.error(USAGE);
    process.exit(1);
  }
  forward.push(argv[i]);
  if (FLAGS[flag]) {
    if (i + 1 >= argv.length) {
      console.error(`Falta o valor de ${argv[i]}.`);
      process.exit(1);
    }
    forward.push(argv[++i]);
  }
}

if (process.platform !== 'win32') {
  console.error('hpx-telemetry roda somente em Windows.');
  process.exit(1);
}

const script = path.join(__dirname, '..', 'install.ps1');
const result = spawnSync(
  'powershell.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...forward],
  { stdio: 'inherit' }
);
process.exit(result.status === null ? 1 : result.status);
