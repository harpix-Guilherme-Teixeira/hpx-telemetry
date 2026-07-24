# hpx-telemetry: watcher do Claude Desktop.
# Roda a cada 5 min via tarefa agendada de usuario. Se o app estiver aberto,
# manda um heartbeat (sem nenhum conteudo). Sessoes sao derivadas no banco por gap.
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -like '*AnthropicClaude*' } catch { $false }
    })
    if ($procs.Count -eq 0) { exit 0 }

    $payload = @{
        nam_user       = $config.nam_user
        nam_email      = $config.nam_email
        nam_machine    = $config.nam_machine
        nam_source     = 'claude_desktop'
        nam_event_type = 'heartbeat'
        jsn_meta       = @{ num_processes = $procs.Count }
    }

    $json = ConvertTo-Json $payload -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }
    Invoke-RestMethod -Method Post -Uri "$($config.endpoint)/rest/v1/fac_usage_event" `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec 5 | Out-Null
} catch {}

exit 0
