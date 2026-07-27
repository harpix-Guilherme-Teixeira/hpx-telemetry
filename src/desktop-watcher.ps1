# hpx-telemetry: watcher de ferramentas de IA em uso na maquina.
# Roda periodicamente via tarefa agendada de usuario. Sem nenhum conteudo.
#
# Cobre duas superficies:
#   1. APP INSTALADO: processo de IA aberto (Claude Desktop, ChatGPT, Cursor, ...)
#   2. IA NA WEB: navegador com a aba ativa em claude.ai, chatgpt.com, Gemini, ...
#
# PRIVACIDADE (regra dura do projeto): o titulo da janela e lido, classificado e
# DESCARTADO na memoria local. So o rotulo da ferramenta (ex: chatgpt_web) sai da
# maquina. O texto do titulo, que pode conter nome de conversa ou de arquivo,
# NUNCA entra no payload. Mesmo desenho do rotulo trabalho/pessoal.
#
# PERFORMANCE: uma unica enumeracao de processos, filtro por NOME (barato) e o
# caminho (.Path) so e aberto nos poucos candidatos de app instalado. Enumerar
# .Path de tudo pesava em maquina com antivirus/EDR. Titulo de janela nao abre
# handle: custa ~90ms.
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json')
)

$ErrorActionPreference = 'Stop'

# Marcadores de IA na web. A chave e comparada com o SEGMENTO do titulo da aba,
# nao com o titulo inteiro: navegador monta o titulo como "<pagina> - <navegador>"
# e essas SPAs terminam a parte da pagina com o nome do produto. Comparar segmento
# inteiro evita falso positivo tipo um .docx com "Claude" no nome do arquivo.
$WebMarkers = @{
    'claude'             = 'claude_web'
    'chatgpt'            = 'chatgpt_web'
    'gemini'             = 'gemini_web'
    'google gemini'      = 'gemini_web'
    'copilot'            = 'copilot_web'
    'microsoft copilot'  = 'copilot_web'
    'perplexity'         = 'perplexity_web'
}

$BrowserNames = 'chrome|msedge|firefox|brave|opera|vivaldi|chromium'

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $all = @(Get-Process -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { exit 0 }

    $counts = @{}

    # --- 1) apps de IA instalados -------------------------------------------
    # filtro barato por nome; so nos candidatos abre o caminho pra classificar
    foreach ($p in ($all | Where-Object { $_.Name -match 'claude|chatgpt|cursor|copilot|windsurf|perplexity' })) {
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

    # --- 2) IA na web (aba ativa do navegador) ------------------------------
    # Cobre o ponto cego: claude.ai e chatgpt.com usados no navegador, que o
    # watcher de processo nao enxerga. Ve so a aba em foco de cada janela.
    foreach ($p in ($all | Where-Object { $_.Name -match $BrowserNames })) {
        $title = ''
        try { $title = "$($p.MainWindowTitle)" } catch {}
        if (-not $title) { continue }

        # quebra o titulo nos separadores usados por navegador e perfil
        # ("Revisar contrato - Claude - Google Chrome" / "ChatGPT - Trabalho - Microsoft Edge").
        # Os traves en/em vao escapados em unicode de proposito: o arquivo fica ASCII puro,
        # porque o PowerShell 5.1 le .ps1 como ANSI e corromperia o caractere literal.
        foreach ($seg in ($title -split '\s+[-\u2013\u2014|]\s+')) {
            # tira caractere invisivel antes de comparar: o Gemini serve o titulo
            # com LRM (U+200E) na frente e o Edge mete zero-width space no meio.
            # Sem isso a comparacao exata falha calada.
            $key = ($seg -replace '\p{C}', '').Trim().ToLowerInvariant()
            if ($key -and $WebMarkers.ContainsKey($key)) {
                $tool = $WebMarkers[$key]
                $counts[$tool] = ($counts[$tool] + 1)
                break
            }
        }
        # $title sai de escopo aqui e nunca e enviado
    }

    if ($counts.Count -eq 0) { exit 0 }

    $headers = @{ apikey = $config.api_key; Prefer = 'return=minimal' }
    foreach ($tool in $counts.Keys) {
        $isWeb = $tool.EndsWith('_web')
        $payload = @{
            nam_user       = $config.nam_user
            nam_email      = $config.nam_email
            nam_machine    = $config.nam_machine
            nam_source     = 'claude_desktop'
            nam_ai_tool    = $tool
            nam_event_type = 'heartbeat'
            jsn_meta       = @{
                num_processes = $counts[$tool]
                str_surface   = if ($isWeb) { 'browser' } else { 'app' }
                str_detection = if ($isWeb) { 'window_title' } else { 'process' }
            }
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
