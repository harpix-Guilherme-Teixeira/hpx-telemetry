# hpx-telemetry: hook do Claude Code.
# Envia SOMENTE metadados (user, hora, maquina, sessao, projeto, modelo, tokens).
# Nenhum conteudo de prompt ou resposta sai da maquina.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('session_start', 'response', 'session_end')]
    [string]$EventType,

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

function Get-Num($value) {
    if ($null -ne $value) { return [int64]$value }
    return [int64]0
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $raw = [Console]::In.ReadToEnd()
    $hookInput = $null
    if ($raw) {
        try { $hookInput = $raw | ConvertFrom-Json } catch { $hookInput = $null }
    }

    $project = $null
    if ($hookInput -and $hookInput.cwd) { $project = Split-Path $hookInput.cwd -Leaf }

    $payload = @{
        nam_user       = $config.nam_user
        nam_email      = $config.nam_email
        nam_machine    = $config.nam_machine
        nam_source     = 'claude_code'
        nam_event_type = $EventType
        str_session    = if ($hookInput) { $hookInput.session_id } else { $null }
        nam_project    = $project
    }

    # No Stop (response), extrai modelo e tokens da ultima resposta a partir do transcript local
    if ($EventType -eq 'response' -and $hookInput -and $hookInput.transcript_path -and (Test-Path $hookInput.transcript_path)) {
        $lines = @(Get-Content $hookInput.transcript_path -Tail 100)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                $entry = $lines[$i] | ConvertFrom-Json
                if ($entry.type -eq 'assistant' -and $entry.message -and $entry.message.usage) {
                    $usage = $entry.message.usage
                    $payload.nam_model = $entry.message.model
                    $payload.num_input_tokens = (Get-Num $usage.input_tokens) + (Get-Num $usage.cache_read_input_tokens) + (Get-Num $usage.cache_creation_input_tokens)
                    $payload.num_output_tokens = Get-Num $usage.output_tokens
                    break
                }
            } catch {}
        }
    }

    $json = ConvertTo-Json $payload -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }
    Invoke-RestMethod -Method Post -Uri "$($config.endpoint)/rest/v1/fac_usage_event" `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec 5 | Out-Null
} catch {
    # Telemetria nunca pode atrapalhar o trabalho: falhou, segue o jogo.
}

exit 0
