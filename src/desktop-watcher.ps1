# hpx-telemetry: watcher de apps de IA de desktop.
# Roda periodicamente via tarefa agendada de usuario. Detecta apps de IA abertos
# e manda um heartbeat por ferramenta. Sem nenhum conteudo.
#
# PERFORMANCE: filtra por NOME do processo primeiro (barato, nao abre handle) e
# so abre o caminho dos poucos candidatos pra classificar. Evita enumerar .Path
# de todos os processos, que pesava em maquina com antivirus/EDR.
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # 1) filtro barato por nome (sem abrir handle de path)
    $cands = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'claude|chatgpt|cursor|copilot|windsurf|perplexity' })
    if ($cands.Count -eq 0) { exit 0 }

    # 2) so nos candidatos, abre o caminho e classifica pela ferramenta
    $counts = @{}
    foreach ($p in $cands) {
        $path = ''
        try { $path = "$($p.Path)" } catch {}
        $name = $p.Name
        $tool = $null
        if ($path -like '*AnthropicClaude*') { $tool = 'claude_desktop' }      # Claude Desktop (nao o CLI)
        elseif ($name -match 'claude') { $tool = $null }                        # claude sem esse path = Claude Code CLI, ja coberto por hook
        elseif ($name -match 'chatgpt') { $tool = 'chatgpt_desktop' }
        elseif ($name -match 'cursor') { $tool = 'cursor' }
        elseif ($name -match 'copilot') { $tool = 'copilot' }
        elseif ($name -match 'windsurf') { $tool = 'windsurf' }
        elseif ($name -match 'perplexity') { $tool = 'perplexity' }
        if ($tool) { $counts[$tool] = ($counts[$tool] + 1) }
    }
    if ($counts.Count -eq 0) { exit 0 }

    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }
    foreach ($tool in $counts.Keys) {
        $payload = @{
            nam_user       = $config.nam_user
            nam_email      = $config.nam_email
            nam_machine    = $config.nam_machine
            nam_source     = 'claude_desktop'
            nam_ai_tool    = $tool
            nam_event_type = 'heartbeat'
            jsn_meta       = @{ num_processes = $counts[$tool] }
        }
        $json = ConvertTo-Json $payload -Depth 5
        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
        try {
            Invoke-RestMethod -Method Post -Uri "$($config.endpoint)/rest/v1/fac_usage_event" `
                -Headers $headers -ContentType 'application/json; charset=utf-8' `
                -Body $body -TimeoutSec 5 | Out-Null
        } catch {}
    }
} catch {}

exit 0
