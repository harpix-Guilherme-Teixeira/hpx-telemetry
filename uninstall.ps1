# hpx-telemetry: desinstalador. Remove hooks, tarefa agendada e pasta local.
$ErrorActionPreference = 'SilentlyContinue'

$TaskName = 'hpx-telemetry-watcher'

# 1. Tarefa agendada
schtasks /Delete /F /TN $TaskName 2>$null | Out-Null

# 2. Hooks no settings.json
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties['hooks']) {
            foreach ($evt in @($settings.hooks.PSObject.Properties.Name)) {
                $kept = @($settings.hooks.$evt) | Where-Object {
                    -not (@($_.hooks).command -match 'hpx-telemetry')
                }
                if (@($kept).Count -gt 0) {
                    $settings.hooks.$evt = @($kept)
                } else {
                    $settings.hooks.PSObject.Properties.Remove($evt)
                }
            }
        }
        $json = $settings | ConvertTo-Json -Depth 64
        [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host 'Hooks removidos do settings.json' -ForegroundColor Green
    } catch {
        Write-Host 'Nao consegui editar o settings.json, remova os hooks hpx-telemetry manualmente.' -ForegroundColor Yellow
    }
}

# 3. Pasta local
Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE '.hpx-telemetry')

Write-Host 'hpx-telemetry desinstalado.' -ForegroundColor Green
