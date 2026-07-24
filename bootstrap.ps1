# hpx-telemetry: instalacao em uma linha.
# Uso (colar no PowerShell):
#   irm https://raw.githubusercontent.com/harpix-Guilherme-Teixeira/hpx-telemetry/develop/bootstrap.ps1 | iex
# Baixa o pack, extrai e roda o instalador interativo. Sem admin, sem UAC.
$ErrorActionPreference = 'Stop'

$tmp = Join-Path $env:TEMP ('hpx-telemetry-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$zip = Join-Path $tmp 'hpx-telemetry.zip'
Write-Host 'Baixando o pack hpx-telemetry...' -ForegroundColor DarkYellow
Invoke-WebRequest -Uri 'https://github.com/harpix-Guilherme-Teixeira/hpx-telemetry/archive/refs/heads/develop.zip' `
    -OutFile $zip -UseBasicParsing

Expand-Archive -Path $zip -DestinationPath $tmp -Force

& (Join-Path $tmp 'hpx-telemetry-develop\install.ps1')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
