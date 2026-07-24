# hpx-telemetry: hook do Claude Code.
# Envia SOMENTE metadados (user, hora, maquina, sessao, projeto, modelo, tokens,
# rotulo trabalho/pessoal calculado LOCAL, MCPs usados). Nenhum conteudo de
# prompt ou resposta sai da maquina.
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

# Classifica trabalho x pessoal SEM ler conteudo: usa so o caminho e se e repo git.
# Retorna 'work', 'personal' ou 'unknown'. Nada disso sai da maquina alem do rotulo.
function Get-Classification($cwd) {
    if (-not $cwd) { return 'unknown' }
    $low = $cwd.ToLower()
    $personalDirs = @('\downloads\', '\desktop\', '\onedrive\', '\pictures\', '\music\', '\videos\')
    foreach ($d in $personalDirs) { if ($low -like "*$d*") { return 'personal' } }
    # repo git = sinal forte de trabalho
    if (Test-Path (Join-Path $cwd '.git')) { return 'work' }
    if ($low -like '*\projects\*' -or $low -like '*\repos\*' -or $low -like '*\source\*' -or $low -like '*\src\*') { return 'work' }
    if ($low -like '*\documents\*') { return 'personal' }
    return 'unknown'
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $raw = [Console]::In.ReadToEnd()
    $hookInput = $null
    if ($raw) {
        try { $hookInput = $raw | ConvertFrom-Json } catch { $hookInput = $null }
    }

    $cwd = if ($hookInput) { $hookInput.cwd } else { $null }
    $project = if ($cwd) { Split-Path $cwd -Leaf } else { $null }

    $payload = @{
        nam_user           = $config.nam_user
        nam_email          = $config.nam_email
        nam_machine        = $config.nam_machine
        nam_source         = 'claude_code'
        nam_ai_tool        = 'claude_code'
        nam_event_type     = $EventType
        str_session        = if ($hookInput) { $hookInput.session_id } else { $null }
        nam_project        = $project
        nam_classification = Get-Classification $cwd
    }

    # No Stop (response): modelo, tokens e MCPs usados, a partir do transcript LOCAL.
    # So contamos nomes de ferramenta mcp__<servidor>__<tool>; nenhum texto e lido.
    if ($EventType -eq 'response' -and $hookInput -and $hookInput.transcript_path -and (Test-Path $hookInput.transcript_path)) {
        $lines = @(Get-Content $hookInput.transcript_path -Tail 200)
        $usageDone = $false
        $mcps = @{}
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                $entry = $lines[$i] | ConvertFrom-Json
                if ($entry.type -eq 'assistant' -and $entry.message) {
                    if (-not $usageDone -and $entry.message.usage) {
                        $usage = $entry.message.usage
                        $payload.nam_model = $entry.message.model
                        $payload.num_input_tokens = (Get-Num $usage.input_tokens) + (Get-Num $usage.cache_read_input_tokens) + (Get-Num $usage.cache_creation_input_tokens)
                        $payload.num_output_tokens = Get-Num $usage.output_tokens
                        $usageDone = $true
                    }
                    foreach ($c in @($entry.message.content)) {
                        if ($c.type -eq 'tool_use' -and $c.name -like 'mcp__*') {
                            $server = ($c.name -split '__')[1]
                            if ($server) { $mcps[$server] = $true }
                        }
                    }
                }
            } catch {}
        }
        if ($mcps.Count -gt 0) { $payload.jsn_meta = @{ arr_mcps = @($mcps.Keys) } }
    }

    $json = ConvertTo-Json $payload -Depth 6
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }
    Invoke-RestMethod -Method Post -Uri "$($config.endpoint)/rest/v1/fac_usage_event" `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec 5 | Out-Null
} catch {
    # Telemetria nunca pode atrapalhar o trabalho: falhou, segue o jogo.
}

exit 0
