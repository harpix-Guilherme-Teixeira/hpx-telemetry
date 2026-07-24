' hpx-telemetry: lancador oculto.
' Roda um script PowerShell SEM criar janela (window style 0). Evita o flash de
' console que o Task Scheduler causa mesmo com -WindowStyle Hidden.
Set args = WScript.Arguments
If args.Count = 0 Then WScript.Quit
scriptPath = args(0)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
