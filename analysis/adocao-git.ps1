# hpx-telemetry / CA-07: levanta a DATA DE ADOCAO de IA por pessoa a partir do git.
#
# Ideia: todo commit assistido carrega o trailer "Co-Authored-By: Claude ...".
# Logo, o primeiro commit com esse trailer marca a adocao daquela pessoa, com
# data exata, de forma retroativa e auditavel, sem depender de console de
# administracao nem de plano. Cobre inclusive o periodo anterior a telemetria.
#
# Saida (pasta ./saida):
#   commits.csv  linha por commit: repo, sha, email, nome, data, flg_ai
#   adocao.csv   linha por pessoa: data de adocao e ritmo antes x depois
#
# ATENCAO na leitura: nao comparar contagem bruta antes x depois. As janelas tem
# tamanhos diferentes (quem adotou em maio tem 2 meses de "depois" e anos de
# "antes"). Por isso a coluna que importa e commits por SEMANA ATIVA, nao o total.
#
# Isto e um levantamento descritivo, nao a analise causal. Serve para: (1) obter
# a data de adocao por pessoa, (2) ver se ha sinal que justifique a analise, e
# (3) expor as pessoas com mais de um email, que precisam ser unificadas antes.
param(
    [string[]]$RepoPaths,
    [string]$OutDir = (Join-Path $PSScriptRoot 'saida'),
    [int]$MinCommits = 5
)

$ErrorActionPreference = 'Stop'

# 1) descobre repositorios se nao vier lista
if (-not $RepoPaths -or $RepoPaths.Count -eq 0) {
    $raizes = @("$HOME\Projects", "$HOME\_research", "$HOME\Documents")
    $RepoPaths = @()
    foreach ($raiz in $raizes) {
        if (-not (Test-Path $raiz)) { continue }
        $RepoPaths += @(Get-ChildItem -Path $raiz -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
            ForEach-Object { $_.FullName })
    }
}
if ($RepoPaths.Count -eq 0) { throw 'Nenhum repositorio git encontrado. Passe -RepoPaths.' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
"Repositorios: $($RepoPaths.Count)"

# 2) extrai commits de cada repo
# Separadores de controle evitam qualquer problema de aspas ou virgula na mensagem.
# %x1e separa commit, %x1f separa campo, %x1d separa multiplos trailers.
$RS = [char]0x1e; $US = [char]0x1f
$formato = "%x1e%H%x1f%ae%x1f%an%x1f%aI%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x1d)"

$commits = New-Object System.Collections.Generic.List[object]
foreach ($repo in $RepoPaths) {
    $nome = Split-Path $repo -Leaf
    try {
        $bruto = & git -C $repo log --all --no-merges --pretty=format:$formato 2>$null
    } catch {
        "  [pulado] $nome (git falhou)"
        continue
    }
    if (-not $bruto) { "  [vazio]   $nome"; continue }

    $n = 0
    foreach ($rec in (($bruto -join "`n") -split $RS)) {
        if (-not $rec.Trim()) { continue }
        $c = $rec -split $US
        if ($c.Count -lt 4) { continue }
        $trailers = if ($c.Count -ge 5) { $c[4] } else { '' }
        $commits.Add([pscustomobject]@{
            repo   = $nome
            sha    = $c[0]
            email  = $c[1].ToLowerInvariant()
            nome   = $c[2]
            data   = [datetime]::Parse($c[3], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            flg_ai = [bool]($trailers -match 'claude|anthropic')
        })
        $n++
    }
    "  [ok]      $nome  commits=$n"
}

if ($commits.Count -eq 0) { throw 'Nenhum commit lido.' }

# Chave de semana. Nao usar Get-Date -UFormat %V: o suporte a %V e instavel no
# PowerShell 5.1. Aqui a semana e identificada pela data do domingo que a inicia,
# calculo puro de data, sem depender de calendario nem de cultura.
function Get-ChaveSemana([datetime]$d) {
    return $d.Date.AddDays(-[int]$d.DayOfWeek).ToString('yyyy-MM-dd')
}
$commits | Sort-Object data |
    Select-Object repo, sha, email, nome, @{n='data';e={$_.data.ToString('s')}}, flg_ai |
    Export-Csv (Join-Path $OutDir 'commits.csv') -NoTypeInformation -Encoding UTF8

# 3) agrega por pessoa
$hoje = (Get-Date).ToUniversalTime()
$linhas = New-Object System.Collections.Generic.List[object]

foreach ($g in ($commits | Group-Object email)) {
    $meus = @($g.Group | Sort-Object data)
    if ($meus.Count -lt $MinCommits) { continue }

    $comIA = @($meus | Where-Object { $_.flg_ai })
    $adocao = if ($comIA.Count -gt 0) { $comIA[0].data } else { $null }

    if ($adocao) {
        $antes  = @($meus | Where-Object { $_.data -lt $adocao })
        $depois = @($meus | Where-Object { $_.data -ge $adocao })
        # semana ATIVA = semana em que a pessoa commitou. Evita inflar o "antes"
        # de quem tem historico antigo com meses parados.
        $semAntes  = @($antes  | ForEach-Object { Get-ChaveSemana $_.data } | Sort-Object -Unique).Count
        $semDepois = @($depois | ForEach-Object { Get-ChaveSemana $_.data } | Sort-Object -Unique).Count
    } else {
        $antes = $meus; $depois = @()
        $semAntes = @($antes | ForEach-Object { Get-ChaveSemana $_.data } | Sort-Object -Unique).Count
        $semDepois = 0
    }

    $ritmoAntes  = if ($semAntes  -gt 0) { [math]::Round($antes.Count  / $semAntes,  2) } else { $null }
    $ritmoDepois = if ($semDepois -gt 0) { [math]::Round($depois.Count / $semDepois, 2) } else { $null }
    $delta = if ($ritmoAntes -and $ritmoDepois) { [math]::Round((($ritmoDepois / $ritmoAntes) - 1) * 100, 1) } else { $null }

    $linhas.Add([pscustomobject]@{
        email             = $g.Name
        nome              = $meus[-1].nome
        repos             = @($meus | Select-Object -ExpandProperty repo -Unique).Count
        total_commits     = $meus.Count
        primeiro_commit   = $meus[0].data.ToString('yyyy-MM-dd')
        data_adocao       = if ($adocao) { $adocao.ToString('yyyy-MM-dd') } else { '' }
        commits_com_ia    = $comIA.Count
        pct_com_ia        = if ($depois.Count -gt 0) { [math]::Round($comIA.Count * 100 / $depois.Count, 1) } else { 0 }
        semanas_antes     = $semAntes
        semanas_depois    = $semDepois
        ritmo_antes       = $ritmoAntes
        ritmo_depois      = $ritmoDepois
        delta_pct         = $delta
    })
}

$linhas = @($linhas | Sort-Object { if ($_.data_adocao) { 0 } else { 1 } }, data_adocao)
$linhas | Export-Csv (Join-Path $OutDir 'adocao.csv') -NoTypeInformation -Encoding UTF8

''
'=== ADOCAO POR PESSOA (ritmo = commits por semana ativa) ==='
$linhas | Format-Table email, total_commits, data_adocao, ritmo_antes, ritmo_depois, delta_pct -AutoSize

''
"adotantes=$(@($linhas | Where-Object { $_.data_adocao }).Count)  nao_adotantes=$(@($linhas | Where-Object { -not $_.data_adocao }).Count)"
"Os nao adotantes sao o GRUPO DE CONTROLE da analise, nao descarte."
''
'ATENCAO: confira a lista de emails acima. Pessoa com mais de um email (pessoal e'
'corporativo) aparece dividida e precisa ser unificada antes de qualquer leitura.'
"Saida em: $OutDir"
