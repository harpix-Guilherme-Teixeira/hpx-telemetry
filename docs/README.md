# Documentação do pack

`como-funciona.html` e a fonte do PDF entregue ao time.

Gerar o PDF (Chrome headless, perfil separado porque o Chrome do dia a dia costuma
estar aberto e trava o modo headless):

    & "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" --headless=new --disable-gpu `
      --no-first-run --user-data-dir="$env:TEMP\hpx-doc-prof" --virtual-time-budget=15000 `
      --no-pdf-header-footer --print-to-pdf="$HOME\Downloads\hpx-telemetry-como-funciona.pdf" `
      "file:///$($PWD.Path -replace '\\','/')/docs/como-funciona.html"

Mudou o funcionamento do pack? Atualizar TRES coisas: este HTML, o board de
arquitetura e o comunicado de privacidade do time.
