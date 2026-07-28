# hpx-telemetry

Telemetria de uso de Claude e Claude Code na harpix. Registra **somente metadados** de uso num Supabase central, pra medir adoção e impacto de IA no time. Nenhum conteúdo de conversa sai da máquina.

Board de arquitetura: https://claude.ai/code/artifact/7c1008e7-f046-47c7-84dd-556933945d63

## Instalar

Um comando no PowerShell, sem admin e sem UAC:

```powershell
npx hpx-telemetry
```

Responde nome e email e pronto: a partir daí é só usar o Claude Code ou o Claude Desktop normalmente, nada mais precisa ser feito. A cobertura começa na hora (o instalador já dispara uma leitura do Desktop) e a próxima sessão de Claude Code já reporta sozinha.

Sem Node na máquina? Alternativa sem dependência:

```powershell
irm https://raw.githubusercontent.com/harpix-Guilherme-Teixeira/hpx-telemetry/develop/bootstrap.ps1 | iex
```

## Auto atualização

O instalador registra a tarefa diária `hpx-telemetry-updater`, que compara a versão local com a última publicada no npm. Quando publicamos um pack novo (`npm version patch && npm publish`), todas as máquinas se atualizam sozinhas em até um dia, reinstalando em modo silencioso com a identidade já cadastrada e registrando um evento `update` com a versão.

O instalador pergunta nome e email e faz o resto:

1. Registra colaborador e máquina em `rec_collaborator`
2. Copia os scripts pra `%USERPROFILE%\.hpx-telemetry` com `config.json`
3. Adiciona hooks no `~/.claude/settings.json` (`SessionStart`, `Stop`, `SessionEnd`), com backup do arquivo original em `settings.json.bak-hpx-telemetry`
4. Cria tarefa agendada de usuário `hpx-telemetry-watcher` (a cada 5 min) que detecta o Claude Desktop aberto e manda heartbeat

Pra remover tudo: `.\uninstall.ps1`

## O que é coletado

| Campo | Exemplo |
|---|---|
| nome, email, máquina, time | Guilherme, gui@harpix.com.br, NOTE-GUI, Dados |
| data e hora | via `now()` do banco |
| IP de origem | carimbado pelo servidor (trigger no banco), o cliente não envia |
| origem | claude_code ou claude_desktop |
| tipo do evento | session_start, response, session_end, heartbeat, install, update |
| sessão | id da sessão do Claude Code, ou derivada por gap no Desktop |
| projeto | só o nome da pasta do repo (leaf do cwd) |
| modelo e tokens | lidos do transcript local no evento Stop |

O que **nunca** é coletado: texto de prompt, texto de resposta, caminho completo de arquivos, conteúdo de repositório.

## Como o watcher decide que uma ferramenta está em uso

Duas superfícies, com regras diferentes e precisões diferentes. Vale conhecer antes de ler qualquer gráfico.

**App instalado.** Conta só quando existe **janela visível**. Processo residente não é uso: o `M365Copilot.exe` do Office Hub fica ligado o tempo todo sem janela e, até a 1.3.1, aparecia como uso em 100% das leituras de todo mundo. O preço da regra é o caminho oposto: app minimizado na bandeja deixa de contar.

**IA no navegador.** O watcher lê o título da janela, classifica na máquina e **descarta o texto**, só o rótulo (`claude_web`, `chatgpt_web`, ...) sai dali. Duas limitações que mudam a leitura:

- enxerga apenas a **aba em foco** no instante da leitura, então é **amostragem**, nunca tempo de uso. Uma pessoa com o Claude aberto o dia todo numa aba de fundo aparece perto de zero.
- a leitura acontece a cada 15 minutos, então uma conversa curta entre duas leituras não deixa rastro.

Ou seja: presença de `_web` é prova de uso, ausência não é prova de não uso.

## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-titles.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-identidade.ps1
```

Os dois leem as regras direto dos scripts que vão no pack, pra teste e produção não poderem divergir. Pra conferir a detecção na sua máquina sem gravar nada no banco:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\desktop-watcher.ps1 -DryRun
```

## Banco

Projeto Supabase `crugvrjtkorkrtrbrolv` ("Telemetria do uso de IA").

- `rec_collaborator`: cadastro de pessoa + máquina
- `fac_usage_event`: fato de eventos (padrão de nomenclatura harpix: `nam_`, `tms_`, `num_`, `str_`, `jsn_`)
- `vw_session`: sessões consolidadas (Code por `str_session`, Desktop por gap de 15 min entre heartbeats)
- `vw_daily_usage`: uso por pessoa/dia/fonte, base do dashboard

Segurança: RLS ligado nas duas tabelas. A chave publicável embarcada no pack só tem policy de **insert**, leitura só via service role ou dashboard do Supabase. Views com `security_invoker` pra não vazarem por cima do RLS.

## LGPD

Monitoramento de colaborador exige transparência: antes do rollout, comunicado formal ao time informando finalidade (medir adoção de IA), o que é coletado (tabela acima) e o que não é. O instalador reafirma isso na saída. Coleta é minimizada por design (metadados, sem conteúdo).
