-- =====================================================================
-- SGDE — 0004: contas bancárias, importação OFX/CSV e conciliação
-- =====================================================================

create table contas_bancarias (
  id_conta      uuid primary key default gen_random_uuid(),
  banco         text not null,
  agencia       text not null,
  conta         text not null,
  titularidade  text not null,   -- deve ser sempre o CNPJ da igreja
  ativo         boolean not null default true
);

create table extratos_importados (
  id_extrato       uuid primary key default gen_random_uuid(),
  conta_id         uuid not null references contas_bancarias(id_conta),
  arquivo_origem   text not null,
  formato          text not null check (formato in ('OFX','CSV')),
  data_importacao  timestamptz not null default now(),
  importado_por_id uuid not null references usuarios(id_usuario)
);

-- ---------------------------------------------------------------------
-- MOVIMENTOS_BANCARIOS — em vez de FK polimórfica (lancamento_vinculado_id +
-- tipo_lancamento_vinculado), usamos duas colunas FK reais com CHECK de
-- exclusividade: o Postgres valida a integridade nativamente.
-- ---------------------------------------------------------------------
create table movimentos_bancarios (
  id_movimento         uuid primary key default gen_random_uuid(),
  extrato_id           uuid not null references extratos_importados(id_extrato),
  data                 date not null,
  valor                numeric(14,2) not null,
  descricao_banco      text,
  hash_transacao       text not null,   -- evita duplicidade em reimportação
  status_conciliacao   text not null default 'pendente'
                          check (status_conciliacao in ('pendente','conciliado','ignorado')),
  entrada_lote_id       uuid references lotes_arrecadacao(id_lote),
  saida_solicitacao_id  uuid references solicitacoes_pagamento(id_solicitacao),
  conciliado_em        timestamptz,
  conciliado_por_id    uuid references usuarios(id_usuario),
  unique (extrato_id, hash_transacao),
  constraint chk_movimento_vinculo_exclusivo check (
    (entrada_lote_id is not null and saida_solicitacao_id is null) or
    (entrada_lote_id is null and saida_solicitacao_id is not null) or
    (entrada_lote_id is null and saida_solicitacao_id is null)   -- ainda não conciliado
  ),
  constraint chk_movimento_conciliado_tem_vinculo check (
    status_conciliacao <> 'conciliado' or entrada_lote_id is not null or saida_solicitacao_id is not null
  )
);

create index idx_movimentos_status on movimentos_bancarios(status_conciliacao);
create index idx_movimentos_data_valor on movimentos_bancarios(data, valor);

-- Conciliação automática por valor+data exato; o que não bate exato fica
-- 'pendente' (fila manual). Função chamada após cada importação de extrato.
create or replace function conciliar_extrato_automatico(p_extrato_id uuid)
returns table(id_movimento uuid, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  -- casa saídas (valor negativo) com solicitações liquidadas por valor+data
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

  -- casa entradas (valor positivo) com lotes conferidos por valor+data
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
