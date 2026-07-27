# hpx-telemetry / CA-07: data de ADOCAO de IA por pessoa e ritmo de entrega
# antes x depois, tudo a partir do git.
#
# Ideia: todo commit assistido carrega o trailer "Co-Authored-By: Claude ...".
# O primeiro commit com esse trailer marca a adocao daquela pessoa, com data
# exata, retroativa e auditavel, sem depender de console de administracao.
#
# POR QUE DUAS METRICAS (a licao da v1): medir so commits por semana engana.
# Com IA o commit tende a ficar MAIOR e menos frequente, entao queda no ritmo
# de commits pode significar o oposto do que parece. Por isso medimos tambem
# LINHAS por semana e o TAMANHO MEDIANO do commit. Se o ritmo cai e as linhas
# sobem, a leitura correta e "commit ficou maior", nao "entregou menos".
#
# Saida (pasta ./saida):
#   commits.csv  linha por commit: repo, sha, email, nome, data, linhas, flg_ai
#   adocao.csv   linha por pessoa: adocao e ritmo antes x depois
#
# LIMITES, para nao superinterpretar: contagem de commit e de linha nao mede
# valor entregue. Nao ha controle de mudanca de projeto, ferias ou troca de
# funcao. Isto e um levantamento descritivo que produz a DATA DE ADOCAO e
# indica se ha sinal, nao a analise causal.
param(
    [string[]]$RepoPaths,
    [string]$OutDir      = (Join-Path $PSScriptRoot 'saida'),
    [string]$MailmapPath = (Join-Path $PSScriptRoot 'harpix.mailmap'),
    [int]$MinCommits     = 5,
    # Piso POR LADO para a pessoa entrar na comparacao. Sem isso, quem tem um
    # unico commit gordo no "antes" (um import inicial, por exemplo) produz um
    # delta enorme e sem significado, que e justamente o numero que acaba
    # vazando para apresentacao.
    [int]$MinPorLado     = 10,
    [int]$MinSemanasLado = 3
)

$ErrorActionPreference = 'Stop'

# Autores que NAO sao pessoas do time. Bot e conta de servico distorcem
# qualquer media (o devin sozinho tem 300+ commits nos repos principais).
$ExcluirAutor = @(
    'devin-ai-integration',      # agente de IA que commita direto no repo
    '\[bot\]',                   # qualquer bot do GitHub
    'noreply@anthropic\.com',    # commits com autoria direta do Claude
    'gcpharpix@harpix\.com\.br'  # conta de servico
) -join '|'

# Repositorios que nao sao codigo da harpix (clone de terceiro polui o dado)
$ExcluirRepo = '^(litellm|skills)$'

# Arquivos que inflam contagem de linha sem representar trabalho humano
$ExcluirArquivo = @(
    ':(exclude,glob)**/package-lock.json'
    ':(exclude,glob)**/pnpm-lock.yaml'
    ':(exclude,glob)**/yarn.lock'
    ':(exclude,glob)**/*.min.js'
    ':(exclude,glob)**/*.min.css'
    ':(exclude,glob)**/dist/**'
    ':(exclude,glob)**/build/**'
    ':(exclude,glob)**/node_modules/**'
    ':(exclude,glob)**/*.Designer.cs'
    ':(exclude,glob)**/migrations/**'
)

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
if (-not (Test-Path $MailmapPath)) { throw "Mailmap nao encontrado em $MailmapPath" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
"Repositorios encontrados: $($RepoPaths.Count)   mailmap: $(Split-Path $MailmapPath -Leaf)"

# 2) extrai commits
# %aE e %aN (maiusculos) aplicam o mailmap; %ae/%an dariam o email cru.
# --numstat traz linhas adicionadas e removidas por arquivo.
$RS = [char]0x1e; $US = [char]0x1f
$formato = "%x1e%H%x1f%aE%x1f%aN%x1f%aI%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x1d)"

$commits = New-Object System.Collections.Generic.List[object]
$ignorados = 0

foreach ($repo in $RepoPaths) {
    $nomeRepo = Split-Path $repo -Leaf
    if ($nomeRepo -match $ExcluirRepo) { "  [fora]    $nomeRepo (nao e codigo da harpix)"; continue }

    try {
        $args = @('-c', "mailmap.file=$MailmapPath", 'log', '--all', '--no-merges',
                  '--numstat', "--pretty=format:$formato", '--') + $ExcluirArquivo
        $bruto = & git -C $repo @args 2>$null
    } catch { "  [pulado]  $nomeRepo (git falhou)"; continue }
    if (-not $bruto) { "  [vazio]   $nomeRepo"; continue }

    $n = 0
    foreach ($rec in (($bruto -join "`n") -split $RS)) {
        if (-not $rec.Trim()) { continue }
        $linhasRec = $rec -split "`n"
        $c = $linhasRec[0] -split $US
        if ($c.Count -lt 4) { continue }

        if ($c[1] -match $ExcluirAutor -or $c[2] -match $ExcluirAutor) { $ignorados++; continue }

        # soma linhas tocadas; binario vem como "-" e e ignorado
        $linhas = 0
        for ($i = 1; $i -lt $linhasRec.Count; $i++) {
            $p = $linhasRec[$i] -split "`t"
            if ($p.Count -lt 3) { continue }
            if ($p[0] -eq '-' -or $p[1] -eq '-') { continue }
            $linhas += ([int]$p[0] + [int]$p[1])
        }

        $trailers = if ($c.Count -ge 5) { $c[4] } else { '' }
        $commits.Add([pscustomobject]@{
            repo   = $nomeRepo
            sha    = $c[0]
            email  = $c[1].ToLowerInvariant()
            nome   = $c[2]
            data   = [datetime]::Parse($c[3], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            linhas = $linhas
            flg_ai = [bool]($trailers -match 'claude|anthropic')
        })
        $n++
    }
    "  [ok]      $nomeRepo  commits=$n"
}

if ($commits.Count -eq 0) { throw 'Nenhum commit lido.' }
"Commits lidos: $($commits.Count)   ignorados por bot ou conta de servico: $ignorados"

$commits | Sort-Object data |
    Select-Object repo, sha, email, nome, @{n='data';e={$_.data.ToString('s')}}, linhas, flg_ai |
    Export-Csv (Join-Path $OutDir 'commits.csv') -NoTypeInformation -Encoding UTF8

# semana identificada pelo domingo que a inicia. Nao usar Get-Date -UFormat %V,
# o suporte a %V e instavel no PowerShell 5.1 e falha calado.
function Get-ChaveSemana([datetime]$d) { $d.Date.AddDays(-[int]$d.DayOfWeek).ToString('yyyy-MM-dd') }
function Get-Mediana($valores) {
    $v = @($valores | Sort-Object)
    if ($v.Count -eq 0) { return 0 }
    if ($v.Count % 2) { return $v[[int](($v.Count - 1) / 2)] }
    return [math]::Round((($v[$v.Count/2 - 1]) + ($v[$v.Count/2])) / 2, 1)
}
function Get-Ritmo($conjunto) {
    $c = @($conjunto)
    if ($c.Count -eq 0) { return $null }
    $semanas = @($c | ForEach-Object { Get-ChaveSemana $_.data } | Sort-Object -Unique).Count
    if ($semanas -eq 0) { return $null }
    return [pscustomobject]@{
        commits  = $c.Count
        semanas  = $semanas
        porSem   = [math]::Round($c.Count / $semanas, 2)
        linhasSem= [math]::Round((($c | Measure-Object linhas -Sum).Sum) / $semanas, 0)
        tamMed   = Get-Mediana ($c | Select-Object -ExpandProperty linhas)
    }
}
function Get-Delta($antes, $depois) {
    if (-not $antes -or -not $depois -or $antes -eq 0) { return $null }
    return [math]::Round((($depois / $antes) - 1) * 100, 1)
}

# 3) agrega por pessoa
$linhasSaida = New-Object System.Collections.Generic.List[object]
foreach ($g in ($commits | Group-Object email)) {
    $meus = @($g.Group | Sort-Object data)
    if ($meus.Count -lt $MinCommits) { continue }

    $comIA  = @($meus | Where-Object { $_.flg_ai })
    $adocao = if ($comIA.Count -gt 0) { $comIA[0].data } else { $null }

    if ($adocao) {
        $a = Get-Ritmo (@($meus | Where-Object { $_.data -lt  $adocao }))
        $d = Get-Ritmo (@($meus | Where-Object { $_.data -ge $adocao }))
    } else {
        $a = Get-Ritmo $meus; $d = $null
    }

    # comparavel exige amostra minima NOS DOIS LADOS
    $ladoOk = { param($x) $x -and $x.commits -ge $MinPorLado -and $x.semanas -ge $MinSemanasLado }
    $comparavel = ($adocao -and (& $ladoOk $a) -and (& $ladoOk $d))
    $motivo = ''
    if ($adocao -and -not $comparavel) {
        if (-not (& $ladoOk $a)) { $motivo = 'historico anterior insuficiente' }
        else                     { $motivo = 'periodo posterior ainda curto' }
    }

    $linhasSaida.Add([pscustomobject]@{
        nome                = $meus[-1].nome
        email               = $g.Name
        total_commits       = $meus.Count
        data_adocao         = if ($adocao) { $adocao.ToString('yyyy-MM-dd') } else { '' }
        comparavel          = if ($comparavel) { 'sim' } else { 'nao' }
        motivo_fora         = $motivo
        tem_antes           = if ($a) { 'sim' } else { 'nao' }
        commits_antes       = if ($a) { $a.commits } else { '' }
        commits_depois      = if ($d) { $d.commits } else { '' }
        commits_sem_antes   = if ($a) { $a.porSem } else { '' }
        commits_sem_depois  = if ($d) { $d.porSem } else { '' }
        linhas_sem_antes    = if ($a) { $a.linhasSem } else { '' }
        linhas_sem_depois   = if ($d) { $d.linhasSem } else { '' }
        tam_mediano_antes   = if ($a) { $a.tamMed } else { '' }
        tam_mediano_depois  = if ($d) { $d.tamMed } else { '' }
        delta_commits_pct   = if ($a -and $d) { Get-Delta $a.porSem    $d.porSem }    else { '' }
        delta_linhas_pct    = if ($a -and $d) { Get-Delta $a.linhasSem $d.linhasSem } else { '' }
    })
}

$linhasSaida = @($linhasSaida | Sort-Object { if ($_.data_adocao) { 0 } else { 1 } }, data_adocao)
$linhasSaida | Export-Csv (Join-Path $OutDir 'adocao.csv') -NoTypeInformation -Encoding UTF8

$comparaveis = @($linhasSaida | Where-Object { $_.comparavel -eq 'sim' })
''
'=== COMPARAVEIS (adotaram E tem historico anterior) ==='
$comparaveis | Format-Table nome, data_adocao, commits_sem_antes, commits_sem_depois, delta_commits_pct,
                            linhas_sem_antes, linhas_sem_depois, delta_linhas_pct -AutoSize
''
'=== ADOTARAM MAS FORA DA COMPARACAO (amostra insuficiente) ==='
$linhasSaida | Where-Object { $_.data_adocao -and $_.comparavel -eq 'nao' } |
    Format-Table nome, data_adocao, commits_antes, commits_depois, motivo_fora -AutoSize
''
'=== AINDA NAO ADOTARAM (grupo de controle, nao descarte) ==='
$linhasSaida | Where-Object { -not $_.data_adocao } |
    Format-Table nome, total_commits, commits_sem_antes, linhas_sem_antes -AutoSize
''
"comparaveis=$($comparaveis.Count)  adotantes=$(@($linhasSaida | Where-Object { $_.data_adocao }).Count)  controle=$(@($linhasSaida | Where-Object { -not $_.data_adocao }).Count)"
'LEITURA: se commits por semana CAI e linhas por semana SOBE, o commit ficou'
'maior. Nao ler a queda de commits como queda de entrega.'
"Saida em: $OutDir"
