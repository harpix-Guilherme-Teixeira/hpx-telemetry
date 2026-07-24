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

# Scripts baixados da internet carregam Mark of the Web e podem ser bloqueados
# por politica RemoteSigned; desbloqueia e roda com Bypass de processo (sem admin).
Get-ChildItem -Path $tmp -Recurse -Filter *.ps1 | Unblock-File -ErrorAction SilentlyContinue
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'hpx-telemetry-develop\install.ps1')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
