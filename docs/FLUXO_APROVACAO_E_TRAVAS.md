# SGDE — Fluxo de Aprovação e Travas de Segurança

## 1. Papéis

| Papel | Uso principal |
|---|---|
| Administrador | Gestão de usuários/senhas/papéis. Não aprova despesas por padrão (mas a trava de autoaprovação vale para ele também, sem exceção). |
| Tesoureiro | Abre lotes, lança entradas, aprova saídas até R$ 500.000,00, liquida despesas. |
| Diretoria | Aprova saídas acima de R$ 500.000,00 (em conjunto com o Tesoureiro), aprova prebendas pastorais. |
| Secretaria | Cadastro de membros/departamentos, apoio operacional. |
| Pastor | Consulta suas próprias prebendas; não aprova despesas. |
| Auditor_Externo | Leitura ampla, incluindo `LOG_AUDITORIA` e verificação de integridade. Nunca escreve. |
| Contador | Leitura de balancete/relatórios; apoio à conciliação. |

## 2. Alçada de aprovação de despesas

Configurada na tabela `alcadas_aprovacao` (não hardcoded no código, para permitir ajuste futuro sem migration):

- **Até R$ 500.000,00**: aprovação de **1** usuário com papel `Tesoureiro`.
- **Acima de R$ 500.000,00**: aprovação de **2** usuários — `Tesoureiro` **e** `Diretoria` — ambos precisam registrar decisão `aprovado`.

A solicitação some para `aprovado` automaticamente (trigger `processar_decisao_solicitacao`) assim que todos os papéis exigidos pela faixa de valor tiverem decidido `aprovado`. Uma única decisão `reprovado` de qualquer aprovador já move o status para `reprovado`.

## 3. Travas implementadas no banco (não contornáveis via API)

| Trava | Onde | Mecanismo |
|---|---|---|
| Solicitante nunca aprova a própria solicitação | `aprovacoes` | Trigger `trg_aprovacoes_bloqueia_autoaprovacao` — vale para todos os papéis, sem exceção de Administrador. |
| Liquidação exige documento fiscal | `solicitacoes_pagamento` | Trigger `trg_liquidacao_exige_documento_fiscal` — bloqueia `UPDATE ... SET status = 'liquidado'` sem `documento_fiscal_id`. |
| Fechamento de lote exige dupla contagem convergente | `lotes_arrecadacao` / `contagem_lote` | Função `fechar_lote()` (SECURITY DEFINER) exige ≥ 2 contagens com `de_acordo = true` e soma dos lançamentos igual ao valor apurado (tolerância de R$ 0,01). |
| Divergência de contagem exige justificativa | `contagem_lote` | Trigger `trg_contagem_exige_justificativa`. |
| Dízimo identificado exige membro vinculado | `lancamentos_entrada` | `CHECK` constraint `chk_dizimo_precisa_membro`. |
| Recibo é imutável (nunca editado/apagado) | `recibos` | Triggers `trg_recibos_bloqueia_update` / `..._delete`. Numeração sequencial reinicia por ano civil, controlada por `recibos_contador_anual` (incremento atômico via `INSERT ... ON CONFLICT`). |
| Prebenda pastoral: quem solicita não aprova; só Diretoria/Administrador aprova | `prebendas_pastorais` | Trigger `trg_prebenda_bloqueia_autoaprovacao_e_papel`. |
| Dados bancários de fornecedor nunca expostos pela API pública | `fornecedores_dados_bancarios` | RLS bloqueia 100% do acesso direto (`using (false)`); único caminho é a função `SECURITY DEFINER` `obter_dados_bancarios_fornecedor()`, que checa papel e registra a consulta em auditoria. |
| Log de auditoria é append-only | `log_auditoria` | Triggers bloqueiam `UPDATE`/`DELETE`; gravação só via função `registrar_auditoria()`; tabela sem policy de `INSERT` direto. |
| Cadeia de hash detecta adulteração retroativa | `log_auditoria` | Cada linha grava `hash_registro = sha256(conteúdo + hash_registro_anterior)`. Função `verificar_integridade_auditoria()` percorre a cadeia e aponta a primeira linha cujo hash não confere. |
| Único Administrador ativo não pode ser removido/rebaixado | `usuarios` | Trigger `trg_usuarios_protege_admin` (trava operacional, evita lockout). |

## 4. Fluxo de Entradas (resumo operacional)

1. Abrir lote (`lotes_arrecadacao`, status `aberto`).
2. Pelo menos 2 usuários registram contagem independente (`contagem_lote`).
3. Lançar dízimos identificados (vinculados a membro) e ofertas agregadas (`lancamentos_entrada`).
4. Emitir recibo para lançamentos identificados (`emitir_recibo()` — numeração sequencial por ano).
5. Fechar o lote (`fechar_lote()`) — só permite quando dupla contagem bate e soma dos lançamentos confere.
6. Depósito bancário (fora do sistema) + upload do extrato.
7. Conciliação automática por valor+data (`conciliar_extrato_automatico()`); divergências ficam na fila `pendente` para tratamento manual.

## 5. Fluxo de Saídas (resumo operacional)

1. Solicitação de pagamento vinculada a um centro de custo.
2. Alçada de aprovação conforme valor (ver seção 2).
3. Upload de NF/RPA (`documentos_fiscais`) — obrigatório antes de liquidar.
4. Liquidação (`status = 'liquidado'`).
5. Prebenda pastoral segue tabela própria (`prebendas_pastorais`), com aprovação simples de Diretoria/Administrador registrada no sistema — não passa pelo fluxo de fornecedor comum nem exige NF.
6. Conciliação do débito no extrato com a solicitação liquidada.

## 6. Módulo de Conciliação (OFX/CSV)

`app/conciliacao.html` faz o parsing do arquivo inteiramente no navegador (`js/parsers.js`, sem lib externa): OFX é lido por regex (bancos brasileiros frequentemente geram SGML com tags não fechadas, então não tentamos exigir XML válido) e CSV espera colunas com "data"/"valor"/"desc" no cabeçalho, aceitando `;` ou `,` como separador e datas em `DD/MM/AAAA` ou `AAAA-MM-DD`. Cada movimento recebe um `hash_transacao` (SHA-256 client-side) derivado do id do extrato + referência do movimento, e a constraint `unique(extrato_id, hash_transacao)` no banco impede duplicidade em reimportação.

Após a importação, a função `conciliar_extrato_automatico()` roda automaticamente e casa por valor+data exato. O que não bate cai na fila manual, que sugere candidatos por proximidade de valor (±R$5) para o usuário vincular ou marcar como ignorado — a vinculação final grava `conciliado_por_id` e passa pela mesma trava de RLS/auditoria das demais tabelas financeiras.

## 7. Hardening de RLS aplicado após a primeira versão

Na revisão do MVP, encontrei e corrigi duas policies `for all` amplas demais:

- `prebendas_pastorais` tinha `using (app_papel_gestor() or app_papel() = 'Pastor')` num único `for all`, o que teoricamente permitiria a um Pastor fazer `DELETE` (o `using` vale para `DELETE` mesmo sem `with check`). Separado em policies por operação: `Pastor` só tem `SELECT`.
- Tabelas de execução financeira (`contas_bancarias`, `extratos_importados`, `movimentos_bancarios`, `aprovacoes`, `prebendas_pastorais`) usavam `app_papel_gestor()` para escrita, que inclui `Auditor_Externo` e `Contador` — papéis que deveriam ser só-leitura. Criada a função `app_papel_aprovador()` (Administrador/Tesoureiro/Diretoria) para gatear escrita nessas tabelas, mantendo `app_papel_gestor()` só para leitura ampla.

## 8. Pendências conhecidas para próximas iterações

- Índices/estratégia de paginação: não necessários no volume atual (~32 membros, ~32 lançamentos/mês); revisar se o volume crescer.
- Upload de NF/RPA no MVP é feito via URL informada manualmente; a integração direta com Supabase Storage (bucket + assinatura de URL) fica para a próxima iteração.
- MFA (`usuarios.mfa_ativo`) existe como coluna preparatória; a validação de segundo fator ainda não está implementada nesta versão do MVP.
- Alertas de estouro de orçamento por centro de custo (`centros_custo.orcamento_anual`) ainda não têm UI — hoje só o dado existe no schema.
- O parser de OFX cobre o formato mais comum (`STMTTRN`/`DTPOSTED`/`TRNAMT`/`FITID`); um extrato real do seu banco pode ter variações — vale testar com um arquivo de verdade antes de ir para produção.
