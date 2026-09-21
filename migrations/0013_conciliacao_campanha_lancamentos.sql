-- =====================================================================
-- SGDE — 0013: liga a conciliação bancária aos lançamentos de campanha
-- =====================================================================
-- Contexto: campanha_lancamentos já registra valor, data e observação
-- (na prática, muitas vezes usada para anotar o doador) para cada
-- arrecadação confirmada de campanha — mas esse lançamento nunca era
-- considerado na conciliação bancária, nem na automática nem na fila
-- manual. Esta migração estende movimentos_bancarios para também poder
-- se vincular a um campanha_lancamento, e estende a conciliação
-- automática para sugerir/casar esses lançamentos por valor + data.

alter table movimentos_bancarios
  add column campanha_lancamento_id uuid references campanha_lancamentos(id_lancamento);

-- Trava de exclusividade agora cobre os três vínculos possíveis (no
-- máximo um: lote de entrada, solicitação de saída ou lançamento de
-- campanha — ou nenhum, se ainda não conciliado).
alter table movimentos_bancarios drop constraint chk_movimento_vinculo_exclusivo;
alter table movimentos_bancarios add constraint chk_movimento_vinculo_exclusivo check (
  (case when entrada_lote_id is not null then 1 else 0 end
   + case when saida_solicitacao_id is not null then 1 else 0 end
   + case when campanha_lancamento_id is not null then 1 else 0 end) <= 1
);

alter table movimentos_bancarios drop constraint chk_movimento_conciliado_tem_vinculo;
alter table movimentos_bancarios add constraint chk_movimento_conciliado_tem_vinculo check (
  status_conciliacao <> 'conciliado'
  or entrada_lote_id is not null
  or saida_solicitacao_id is not null
  or campanha_lancamento_id is not null
);

-- ---------------------------------------------------------------------
-- Conciliação automática: agora também casa entradas pendentes com um
-- lançamento de campanha por valor + data (data_lancamento), quando não
-- houver lote correspondente. Mantém a validação de sessão/papel e o
-- restante do comportamento já existente (saídas × solicitações
-- liquidadas, entradas × lotes conferidos).
-- ---------------------------------------------------------------------
drop function if exists conciliar_extrato_automatico(uuid, uuid);

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

  -- Novo: entradas ainda pendentes (sem lote correspondente) que batem
  -- por valor + data com um lançamento de campanha ainda não vinculado
  -- a nenhum outro movimento bancário.
  for r in
    select m.id_movimento, cl.id_lancamento
    from movimentos_bancarios m
    join campanha_lancamentos cl
      on cl.valor = m.valor
     and cl.data_lancamento = m.data
    where m.extrato_id = p_extrato_id
      and m.status_conciliacao = 'pendente'
      and m.valor > 0
      and not exists (select 1 from movimentos_bancarios mm where mm.campanha_lancamento_id = cl.id_lancamento)
  loop
    update movimentos_bancarios
      set status_conciliacao = 'conciliado', campanha_lancamento_id = r.id_lancamento, conciliado_em = now()
      where movimentos_bancarios.id_movimento = r.id_movimento;
  end loop;

  return query
    select m.id_movimento, m.status_conciliacao from movimentos_bancarios m where m.extrato_id = p_extrato_id;
end;
$$;
