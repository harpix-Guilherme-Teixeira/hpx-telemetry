# hpx-telemetry: instalador do pack de telemetria de uso de IA da harpix.
# Roda em nivel de usuario, sem admin e sem UAC.
# O que ele faz:
#   1. Registra voce (nome, email, maquina) no banco de telemetria
#   2. Copia os scripts pra %USERPROFILE%\.hpx-telemetry
#   3. Adiciona os hooks de metadados no ~/.claude/settings.json (preservando o que ja existe)
#   4. Cria as tarefas agendadas: watcher do Claude Desktop (5 min) e auto update (diario)
# Depois disso nada mais e preciso: basta a pessoa usar Claude Code ou Claude Desktop.
# O que ele NAO faz: gravar conteudo de conversa. So metadados.
param(
    [string]$Name,
    [string]$Email,
    [string]$Team,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$Endpoint = 'https://crugvrjtkorkrtrbrolv.supabase.co'
$ApiKey   = 'sb_publishable_34fW8Tv3762EZPulvYZOsw_DsKDrdRP'
$WatcherTask = 'hpx-telemetry-watcher'
$UpdaterTask = 'hpx-telemetry-updater'

$dest = Join-Path $env:USERPROFILE '.hpx-telemetry'
$configPath = Join-Path $dest 'config.json'

# Versao vem do package.json que acompanha o pack (npm)
$version = '0.0.0'
$pkgJson = Join-Path $PSScriptRoot 'package.json'
if (Test-Path $pkgJson) {
    try { $version = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version } catch {}
}

if (-not $Silent) {
    Write-Host ''
    Write-Host "=== hpx-telemetry v$version ===" -ForegroundColor DarkYellow
    Write-Host 'Telemetria de uso de Claude / Claude Code da harpix (somente metadados).'
    Write-Host ''
}

# Identidade: parametro > config existente (update) > pergunta interativa
if ((-not $Name -or -not $Email -or -not $Team) -and (Test-Path $configPath)) {
    try {
        $old = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not $Name)  { $Name  = $old.nam_user }
        if (-not $Email) { $Email = $old.nam_email }
        if (-not $Team)  { $Team  = $old.nam_team }
    } catch {}
}
if (-not $Silent) {
    if (-not $Name)  { $Name  = Read-Host 'Seu nome completo' }
    if (-not $Email) { $Email = Read-Host 'Seu email harpix' }
    if (-not $Team) {
        $teams = @('Desenvolvimento', 'Dados', 'Marketing', 'Comercial', 'Produto')
        Write-Host 'Em qual time voce atua?'
        for ($i = 0; $i -lt $teams.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $teams[$i])
        }
        Write-Host ("  {0}. Outro" -f ($teams.Count + 1))
        $choice = Read-Host 'Numero do time'
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $teams.Count) {
            $Team = $teams[$idx - 1]
        } elseif ($idx -eq ($teams.Count + 1)) {
            $Team = Read-Host 'Nome do seu time'
        }
    }
}
if (-not $Name -or -not $Email) {
    if (-not $Silent) { Write-Host 'Nome e email sao obrigatorios.' -ForegroundColor Red }
    exit 1
}

$machine = $env:COMPUTERNAME
$os = (Get-CimInstance Win32_OperatingSystem).Caption

function Write-Step($msg) {
    if (-not $Silent) { Write-Host $msg -ForegroundColor Green }
}
function Write-Warn($msg) {
    if (-not $Silent) { Write-Host $msg -ForegroundColor Yellow }
}

# 1. Pasta local + scripts + config
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$srcDir = Join-Path $PSScriptRoot 'src'
Copy-Item (Join-Path $srcDir 'telemetry-hook.ps1') $dest -Force
Copy-Item (Join-Path $srcDir 'desktop-watcher.ps1') $dest -Force
Copy-Item (Join-Path $srcDir 'self-update.ps1') $dest -Force

$config = @{
    endpoint    = $Endpoint
    api_key     = $ApiKey
    nam_user    = $Name
    nam_email   = $Email
    nam_team    = $Team
    nam_machine = $machine
    version     = $version
}
$configJson = ConvertTo-Json $config -Depth 3
[System.IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Step "[1/4] Scripts e config em $dest"

# 2. Registro do colaborador
# Insert simples: o upsert do PostgREST (resolution=ignore-duplicates) exige policy
# de SELECT, que a chave nao tem de proposito. Duplicata (409) e tratada como sucesso.
function Send-Row($table, $row) {
    $json = ConvertTo-Json $row -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{ apikey = $ApiKey; Prefer = 'return=minimal' }
    try {
        Invoke-RestMethod -Method Post -Uri "$Endpoint/rest/v1/$table" -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 10 | Out-Null
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -ne 409) { throw }
    }
}

try {
    Send-Row 'rec_collaborator' @{
        nam_user = $Name; nam_email = $Email; nam_team = $Team; nam_machine = $machine; nam_os = $os
    }
    Write-Step '[2/4] Colaborador registrado no banco'
} catch {
    Write-Warn "[2/4] Aviso: nao consegui registrar agora ($($_.Exception.Message)). Siga em frente."
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
Write-Step '[3/4] Hooks do Claude Code configurados (backup em settings.json.bak-hpx-telemetry)'

# 4. Tarefas agendadas (nivel de usuario, sem admin)
$watcherScript = Join-Path $dest 'desktop-watcher.ps1'
$updateScript  = Join-Path $dest 'self-update.ps1'

$trWatcher = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$watcherScript\`""
schtasks /Create /F /SC MINUTE /MO 5 /TN $WatcherTask /TR $trWatcher | Out-Null
$watcherOk = ($LASTEXITCODE -eq 0)

$trUpdater = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$updateScript\`""
schtasks /Create /F /SC DAILY /ST 12:30 /TN $UpdaterTask /TR $trUpdater | Out-Null
$updaterOk = ($LASTEXITCODE -eq 0)

if ($watcherOk -and $updaterOk) {
    Write-Step '[4/4] Watcher do Desktop (5 min) e auto update (diario) agendados'
} else {
    Write-Warn '[4/4] Aviso: alguma tarefa agendada falhou. O Claude Code segue coberto pelos hooks.'
}

# Evento de confirmacao (install na primeira vez, update no auto update)
$eventType = 'install'
if ($Silent) { $eventType = 'update' }
try {
    Send-Row 'fac_usage_event' @{
        nam_user = $Name; nam_email = $Email; nam_machine = $machine
        nam_source = 'claude_code'; nam_event_type = $eventType
        jsn_meta = @{ nam_os = $os; str_version = $version }
    }
} catch {}

# Inventario de MCPs configurados no Claude Code (~/.claude.json).
# So os NOMES dos servidores MCP, nunca args/tokens/segredos.
try {
    $claudeJsonPath = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path $claudeJsonPath) {
        $cj = Get-Content $claudeJsonPath -Raw | ConvertFrom-Json
        $servers = @{}
        if ($cj.mcpServers) { $cj.mcpServers.PSObject.Properties.Name | ForEach-Object { $servers[$_] = $true } }
        if ($cj.projects) {
            foreach ($proj in $cj.projects.PSObject.Properties) {
                if ($proj.Value.mcpServers) {
                    $proj.Value.mcpServers.PSObject.Properties.Name | ForEach-Object { $servers[$_] = $true }
                }
            }
        }
        if ($servers.Count -gt 0) {
            Send-Row 'fac_usage_event' @{
                nam_user = $Name; nam_email = $Email; nam_machine = $machine
                nam_source = 'claude_code'; nam_event_type = 'mcp_inventory'
                jsn_meta = @{ arr_mcps = @($servers.Keys); num_mcps = $servers.Count }
            }
        }
    }
} catch {}

# Cobertura imediata: se algum app de IA ja estiver aberto agora, registra sem esperar o primeiro tick
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcherScript | Out-Null
} catch {}

if (-not $Silent) {
    Write-Host ''
    Write-Host 'Pronto. Nao precisa fazer mais nada: e so usar o Claude Code ou o Claude Desktop normalmente.' -ForegroundColor DarkYellow
    Write-Host 'Coletado: nome, email, maquina, data/hora, projeto (nome da pasta), modelo e tokens.' -ForegroundColor DarkYellow
    Write-Host 'NUNCA coletado: o texto das suas conversas.' -ForegroundColor DarkYellow
}
