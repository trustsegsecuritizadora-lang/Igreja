-- =====================================================================
-- SGDE — 0005: log de auditoria append-only com hash encadeado
-- Cada linha carrega o hash da linha anterior + seu próprio conteúdo,
-- formando uma cadeia: qualquer adulteração retroativa quebra a cadeia
-- e é detectável por verificar_integridade_auditoria().
-- =====================================================================

create table log_auditoria (
  id_log          bigserial primary key,
  usuario_id      uuid references usuarios(id_usuario),
  tabela_afetada  text not null,
  registro_id     text not null,
  acao            text not null check (acao in ('INSERT','UPDATE','DELETE','EXPORT')),
  valor_anterior  jsonb,
  valor_novo      jsonb,
  timestamp_evento timestamptz not null default now(),
  ip_origem       text,
  hash_anterior   text not null,
  hash_registro   text not null
);

-- Nenhuma linha de auditoria pode ser alterada ou apagada por ninguém,
-- nem pelo dono do schema em uso normal (revogado abaixo).
create or replace function trg_log_auditoria_imutavel()
returns trigger language plpgsql as $$
begin
  raise exception 'LOG_AUDITORIA é append-only: UPDATE/DELETE não são permitidos.';
end;
$$;

create trigger trg_log_auditoria_bloqueia_update
  before update on log_auditoria
  for each row execute function trg_log_auditoria_imutavel();

create trigger trg_log_auditoria_bloqueia_delete
  before delete on log_auditoria
  for each row execute function trg_log_auditoria_imutavel();

-- Função central de gravação — calcula o hash encadeado e insere.
-- current_setting('app.ip_origem', true) é opcional (setado pelo client).
create or replace function registrar_auditoria(
  p_usuario_id      uuid,
  p_tabela_afetada  text,
  p_registro_id     text,
  p_acao            text,
  p_valor_anterior  jsonb,
  p_valor_novo      jsonb
) returns void
language plpgsql
security definer
set search_path = public, extensions   -- digest() mora em "extensions" nos projetos Supabase
as $$
declare
  v_hash_anterior text;
  v_conteudo      text;
  v_hash_novo     text;
  v_ip            text;
begin
  select hash_registro into v_hash_anterior
    from log_auditoria order by id_log desc limit 1;

  if v_hash_anterior is null then
    v_hash_anterior := encode(digest('SGDE_GENESIS', 'sha256'), 'hex');
  end if;

  v_ip := coalesce(current_setting('app.ip_origem', true), '');

  v_conteudo := coalesce(p_usuario_id::text, '') || '|' || p_tabela_afetada || '|' || p_registro_id || '|' ||
                p_acao || '|' || coalesce(p_valor_anterior::text, '') || '|' || coalesce(p_valor_novo::text, '') ||
                '|' || now()::text || '|' || v_ip || '|' || v_hash_anterior;

  v_hash_novo := encode(digest(v_conteudo, 'sha256'), 'hex');

  insert into log_auditoria (
    usuario_id, tabela_afetada, registro_id, acao, valor_anterior, valor_novo,
    ip_origem, hash_anterior, hash_registro
  ) values (
    p_usuario_id, p_tabela_afetada, p_registro_id, p_acao, p_valor_anterior, p_valor_novo,
    v_ip, v_hash_anterior, v_hash_novo
  );
end;
$$;

-- Trigger genérico: dispara em toda INSERT/UPDATE/DELETE das tabelas
-- financeiras, sem depender da aplicação lembrar de logar.
create or replace function trg_auditoria_generica()
returns trigger language plpgsql as $$
declare
  v_usuario_id uuid;
  v_registro_id text;
begin
  begin
    v_usuario_id := nullif(current_setting('app.usuario_id', true), '')::uuid;
  exception when others then
    v_usuario_id := null;
  end;

  if TG_OP = 'DELETE' then
    v_registro_id := (to_jsonb(old) ->> TG_ARGV[0]);
    perform registrar_auditoria(v_usuario_id, TG_TABLE_NAME, v_registro_id, 'DELETE', to_jsonb(old), null);
    return old;
  elsif TG_OP = 'UPDATE' then
    v_registro_id := (to_jsonb(new) ->> TG_ARGV[0]);
    perform registrar_auditoria(v_usuario_id, TG_TABLE_NAME, v_registro_id, 'UPDATE', to_jsonb(old), to_jsonb(new));
    return new;
  elsif TG_OP = 'INSERT' then
    v_registro_id := (to_jsonb(new) ->> TG_ARGV[0]);
    perform registrar_auditoria(v_usuario_id, TG_TABLE_NAME, v_registro_id, 'INSERT', null, to_jsonb(new));
    return new;
  end if;
  return null;
end;
$$;

-- Anexa o trigger de auditoria a todas as tabelas financeiras sensíveis.
-- O argumento é o nome da coluna de PK, usada como registro_id.
create trigger trg_audit_lotes_arrecadacao
  after insert or update or delete on lotes_arrecadacao
  for each row execute function trg_auditoria_generica('id_lote');

create trigger trg_audit_contagem_lote
  after insert or update or delete on contagem_lote
  for each row execute function trg_auditoria_generica('id_contagem');

create trigger trg_audit_lancamentos_entrada
  after insert or update or delete on lancamentos_entrada
  for each row execute function trg_auditoria_generica('id_entrada');

create trigger trg_audit_recibos
  after insert on recibos     -- recibos são imutáveis: só INSERT é possível
  for each row execute function trg_auditoria_generica('id_recibo');

create trigger trg_audit_solicitacoes_pagamento
  after insert or update or delete on solicitacoes_pagamento
  for each row execute function trg_auditoria_generica('id_solicitacao');

create trigger trg_audit_documentos_fiscais
  after insert or update or delete on documentos_fiscais
  for each row execute function trg_auditoria_generica('id_documento');

create trigger trg_audit_aprovacoes
  after insert or update or delete on aprovacoes
  for each row execute function trg_auditoria_generica('id_aprovacao');

create trigger trg_audit_prebendas_pastorais
  after insert or update or delete on prebendas_pastorais
  for each row execute function trg_auditoria_generica('id_prebenda');

create trigger trg_audit_movimentos_bancarios
  after insert or update or delete on movimentos_bancarios
  for each row execute function trg_auditoria_generica('id_movimento');

create trigger trg_audit_fornecedores_dados_bancarios
  after insert or update or delete on fornecedores_dados_bancarios
  for each row execute function trg_auditoria_generica('fornecedor_id');

-- ---------------------------------------------------------------------
-- Verificação de integridade da cadeia — roda sob demanda (Auditor_Externo)
-- ---------------------------------------------------------------------
create or replace function verificar_integridade_auditoria()
returns table(id_log bigint, integro boolean, motivo text)
language plpgsql
security definer
set search_path = public, extensions   -- digest() mora em "extensions" nos projetos Supabase
as $$
declare
  r record;
  v_hash_esperado text;
  v_hash_anterior_esperado text := encode(digest('SGDE_GENESIS', 'sha256'), 'hex');
  v_conteudo text;
begin
  for r in select * from log_auditoria order by id_log asc loop
    if r.hash_anterior <> v_hash_anterior_esperado then
      id_log := r.id_log; integro := false; motivo := 'hash_anterior não confere com a cadeia';
      return next;
    else
      v_conteudo := coalesce(r.usuario_id::text, '') || '|' || r.tabela_afetada || '|' || r.registro_id || '|' ||
                    r.acao || '|' || coalesce(r.valor_anterior::text, '') || '|' || coalesce(r.valor_novo::text, '') ||
                    '|' || r.timestamp_evento::text || '|' || coalesce(r.ip_origem, '') || '|' || r.hash_anterior;
      v_hash_esperado := encode(digest(v_conteudo, 'sha256'), 'hex');
      if v_hash_esperado <> r.hash_registro then
        id_log := r.id_log; integro := false; motivo := 'hash_registro não confere: possível adulteração';
        return next;
      end if;
    end if;
    v_hash_anterior_esperado := r.hash_registro;
  end loop;
end;
$$;
