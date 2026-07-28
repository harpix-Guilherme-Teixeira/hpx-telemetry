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
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.hpx-telemetry\config.json'),
    # imprime o que seria enviado e nao envia nada. serve pra conferir deteccao
    # na propria maquina sem sujar o banco.
    [switch]$DryRun
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
    $hasWindow = @{}

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
        if ($tool) {
            $counts[$tool] = ($counts[$tool] + 1)
            # basta UM processo do grupo ter janela: app Electron abre varios
            # processos filhos e so o principal carrega o titulo.
            if (-not $hasWindow[$tool]) {
                $wt = ''
                try { $wt = "$($p.MainWindowTitle)" } catch {}
                if ($wt) { $hasWindow[$tool] = $true }
            }
        }
    }

    # Processo residente NAO e uso. Caso real que motivou a regra: o
    # M365Copilot.exe do Office Hub fica ligado o tempo todo, sem janela, e
    # fazia o Copilot aparecer em 100% dos ticks de todo mundo (60 de 60 num
    # dia), virando a "ferramenta mais usada da empresa" sem ninguem abrir.
    # Descartar o que nao tem janela troca falso positivo garantido por um
    # possivel falso negativo (app minimizado na bandeja), que e o erro barato.
    # A checagem de _web e redundante aqui (a parte 2 ainda nem rodou), mas
    # deixa a poda segura se alguem mover este bloco: aba de navegador nunca
    # passa por $hasWindow e seria apagada em silencio.
    foreach ($tool in @($counts.Keys)) {
        if (-not $tool.EndsWith('_web') -and -not $hasWindow[$tool]) { $counts.Remove($tool) }
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
            # O Edge gruda "e mais N paginas" no titulo quando a janela tem mais
            # de uma aba ("Claude e mais 6 paginas - Trabalho - Microsoft Edge"),
            # e em ingles "and N more pages". Sem cortar esse sufixo o segmento
            # nunca casa, e quem usa Edge com varias abas, ou seja quase todo
            # mundo, fica invisivel pra captura web.
            $key = ($key -replace '\s+(e mais \d+ p.ginas?|and \d+ more pages?)$', '').Trim()
            if ($key -and $WebMarkers.ContainsKey($key)) {
                $tool = $WebMarkers[$key]
                $counts[$tool] = ($counts[$tool] + 1)
                break
            }
        }
        # $title sai de escopo aqui e nunca e enviado
    }

    if ($DryRun) {
        if ($counts.Count -eq 0) { Write-Host 'nenhuma ferramenta de IA detectada' }
        foreach ($tool in $counts.Keys) {
            Write-Host ("{0,-18} x{1}" -f $tool, $counts[$tool])
        }
        exit 0
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
                # 'process_window' (e nao 'process') marca o cliente que ja exige
                # janela visivel. E o que separa, na leitura, o dado confiavel do
                # que veio das versoes <= 1.3.1, que contavam processo residente.
                str_detection = if ($isWeb) { 'window_title' } else { 'process_window' }
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
