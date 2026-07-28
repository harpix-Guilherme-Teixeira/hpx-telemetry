# Testa a normalizacao de identidade do install.ps1.
# Le a regra DIRETO do instalador que vai pro pack, pra teste e producao nao
# poderem divergir (mesmo desenho do test-titles.ps1).
#
# Roda: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-identidade.ps1

$ErrorActionPreference = 'Stop'

$instalador = Join-Path $PSScriptRoot '..\install.ps1'
$src = Get-Content $instalador -Raw

if ($src -notmatch "(?m)^\s*\`$Name -match '(\^\(version[^']+)'") {
    throw 'nao achei a lista de nomes reservados no install.ps1'
}
$Reservado = $Matches[1]
Write-Host "regra em teste: $Reservado`n"

function Resolve-Identidade($nome, $email) {
    $nome = ($nome -replace '\s+', ' ').Trim()
    $email = $email.Trim().ToLowerInvariant()
    if ($nome.Length -lt 2 -or $nome -match '^[-/]' -or $nome -match $Reservado) {
        $nome = ((($email -split '@')[0] -split '[._-]+' |
            Where-Object { $_ } |
            ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ' ')
    }
    return $nome
}

$casos = @(
    # o bug real: "npx hpx-telemetry version" gravou "version" como nome
    @{ nome = 'version';           email = 'sergio.junior@harpix.com.br'; esperado = 'Sergio Junior' }
    @{ nome = '--help';            email = 'sergio.junior@harpix.com.br'; esperado = 'Sergio Junior' }
    @{ nome = '-Silent';           email = 'yuri.lacerda@harpix.com.br';  esperado = 'Yuri Lacerda' }
    @{ nome = 'true';              email = 'yuri.lacerda@harpix.com.br';  esperado = 'Yuri Lacerda' }
    # espaco sobrando duplicava a pessoa no relatorio
    @{ nome = 'Sergio  ';          email = 'sergio.junior@harpix.com.br'; esperado = 'Sergio' }
    @{ nome = ' Sergio   Alves ';  email = 'sergio.junior@harpix.com.br'; esperado = 'Sergio Alves' }
    # nome legitimo passa intacto, inclusive quando nao bate com o email
    @{ nome = 'Guilherme Teixeira'; email = 'guilherme.santos@harpix.com.br'; esperado = 'Guilherme Teixeira' }
    @{ nome = 'Ana';               email = 'ana@harpix.com.br';           esperado = 'Ana' }
)

$falhas = 0
foreach ($c in $casos) {
    $obtido = Resolve-Identidade $c.nome $c.email
    $ok = ($obtido -ceq $c.esperado)
    if (-not $ok) { $falhas++ }
    '{0}  esperado="{1,-20}" obtido="{2,-20}" entrada="{3}"' -f `
        $(if ($ok) { 'PASS' } else { 'FALHA' }), $c.esperado, $obtido, $c.nome
}

"`ntotal=$($casos.Count) falhas=$falhas"
if ($falhas -gt 0) { exit 1 }
exit 0
