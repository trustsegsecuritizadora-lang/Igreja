-- =====================================================================
-- SGDE — 0011: FIX CRÍTICO — funções SECURITY DEFINER (fechar_lote,
-- emitir_recibo, conciliar_extrato_automatico, criar_usuario) rodavam
-- com privilégio elevado (ignoram RLS) mas sem validar a sessão do
-- chamador. Isso permitia que qualquer pessoa com a anon key as
-- chamasse diretamente via /rest/v1/rpc/... sem estar logada — incluindo
-- criar um usuário Administrador arbitrário via criar_usuario(). Achado
-- pelo linter de segurança do próprio Supabase (get_advisors) logo após
-- aplicar as migrations em produção. Todas passam a exigir token de
-- sessão válido (mesma verificar_sessao() usada no resto do sistema) e
-- checar o papel. Aplicar depois de 0001-0009.
-- =====================================================================

drop function if exists criar_usuario(text, text, text, text, uuid);

create or replace function criar_usuario(
  p_token uuid, p_login text, p_senha text, p_nome text, p_papel text, p_membro_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sessao record;
  v_salt text := encode(gen_random_bytes(16), 'hex');
  v_id   uuid;
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel <> 'Administrador' then
    raise exception 'Apenas Administrador pode criar usuários.';
  end if;

  insert into usuarios (login, hash_senha, salt, nome, papel, membro_id)
    values (lower(trim(p_login)), hash_senha(p_senha, v_salt), v_salt, p_nome, p_papel, p_membro_id)
    returning id_usuario into v_id;

  perform registrar_auditoria(v_sessao.usuario_id, 'usuarios', v_id::text, 'INSERT',
    null, jsonb_build_object('evento','usuario_criado','papel',p_papel));

  return v_id;
end;
$$;

drop function if exists fechar_lote(uuid, uuid);

create or replace function fechar_lote(p_token uuid, p_lote_id uuid)
returns lotes_arrecadacao
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sessao          record;
  v_lote            lotes_arrecadacao;
  v_qtd_conferencias int;
  v_soma_lancamentos numeric(14,2);
  v_tolerancia       numeric(14,2) := 0.01;
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel = 'Auditor_Externo' then
    raise exception 'Auditor_Externo tem acesso somente leitura.';
  end if;

  select * into v_lote from lotes_arrecadacao where id_lote = p_lote_id for update;
  if v_lote is null then
    raise exception 'Lote não encontrado.';
  end if;

  select count(*) into v_qtd_conferencias
    from contagem_lote
    where lote_id = p_lote_id and de_acordo = true;

  if v_qtd_conferencias < 2 then
    raise exception 'Fechamento bloqueado: é necessário pelo menos 2 conferências convergentes (encontradas: %).', v_qtd_conferencias;
  end if;

  select coalesce(sum(valor), 0) into v_soma_lancamentos
    from lancamentos_entrada where lote_id = p_lote_id;

  if abs(v_soma_lancamentos - v_lote.valor_apurado_total) > v_tolerancia then
    update lotes_arrecadacao set status = 'divergente' where id_lote = p_lote_id;
    raise exception 'Fechamento bloqueado: soma dos lançamentos (%) difere do valor apurado do lote (%).',
      v_soma_lancamentos, v_lote.valor_apurado_total;
  end if;

  update lotes_arrecadacao
    set status = 'conferido', fechado_em = now()
    where id_lote = p_lote_id
    returning * into v_lote;

  return v_lote;
end;
$$;

drop function if exists emitir_recibo(uuid);

create or replace function emitir_recibo(p_token uuid, p_entrada_id uuid)
returns recibos
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sessao   record;
  v_ano      int := extract(year from now())::int;
  v_numero   int;
  v_valor    numeric(14,2);
  v_recibo   recibos;
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel = 'Auditor_Externo' then
    raise exception 'Auditor_Externo tem acesso somente leitura.';
  end if;

  select valor into v_valor from lancamentos_entrada where id_entrada = p_entrada_id;
  if v_valor is null then
    raise exception 'Lançamento de entrada % não encontrado.', p_entrada_id;
  end if;

  insert into recibos_contador_anual(ano_referencia, ultimo_numero)
    values (v_ano, 1)
    on conflict (ano_referencia) do update set ultimo_numero = recibos_contador_anual.ultimo_numero + 1
    returning ultimo_numero into v_numero;

  insert into recibos (entrada_id, ano_referencia, numero_recibo, hash_documento)
    values (
      p_entrada_id, v_ano, v_numero,
      encode(digest(p_entrada_id::text || v_ano::text || v_numero::text || v_valor::text || now()::text, 'sha256'), 'hex')
    )
    returning * into v_recibo;

  update lancamentos_entrada set recibo_id_cache = v_recibo.id_recibo where id_entrada = p_entrada_id;

  return v_recibo;
end;
$$;

drop function if exists conciliar_extrato_automatico(uuid);

create or replace function conciliar_extrato_automatico(p_token uuid, p_extrato_id uuid)
returns table(id_movimento uuid, status text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sessao record;
  r record;
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel not in ('Administrador','Tesoureiro','Diretoria') then
    raise exception 'Acesso negado à conciliação bancária.';
  end if;

  for r in
    select m.id_movimento, sp.id_solicitacao
    from movimentos_bancarios m
    join solicitacoes_pagamento sp
      on sp.status = 'liquidado'
     and sp.valor = abs(m.valor)
     and sp.data_vencimento = m.data
    where m.extrato_id = p_extrato_id
      and m.status_conciliacao = 'pendente'
      and m.valor < 0
      and not exists (select 1 from movimentos_bancarios mm where mm.saida_solicitacao_id = sp.id_solicitacao)
  loop
    update movimentos_bancarios
      set status_conciliacao = 'conciliado', saida_solicitacao_id = r.id_solicitacao, conciliado_em = now()
      where movimentos_bancarios.id_movimento = r.id_movimento;
  end loop;

  for r in
    select m.id_movimento, la.id_lote
    from movimentos_bancarios m
    join lotes_arrecadacao la
      on la.status = 'conferido'
     and la.valor_apurado_total = m.valor
     and la.data_culto = m.data
    where m.extrato_id = p_extrato_id
      and m.status_conciliacao = 'pendente'
      and m.valor > 0
      and not exists (select 1 from movimentos_bancarios mm where mm.entrada_lote_id = la.id_lote)
  loop
    update movimentos_bancarios
      set status_conciliacao = 'conciliado', entrada_lote_id = r.id_lote, conciliado_em = now()
      where movimentos_bancarios.id_movimento = r.id_movimento;

    update lotes_arrecadacao set status = 'depositado' where id_lote = r.id_lote;
  end loop;

  return query
    select m.id_movimento, m.status_conciliacao from movimentos_bancarios m where m.extrato_id = p_extrato_id;
end;
$$;

-- registrar_auditoria não deve ser chamável direto por anon/authenticated
-- (senão dá para injetar eventos forjados na cadeia de hash). O trigger
-- genérico vira SECURITY DEFINER para continuar funcionando mesmo sem o
-- chamador ter EXECUTE em registrar_auditoria.
create or replace function trg_auditoria_generica()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
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

revoke execute on function registrar_auditoria(uuid, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function verificar_integridade_auditoria() from public, anon;
grant execute on function verificar_integridade_auditoria() to authenticated;
revoke execute on function trg_auditoria_generica() from public, anon, authenticated;

-- Hardening geral do linter: search_path explícito em todas as funções
-- que ainda estavam sem (evita sequestro de search_path por role).
create or replace function app_usuario_id() returns uuid
language sql stable set search_path = public as $$ select nullif(current_setting('app.usuario_id', true), '')::uuid $$;
create or replace function app_papel() returns text
language sql stable set search_path = public as $$ select nullif(current_setting('app.papel', true), '') $$;
create or replace function app_papel_gestor() returns boolean
language sql stable set search_path = public as $$ select app_papel() in ('Administrador','Tesoureiro','Diretoria','Auditor_Externo','Contador') $$;
create or replace function app_papel_aprovador() returns boolean
language sql stable set search_path = public as $$ select app_papel() in ('Administrador','Tesoureiro','Diretoria') $$;
create or replace function app_papel_pode_escrever() returns boolean
language sql stable set search_path = public as $$ select app_papel() is not null and app_papel() <> 'Auditor_Externo' $$;
create or replace function app_papel_conteudo() returns boolean
language sql stable set search_path = public as $$ select app_papel() in ('Administrador','Diretoria','Secretaria') $$;

alter function trg_log_auditoria_imutavel() set search_path = public;
alter function trg_inscricao_valida_vagas() set search_path = public;
alter function trg_impedir_remocao_ultimo_admin() set search_path = public;
alter function trg_contagem_exige_justificativa() set search_path = public;
alter function trg_recibos_imutavel() set search_path = public;
alter function trg_liquidacao_exige_documento_fiscal() set search_path = public;
alter function trg_aprovacoes_bloqueia_autoaprovacao() set search_path = public;
alter function processar_decisao_solicitacao() set search_path = public;
alter function trg_prebenda_bloqueia_autoaprovacao_e_papel() set search_path = public;
