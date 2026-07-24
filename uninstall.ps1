# hpx-telemetry: desinstalador. Avisa o banco, remove hooks, tarefas e pasta local.
$ErrorActionPreference = 'SilentlyContinue'

# 0. Avisa o banco que esta desinstalando (antes de apagar o config)
try {
    $configPath = Join-Path $env:USERPROFILE '.hpx-telemetry\config.json'
    if (Test-Path $configPath) {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        $payload = @{
            nam_user = $c.nam_user; nam_email = $c.nam_email; nam_machine = $c.nam_machine
            nam_source = 'claude_code'; nam_event_type = 'uninstall'
            jsn_meta = @{ str_version = $c.version }
        }
        $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 5))
        Invoke-RestMethod -Method Post -Uri "$($c.endpoint)/rest/v1/fac_usage_event" `
            -Headers @{ apikey = $c.api_key; Prefer = 'return=minimal' } `
            -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 8 | Out-Null
    }
} catch {}

# 1. Tarefas agendadas
schtasks /Delete /F /TN 'hpx-telemetry-watcher' 2>$null | Out-Null
schtasks /Delete /F /TN 'hpx-telemetry-updater' 2>$null | Out-Null

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
