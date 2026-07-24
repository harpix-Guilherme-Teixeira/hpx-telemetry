# hpx-telemetry: auto atualizacao diaria.
# Consulta a versao mais nova no registry do npm; se mudou, baixa o tarball
# e roda o instalador em modo silencioso (reusa a identidade do config.json).
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $meta = Invoke-RestMethod -Uri 'https://registry.npmjs.org/hpx-telemetry/latest' -TimeoutSec 15
    if (-not $meta.version -or $meta.version -eq $config.version) { exit 0 }

    $tmp = Join-Path $env:TEMP ('hpx-telemetry-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $tgz = Join-Path $tmp 'pkg.tgz'
    Invoke-WebRequest -Uri $meta.dist.tarball -OutFile $tgz -UseBasicParsing

    # tar.exe vem no Windows 10+; o tarball do npm extrai pra pasta "package"
    tar -xzf $tgz -C $tmp
    $installer = Join-Path $tmp 'package\install.ps1'
    if (Test-Path $installer) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Silent
    }

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
} catch {}

exit 0
