-- =====================================================================
-- SGDE — 0007: RLS — todo acesso passa por verificar_sessao(token)
-- antes, que popula app.usuario_id / app.papel na transação (via
-- set_config(..., true) — escopo local à transação, não vaza entre
-- requisições). As policies abaixo leem essas variáveis de sessão.
-- Não usamos Supabase Auth (auth.uid()) porque o padrão de autenticação
-- é o já validado nos outros sistemas (hash+salt próprio).
-- =====================================================================

create or replace function app_usuario_id() returns uuid
language sql stable as $$ select nullif(current_setting('app.usuario_id', true), '')::uuid $$;

create or replace function app_papel() returns text
language sql stable as $$ select nullif(current_setting('app.papel', true), '') $$;

-- Helper: papéis com acesso amplo de LEITURA financeira (inclui quem só audita/contabiliza)
create or replace function app_papel_gestor() returns boolean
language sql stable as $$
  select app_papel() in ('Administrador','Tesoureiro','Diretoria','Auditor_Externo','Contador')
$$;

-- Helper: papéis que podem APROVAR/DECIDIR/escrever em fluxos de aprovação
-- e conciliação. Deliberadamente MENOR que app_papel_gestor(): Auditor_Externo
-- e Contador têm papel de leitura/conferência, não de execução, então não
-- entram aqui mesmo sendo "gestores" para fins de consulta.
create or replace function app_papel_aprovador() returns boolean
language sql stable as $$
  select app_papel() in ('Administrador','Tesoureiro','Diretoria')
$$;

alter table membros enable row level security;
alter table departamentos enable row level security;
alter table usuarios enable row level security;
alter table sessoes enable row level security;
alter table centros_custo enable row level security;
alter table lotes_arrecadacao enable row level security;
alter table contagem_lote enable row level security;
alter table lancamentos_entrada enable row level security;
alter table recibos enable row level security;
alter table recibos_contador_anual enable row level security;
alter table fornecedores enable row level security;
alter table fornecedores_dados_bancarios enable row level security;
alter table alcadas_aprovacao enable row level security;
alter table solicitacoes_pagamento enable row level security;
alter table documentos_fiscais enable row level security;
alter table aprovacoes enable row level security;
alter table prebendas_pastorais enable row level security;
alter table contas_bancarias enable row level security;
alter table extratos_importados enable row level security;
alter table movimentos_bancarios enable row level security;
alter table log_auditoria enable row level security;

-- Sem sessão válida = nenhum acesso a nada. Todas as tabelas exigem
-- app_usuario_id() não nulo (setado só por verificar_sessao()).
create policy p_membros_rw on membros for all
  using (app_usuario_id() is not null) with check (app_usuario_id() is not null);

create policy p_departamentos_rw on departamentos for all
  using (app_usuario_id() is not null) with check (app_usuario_id() is not null);

-- Usuários: qualquer sessão válida pode ler (para listas de aprovador etc.),
-- mas só Administrador escreve.
create policy p_usuarios_select on usuarios for select
  using (app_usuario_id() is not null);
create policy p_usuarios_write on usuarios for insert with check (app_papel() = 'Administrador');
create policy p_usuarios_update on usuarios for update
  using (app_papel() = 'Administrador') with check (app_papel() = 'Administrador');

create policy p_sessoes_self on sessoes for select
  using (usuario_id = app_usuario_id());

-- Helper: papel Auditor_Externo é só-leitura por definição (é o papel que
-- assina a verificação de integridade; não pode ser também quem lança).
create or replace function app_papel_pode_escrever() returns boolean
language sql stable as $$ select app_papel() is not null and app_papel() <> 'Auditor_Externo' $$;

create policy p_centros_custo_select on centros_custo for select using (app_usuario_id() is not null);
create policy p_centros_custo_write on centros_custo for insert with check (app_papel_pode_escrever());
create policy p_centros_custo_update on centros_custo for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_centros_custo_delete on centros_custo for delete using (app_papel_pode_escrever());

create policy p_lotes_select on lotes_arrecadacao for select using (app_usuario_id() is not null);
create policy p_lotes_write on lotes_arrecadacao for insert with check (app_papel_pode_escrever());
create policy p_lotes_update on lotes_arrecadacao for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_lotes_delete on lotes_arrecadacao for delete using (app_papel_pode_escrever());

create policy p_contagem_select on contagem_lote for select using (app_usuario_id() is not null);
create policy p_contagem_write on contagem_lote for insert with check (app_papel_pode_escrever());
create policy p_contagem_update on contagem_lote for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_contagem_delete on contagem_lote for delete using (app_papel_pode_escrever());

create policy p_lancamentos_select on lancamentos_entrada for select using (app_usuario_id() is not null);
create policy p_lancamentos_write on lancamentos_entrada for insert with check (app_papel_pode_escrever());
create policy p_lancamentos_update on lancamentos_entrada for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_lancamentos_delete on lancamentos_entrada for delete using (app_papel_pode_escrever());

create policy p_recibos_select on recibos for select using (app_usuario_id() is not null);
create policy p_recibos_insert on recibos for insert with check (app_usuario_id() is not null);
-- (sem policy de update/delete: os triggers de imutabilidade já bloqueiam,
-- e a ausência de policy de update/delete nega por padrão)

create policy p_recibos_contador_rw on recibos_contador_anual for all
  using (app_usuario_id() is not null) with check (app_usuario_id() is not null);

create policy p_fornecedores_select on fornecedores for select using (app_usuario_id() is not null);
create policy p_fornecedores_write on fornecedores for insert with check (app_papel_pode_escrever());
create policy p_fornecedores_update on fornecedores for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_fornecedores_delete on fornecedores for delete using (app_papel_pode_escrever());

-- Dados bancários de fornecedor: NENHUM acesso direto via API pública —
-- só a função SECURITY DEFINER obter_dados_bancarios_fornecedor() lê,
-- e ela roda com privilégios do dono da função, contornando RLS.
create policy p_fornecedores_bancarios_bloqueado on fornecedores_dados_bancarios for all
  using (false) with check (false);

create policy p_alcadas_select on alcadas_aprovacao for select using (app_usuario_id() is not null);
create policy p_alcadas_write on alcadas_aprovacao for all
  using (app_papel() = 'Administrador') with check (app_papel() = 'Administrador');

create policy p_solicitacoes_select on solicitacoes_pagamento for select using (app_usuario_id() is not null);
create policy p_solicitacoes_write on solicitacoes_pagamento for insert with check (app_papel_pode_escrever());
create policy p_solicitacoes_update on solicitacoes_pagamento for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_solicitacoes_delete on solicitacoes_pagamento for delete using (app_papel_pode_escrever());

create policy p_documentos_fiscais_select on documentos_fiscais for select using (app_usuario_id() is not null);
create policy p_documentos_fiscais_write on documentos_fiscais for insert with check (app_papel_pode_escrever());
create policy p_documentos_fiscais_update on documentos_fiscais for update
  using (app_papel_pode_escrever()) with check (app_papel_pode_escrever());
create policy p_documentos_fiscais_delete on documentos_fiscais for delete using (app_papel_pode_escrever());

create policy p_aprovacoes_select on aprovacoes for select using (app_usuario_id() is not null);
create policy p_aprovacoes_insert on aprovacoes for insert
  with check (app_usuario_id() is not null and app_papel_aprovador());

-- Pastor só enxerga (inclusive as próprias); toda escrita fica restrita
-- a papéis de gestão. Separado em SELECT + ALL porque um único "for all"
-- com using() amplo liberaria também UPDATE/DELETE para quem só devia ler.
create policy p_prebendas_select on prebendas_pastorais for select
  using (app_papel_gestor() or app_papel() = 'Pastor');
create policy p_prebendas_insert on prebendas_pastorais for insert
  with check (app_papel_aprovador());
create policy p_prebendas_update on prebendas_pastorais for update
  using (app_papel_aprovador()) with check (app_papel_aprovador());
create policy p_prebendas_delete on prebendas_pastorais for delete
  using (app_papel_aprovador());

create policy p_contas_bancarias_select on contas_bancarias for select using (app_papel_gestor());
create policy p_contas_bancarias_write on contas_bancarias for insert with check (app_papel_aprovador());
create policy p_contas_bancarias_update on contas_bancarias for update
  using (app_papel_aprovador()) with check (app_papel_aprovador());
create policy p_contas_bancarias_delete on contas_bancarias for delete using (app_papel_aprovador());

create policy p_extratos_select on extratos_importados for select using (app_papel_gestor());
create policy p_extratos_write on extratos_importados for insert with check (app_papel_aprovador());
create policy p_extratos_update on extratos_importados for update
  using (app_papel_aprovador()) with check (app_papel_aprovador());
create policy p_extratos_delete on extratos_importados for delete using (app_papel_aprovador());

create policy p_movimentos_select on movimentos_bancarios for select using (app_papel_gestor());
create policy p_movimentos_write on movimentos_bancarios for insert with check (app_papel_aprovador());
create policy p_movimentos_update on movimentos_bancarios for update
  using (app_papel_aprovador()) with check (app_papel_aprovador());
create policy p_movimentos_delete on movimentos_bancarios for delete using (app_papel_aprovador());

-- LOG_AUDITORIA: só leitura, só para Auditor_Externo/Administrador.
-- Nenhuma policy de insert/update/delete: gravação só via
-- registrar_auditoria() (SECURITY DEFINER), nunca via API direta.
create policy p_log_auditoria_select on log_auditoria for select
  using (app_papel() in ('Administrador','Auditor_Externo'));
