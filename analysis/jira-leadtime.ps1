# hpx-telemetry / CA-07: LEAD TIME e RETRABALHO por pessoa, antes x depois da
# adocao de IA. Complemento do adocao-git.ps1, que ja produz a DATA DE ADOCAO.
#
# Por que o Jira e nao so o git: commit por semana mede atividade, nao entrega.
# Lead time (quanto tempo um item leva do inicio ate concluir) e retrabalho
# (item que voltou depois de concluido) sao as duas coisas que a lideranca de
# fato pergunta, e nenhuma das duas esta no git.
#
# POR QUE UM SCRIPT E NAO O CONECTOR: o conector de Jira devolve ~2,5 KB por
# item mesmo pedindo dois campos. Puxar milhares de itens por ali nao para em
# pe. A API REST devolve so o que se pede, entao o levantamento inteiro cabe em
# poucas chamadas.
#
# CREDENCIAL: token de API do Atlassian (id.atlassian.com/manage-profile/security/api-tokens).
# O token NAO fica em arquivo nenhum: entra por parametro e vive so na memoria
# do processo. Use -Token (SecureString) ou a variavel de ambiente JIRA_TOKEN.
#
# Uso:
#   $env:JIRA_TOKEN = '<token>'
#   .\jira-leadtime.ps1 -Email guilherme.santos@harpix.com.br
#
# Saida (pasta ./saida):
#   jira-itens.csv      linha por item: chave, pessoa, tipo, criado, concluido,
#                       dias de lead time, reaberturas
#   jira-leadtime.csv   linha por pessoa: mediana antes x depois e retrabalho
#
# LIMITES, os mesmos do irmao git e mais dois proprios:
#   - lead time aqui e criado -> concluido. Inclui fila e espera, nao so
#     execucao. Comparar entre pessoas exige cuidado; comparar a MESMA pessoa
#     antes e depois e mais honesto, que e o que este script faz.
#   - quantidade de item depende de como o time quebra tarefa, e isso muda com
#     o tempo. Mesmo erro que a v1 do git cometeu com commits: por isso aqui a
#     leitura principal e a MEDIANA de lead time, nao a contagem.
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [securestring]$Token,
    [string]$Site           = 'harpix.atlassian.net',
    [string]$OutDir         = (Join-Path $PSScriptRoot 'saida'),
    [string]$AdocaoCsv      = (Join-Path $PSScriptRoot 'saida\adocao.csv'),
    [datetime]$Desde        = '2026-01-01',
    # Piso POR LADO, mesma logica do adocao-git.ps1: sem isso uma pessoa com
    # tres itens no "antes" produz um delta enorme e sem significado.
    [int]$MinPorLado        = 10,
    # Pessoas fora da leitura, com motivo. Desligamento explica curva melhor
    # que qualquer ferramenta, entao manter no grafico seria desonesto.
    [string[]]$Excluir      = @('rafael.coimbra@harpix.com.br', 'hugo.ribeiro@harpix.com.br'),
    # Retrabalho exige o historico de cada item, que multiplica o volume da
    # resposta. Desligado por padrao.
    [switch]$ComRetrabalho
)

$ErrorActionPreference = 'Stop'

# Status que contam como "concluido" pra detectar reabertura. Varia por projeto,
# entao e lista e nao valor unico.
$StatusConcluido = @('concluído', 'concluido', 'done', 'fechado', 'resolvido', 'finalizado')

if (-not $Token) {
    if ($env:JIRA_TOKEN) {
        $Token = ConvertTo-SecureString $env:JIRA_TOKEN -AsPlainText -Force
    } else {
        $Token = Read-Host 'Token de API do Atlassian' -AsSecureString
    }
}

function Get-TokenPlano([securestring]$s) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$pares = "${Email}:$(Get-TokenPlano $Token)"
$auth  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pares))
$pares = $null
$headers = @{ Authorization = "Basic $auth"; Accept = 'application/json' }

# ---------------------------------------------------------------- adocao ----
if (-not (Test-Path $AdocaoCsv)) {
    throw "nao achei $AdocaoCsv. Rode o adocao-git.ps1 antes: ele produz a data de adocao."
}
$adocao = @{}
foreach ($linha in (Import-Csv $AdocaoCsv)) {
    if ($linha.data_adocao) {
        $adocao[$linha.email.ToLowerInvariant()] = [datetime]::Parse(
            $linha.data_adocao, [Globalization.CultureInfo]::InvariantCulture)
    }
}
if ($adocao.Count -eq 0) { throw 'nenhuma data de adocao no csv; nada a comparar.' }
Write-Host ("adocao conhecida de {0} pessoa(s)" -f $adocao.Count) -ForegroundColor DarkYellow

# ----------------------------------------------------------------- busca ----
$jql = 'resolutiondate >= "{0}" AND assignee IS NOT EMPTY ORDER BY resolutiondate ASC' -f `
       $Desde.ToString('yyyy-MM-dd')
$campos = 'created,resolutiondate,assignee,issuetype,project,status'
$expand = if ($ComRetrabalho) { '&expand=changelog' } else { '' }

$itens = New-Object System.Collections.Generic.List[object]
$token = $null
$pagina = 0
do {
    $uri = 'https://{0}/rest/api/3/search/jql?jql={1}&fields={2}&maxResults=100{3}' -f `
           $Site, [uri]::EscapeDataString($jql), $campos, $expand
    if ($token) { $uri += "&nextPageToken=$([uri]::EscapeDataString($token))" }

    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60
    $pagina++
    Write-Host ("  pagina {0}: {1} item(ns)" -f $pagina, @($resp.issues).Count)

    foreach ($it in $resp.issues) {
        $emailPessoa = "$($it.fields.assignee.emailAddress)".ToLowerInvariant()
        # Sem email no assignee nao da pra cruzar com o git. Some em silencio
        # seria o pior caso, entao registra com email vazio e some depois com
        # motivo visivel.
        $criado    = [datetime]::Parse($it.fields.created, [Globalization.CultureInfo]::InvariantCulture)
        $concluido = [datetime]::Parse($it.fields.resolutiondate, [Globalization.CultureInfo]::InvariantCulture)

        $reaberturas = 0
        if ($ComRetrabalho -and $it.changelog) {
            $entradasDone = 0
            foreach ($h in $it.changelog.histories) {
                foreach ($item in $h.items) {
                    if ($item.field -eq 'status' -and
                        $StatusConcluido -contains "$($item.toString)".ToLowerInvariant()) {
                        $entradasDone++
                    }
                }
            }
            # entrou em "concluido" mais de uma vez = voltou pelo menos uma vez
            $reaberturas = [Math]::Max(0, $entradasDone - 1)
        }

        $itens.Add([pscustomobject]@{
            chave       = $it.key
            projeto     = $it.fields.project.key
            tipo        = $it.fields.issuetype.name
            subtarefa   = [bool]$it.fields.issuetype.subtask
            pessoa      = $it.fields.assignee.displayName
            email       = $emailPessoa
            criado      = $criado
            concluido   = $concluido
            dias        = [Math]::Round(($concluido - $criado).TotalDays, 2)
            reaberturas = $reaberturas
        })
    }
    $token = $resp.nextPageToken
} while ($token)

Write-Host ("total: {0} item(ns) concluido(s) desde {1}" -f $itens.Count, $Desde.ToString('dd/MM/yyyy')) -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$itens | Export-Csv (Join-Path $OutDir 'jira-itens.csv') -NoTypeInformation -Encoding UTF8

# --------------------------------------------------------------- leitura ----
function Get-Mediana([double[]]$v) {
    if ($v.Count -eq 0) { return $null }
    $o = $v | Sort-Object
    $m = [int][Math]::Floor($o.Count / 2)
    if ($o.Count % 2) { return [Math]::Round($o[$m], 2) }
    return [Math]::Round((($o[$m - 1] + $o[$m]) / 2), 2)
}

$linhas = foreach ($email in ($itens.email | Where-Object { $_ } | Sort-Object -Unique)) {
    $meus = @($itens | Where-Object { $_.email -eq $email })
    $nome = $meus[0].pessoa

    if ($Excluir -contains $email) {
        [pscustomobject]@{ nome = $nome; email = $email; total = $meus.Count
            comparavel = 'nao'; motivo_fora = 'fora da leitura por decisao (desligamento)' }
        continue
    }
    if (-not $adocao.ContainsKey($email)) {
        [pscustomobject]@{ nome = $nome; email = $email; total = $meus.Count
            comparavel = 'nao'; motivo_fora = 'sem data de adocao no git (grupo de controle)' }
        continue
    }

    $dataAdocao = $adocao[$email]
    $antes  = @($meus | Where-Object { $_.concluido -lt $dataAdocao })
    $depois = @($meus | Where-Object { $_.concluido -ge $dataAdocao })

    if ($antes.Count -lt $MinPorLado -or $depois.Count -lt $MinPorLado) {
        [pscustomobject]@{ nome = $nome; email = $email; total = $meus.Count
            comparavel = 'nao'
            motivo_fora = "amostra por lado abaixo de $MinPorLado (antes=$($antes.Count) depois=$($depois.Count))" }
        continue
    }

    $medAntes  = Get-Mediana ([double[]]($antes.dias))
    $medDepois = Get-Mediana ([double[]]($depois.dias))

    [pscustomobject]@{
        nome                = $nome
        email               = $email
        total               = $meus.Count
        comparavel          = 'sim'
        motivo_fora         = ''
        data_adocao         = $dataAdocao.ToString('yyyy-MM-dd')
        itens_antes         = $antes.Count
        itens_depois        = $depois.Count
        leadtime_mediano_antes  = $medAntes
        leadtime_mediano_depois = $medDepois
        delta_leadtime_pct  = if ($medAntes) { [Math]::Round(100 * ($medDepois - $medAntes) / $medAntes, 1) } else { $null }
        retrabalho_antes_pct  = if ($ComRetrabalho) { [Math]::Round(100 * (@($antes  | Where-Object { $_.reaberturas -gt 0 }).Count) / $antes.Count, 1) } else { $null }
        retrabalho_depois_pct = if ($ComRetrabalho) { [Math]::Round(100 * (@($depois | Where-Object { $_.reaberturas -gt 0 }).Count) / $depois.Count, 1) } else { $null }
    }
}

$linhas | Export-Csv (Join-Path $OutDir 'jira-leadtime.csv') -NoTypeInformation -Encoding UTF8

$linhas | Where-Object { $_.comparavel -eq 'sim' } |
    Format-Table nome, itens_antes, itens_depois, leadtime_mediano_antes,
                 leadtime_mediano_depois, delta_leadtime_pct -AutoSize |
    Out-String -Width 200 | Write-Host

$fora = @($linhas | Where-Object { $_.comparavel -eq 'nao' })
if ($fora.Count) {
    Write-Host "fora da comparacao (motivo visivel, nunca sumico silencioso):" -ForegroundColor Yellow
    $fora | Format-Table nome, total, motivo_fora -AutoSize | Out-String -Width 200 | Write-Host
}

Write-Host "csv em $OutDir" -ForegroundColor Green
Write-Host "LEMBRETE: delta de lead time NAO e efeito causal. Falta controle de" -ForegroundColor DarkYellow
Write-Host "mudanca de projeto, ferias e troca de funcao, e a amostra e pequena." -ForegroundColor DarkYellow
