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

# Identidade e chave de leitura: nome sujo vira pessoa duplicada no relatorio.
# Ja aconteceu: "Sergio", "Sergio  " e "Sergio Alves" viraram tres linhas, e um
# "npx hpx-telemetry version" gravou o nome "version" por cima do certo.
$Name  = ($Name  -replace '\s+', ' ').Trim()
$Email = $Email.Trim().ToLowerInvariant()

if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    if (-not $Silent) { Write-Host "'$Email' nao e um email valido." -ForegroundColor Red }
    exit 1
}

# Nome invalido NAO pode abortar: no modo silencioso quem roda isso e o auto
# update, e quem esta com o cadastro sujo e justamente quem mais precisa do pack
# novo. Aborta-lo congelaria a maquina na versao velha pra sempre. Entao
# reconstroi o nome a partir do email, que e a chave confiavel.
if ($Name.Length -lt 2 -or $Name -match '^[-/]' -or
    $Name -match '^(version|help|install|update|uninstall|silent|true|false)$') {
    $derivado = (($Email -split '@')[0] -split '[._-]+' |
        Where-Object { $_ } |
        ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ' '
    if (-not $Silent) {
        Write-Host "Nome '$Name' invalido, usando '$derivado' (derivado do email)." -ForegroundColor Yellow
    }
    $Name = $derivado
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
Copy-Item (Join-Path $srcDir 'run-hidden.vbs') $dest -Force

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
# Lancadas via wscript + run-hidden.vbs pra rodar SEM flash de janela de console.
#
# ATENCAO: em maquina gerida, GPO ou EDR pode NEGAR a criacao de tarefa. O
# schtasks escreve no stderr e, com ErrorActionPreference = Stop, isso vira erro
# terminante e matava o instalador aqui no meio: a maquina ficava com o config
# gravado, sem agendamento, sem evento de install e sem aviso pra pessoa.
# Por isso cada chamada vai em try/catch e confere o codigo de saida na mao.
# O catch cobre os dois modos de falha: schtasks recusado (stderr vira erro
# terminante) e schtasks impedido de sequer iniciar (ApplicationFailedException).
# O resultado viaja no evento de install pra que a maquina apareca no painel
# como instalada porem sem agendamento, em vez de sumir calada.
$watcherScript = Join-Path $dest 'desktop-watcher.ps1'
$updateScript  = Join-Path $dest 'self-update.ps1'
$hiddenVbs     = Join-Path $dest 'run-hidden.vbs'

$trWatcher = "wscript.exe \`"$hiddenVbs\`" \`"$watcherScript\`""
$watcherOk = $false
try {
    schtasks /Create /F /SC MINUTE /MO 15 /TN $WatcherTask /TR $trWatcher | Out-Null
    $watcherOk = ($LASTEXITCODE -eq 0)
} catch { $watcherOk = $false }

$trUpdater = "wscript.exe \`"$hiddenVbs\`" \`"$updateScript\`""
$updaterOk = $false
try {
    schtasks /Create /F /SC DAILY /ST 12:30 /TN $UpdaterTask /TR $trUpdater | Out-Null
    $updaterOk = ($LASTEXITCODE -eq 0)
} catch { $updaterOk = $false }

if ($watcherOk -and $updaterOk) {
    Write-Step '[4/4] Watcher do Desktop (15 min) e auto update (diario) agendados'
} else {
    Write-Warn '[4/4] Aviso: a politica desta maquina bloqueou o agendamento.'
    Write-Warn '      O Claude Code segue coberto pelos hooks, mas o uso do Claude Desktop'
    Write-Warn '      e de IA no navegador nao sera registrado, e o auto update nao roda.'
    Write-Warn '      Avise o time de Dados & IA para tratar esta maquina.'
}

# Evento de confirmacao (install na primeira vez, update no auto update)
$eventType = 'install'
if ($Silent) { $eventType = 'update' }
try {
    Send-Row 'fac_usage_event' @{
        nam_user = $Name; nam_email = $Email; nam_machine = $machine
        nam_source = 'claude_code'; nam_event_type = $eventType
        jsn_meta = @{
            nam_os                = $os
            str_version           = $version
            flg_watcher_scheduled = $watcherOk
            flg_updater_scheduled = $updaterOk
        }
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
