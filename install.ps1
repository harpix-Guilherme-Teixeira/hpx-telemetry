# hpx-telemetry: instalador do pack de telemetria de uso de IA da harpix.
# Roda em nivel de usuario, sem admin e sem UAC.
# O que ele faz:
#   1. Registra voce (nome, email, maquina) no banco de telemetria
#   2. Copia os scripts pra %USERPROFILE%\.hpx-telemetry
#   3. Adiciona os hooks de metadados no ~/.claude/settings.json (preservando o que ja existe)
#   4. Cria a tarefa agendada do watcher do Claude Desktop (a cada 5 min)
# O que ele NAO faz: gravar conteudo de conversa. So metadados.
param(
    [string]$Name,
    [string]$Email
)

$ErrorActionPreference = 'Stop'

$Endpoint = 'https://crugvrjtkorkrtrbrolv.supabase.co'
$ApiKey   = 'sb_publishable_34fW8Tv3762EZPulvYZOsw_DsKDrdRP'
$TaskName = 'hpx-telemetry-watcher'

Write-Host ''
Write-Host '=== hpx-telemetry: instalador ===' -ForegroundColor DarkYellow
Write-Host 'Telemetria de uso de Claude / Claude Code da harpix (somente metadados).'
Write-Host ''

if (-not $Name)  { $Name  = Read-Host 'Seu nome completo' }
if (-not $Email) { $Email = Read-Host 'Seu email harpix' }
if (-not $Name -or -not $Email) { Write-Host 'Nome e email sao obrigatorios.' -ForegroundColor Red; exit 1 }

$machine = $env:COMPUTERNAME
$os = (Get-CimInstance Win32_OperatingSystem).Caption

# 1. Pasta local + config
$dest = Join-Path $env:USERPROFILE '.hpx-telemetry'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$srcDir = Join-Path $PSScriptRoot 'src'
Copy-Item (Join-Path $srcDir 'telemetry-hook.ps1') $dest -Force
Copy-Item (Join-Path $srcDir 'desktop-watcher.ps1') $dest -Force

$config = @{
    endpoint    = $Endpoint
    api_key     = $ApiKey
    nam_user    = $Name
    nam_email   = $Email
    nam_machine = $machine
}
$configJson = ConvertTo-Json $config -Depth 3
[System.IO.File]::WriteAllText((Join-Path $dest 'config.json'), $configJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[1/4] Scripts e config em $dest" -ForegroundColor Green

# 2. Registro do colaborador (ignora se essa maquina ja esta cadastrada)
function Send-Row($table, $row, $extraQuery) {
    $json = ConvertTo-Json $row -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $uri = "$Endpoint/rest/v1/$table$extraQuery"
    $headers = @{ apikey = $ApiKey; Prefer = 'return=minimal,resolution=ignore-duplicates' }
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 10 | Out-Null
}

try {
    Send-Row 'rec_collaborator' @{
        nam_user = $Name; nam_email = $Email; nam_machine = $machine; nam_os = $os
    } '?on_conflict=nam_email,nam_machine'
    Write-Host '[2/4] Colaborador registrado no banco' -ForegroundColor Green
} catch {
    Write-Host "[2/4] Aviso: nao consegui registrar agora ($($_.Exception.Message)). Siga em frente, o registro tenta de novo no primeiro evento." -ForegroundColor Yellow
}

# 3. Hooks no settings.json do Claude Code
$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
$settingsPath = Join-Path $claudeDir 'settings.json'

if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak-hpx-telemetry" -Force
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{}
}
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
}

$hookScript = Join-Path $dest 'telemetry-hook.ps1'
$eventMap = [ordered]@{
    'SessionStart' = 'session_start'
    'Stop'         = 'response'
    'SessionEnd'   = 'session_end'
}

foreach ($evt in $eventMap.Keys) {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$hookScript`" -EventType $($eventMap[$evt])"
    $newEntry = [pscustomobject]@{
        hooks = @([pscustomobject]@{ type = 'command'; command = $cmd; timeout = 15 })
    }
    if (-not $settings.hooks.PSObject.Properties[$evt]) {
        $settings.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue @($newEntry)
    } else {
        $existing = @($settings.hooks.$evt)
        $already = $existing | Where-Object {
            @($_.hooks).command -match 'hpx-telemetry'
        }
        if (-not $already) {
            $settings.hooks.$evt = @($existing + $newEntry)
        }
    }
}

$settingsJson = $settings | ConvertTo-Json -Depth 64
[System.IO.File]::WriteAllText($settingsPath, $settingsJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[3/4] Hooks do Claude Code configurados (backup em settings.json.bak-hpx-telemetry)' -ForegroundColor Green

# 4. Tarefa agendada do watcher (nivel de usuario, sem admin)
$watcherScript = Join-Path $dest 'desktop-watcher.ps1'
$tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$watcherScript\`""
schtasks /Create /F /SC MINUTE /MO 5 /TN $TaskName /TR $tr | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host '[4/4] Watcher do Claude Desktop agendado (a cada 5 min)' -ForegroundColor Green
} else {
    Write-Host '[4/4] Aviso: nao consegui criar a tarefa agendada. O Claude Code segue coberto pelos hooks.' -ForegroundColor Yellow
}

# Evento de confirmacao
try {
    Send-Row 'fac_usage_event' @{
        nam_user = $Name; nam_email = $Email; nam_machine = $machine
        nam_source = 'claude_code'; nam_event_type = 'install'
        jsn_meta = @{ nam_os = $os }
    } ''
} catch {}

Write-Host ''
Write-Host 'Instalacao concluida. O que e coletado: nome, email, maquina, data/hora, projeto (nome da pasta), modelo e tokens.' -ForegroundColor DarkYellow
Write-Host 'O que NUNCA e coletado: o texto das suas conversas.' -ForegroundColor DarkYellow
