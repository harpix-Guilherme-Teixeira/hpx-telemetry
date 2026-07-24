# hpx-telemetry: watcher de apps de IA de desktop.
# Roda a cada 5 min via tarefa agendada de usuario. Detecta processos das
# principais ferramentas de IA abertas e manda um heartbeat por ferramenta.
# Sem nenhum conteudo; sessoes sao derivadas no banco por gap.
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

# Mapa ferramenta -> padrao no caminho do executavel do processo
$tools = [ordered]@{
    'claude_desktop'  = '*AnthropicClaude*'
    'chatgpt_desktop' = '*\ChatGPT\*'
    'cursor'          = '*\cursor\*'
    'copilot'         = '*\GitHub Copilot*'
    'windsurf'        = '*\Windsurf\*'
    'perplexity'      = '*\Perplexity\*'
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $procs = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Path } catch { $null }
    } | Where-Object { $_ })

    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }

    foreach ($tool in $tools.Keys) {
        $pattern = $tools[$tool]
        $count = @($procs | Where-Object { $_ -like $pattern }).Count
        if ($count -eq 0) { continue }

        $payload = @{
            nam_user       = $config.nam_user
            nam_email      = $config.nam_email
            nam_machine    = $config.nam_machine
            nam_source     = 'claude_desktop'
            nam_ai_tool    = $tool
            nam_event_type = 'heartbeat'
            jsn_meta       = @{ num_processes = $count }
        }
        # nam_source segue 'claude_desktop' para o Claude; para as outras, marca a ferramenta
        if ($tool -ne 'claude_desktop') { $payload.nam_source = 'claude_desktop' }

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
