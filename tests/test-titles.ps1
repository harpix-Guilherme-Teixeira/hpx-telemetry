# Testa a classificacao de titulo do desktop-watcher, sem tocar no banco.
# Le o regex e o mapa DIRETO do script que vai pro pack, pra testar o que embarca.
# Arquivo ASCII puro: o em dash dos casos e montado por codigo de caractere.
$watcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\desktop-watcher.ps1'
$src = [IO.File]::ReadAllText($watcher, [Text.Encoding]::ASCII)

# extrai o padrao de split usado no watcher
if ($src -notmatch "(?m)-split\s+'([^']+)'") { throw 'nao achei o regex de split no watcher' }
$SplitPattern = $Matches[1]
"regex em teste: $SplitPattern"

# extrai o bloco do hashtable de marcadores e avalia
if ($src -notmatch '(?s)\$WebMarkers = (@\{.*?\n\})') { throw 'nao achei o WebMarkers no watcher' }
$WebMarkers = Invoke-Expression $Matches[1]
''

function Get-Tool($title) {
    foreach ($seg in ($title -split $SplitPattern)) {
        $key = ($seg -replace '\p{C}', '').Trim().ToLowerInvariant()
        if ($key -and $WebMarkers.ContainsKey($key)) { return $WebMarkers[$key] }
    }
    return $null
}

$em = [string][char]0x2014   # travessao usado por Edge e Firefox
$en  = [string][char]0x2013
$lrm = [string][char]0x200E   # left-to-right mark que o Gemini serve no titulo

$cases = @(
    @{ t = 'Claude - Google Chrome';                                    e = 'claude_web' }
    @{ t = 'Revisar contrato Sabesp - Claude - Google Chrome';          e = 'claude_web' }
    @{ t = "ChatGPT - Trabalho $em Microsoft Edge";                     e = 'chatgpt_web' }
    @{ t = "Gemini $em Mozilla Firefox";                                e = 'gemini_web' }
    @{ t = "Perplexity $en Google Chrome";                              e = 'perplexity_web' }
    @{ t = "Microsoft Copilot - Trabalho $em Microsoft Edge";           e = 'copilot_web' }
    # falsos positivos que NAO podem classificar
    @{ t = 'Padrao-Dominio-BigQuery-harpix_V2.docx - Google Chrome';    e = $null }
    @{ t = 'chatgpt tips - Pesquisa Google - Google Chrome';            e = $null }
    @{ t = 'Claude.docx - Word';                                        e = $null }
    @{ t = 'Como usar o Claude no trabalho - Medium - Google Chrome';   e = $null }
    @{ t = 'hpx-telemetry: claude e chatgpt - GitHub - Google Chrome';  e = $null }
    @{ t = 'Reuniao com o time - Google Agenda - Google Chrome';        e = $null }
    @{ t = "${lrm}Google Gemini - Google Chrome";                    e = 'gemini_web' }
    @{ t = 'ChatGPT: Chat, Work, Create & Code with AI - Google Chrome'; e = $null }
    # titulos REAIS capturados na maquina do Gui em 27/07/2026 (regressao)
    @{ t = 'New chat - Claude - Google Chrome';                          e = 'claude_web' }
    @{ t = 'ChatGPT - Google Chrome';                                    e = 'chatgpt_web' }
    @{ t = 'Telemetria de IA ' + [char]0x00B7 + ' harpix - Google Chrome'; e = $null }
    @{ t = 'fac_usage_event | Table Editor | Supabase - Google Chrome';  e = $null }
    @{ t = '';                                                          e = $null }
)

$fail = 0
foreach ($c in $cases) {
    $got = Get-Tool $c.t
    $ok = ($got -eq $c.e)
    if (-not $ok) { $fail++ }
    '{0,-5} esperado={1,-16} obtido={2,-16} titulo="{3}"' -f $(if ($ok) { 'PASS' } else { 'FALHA' }), "$($c.e)", "$got", $c.t
}
''
"total=$($cases.Count) falhas=$fail"
if ($fail -gt 0) { exit 1 }
