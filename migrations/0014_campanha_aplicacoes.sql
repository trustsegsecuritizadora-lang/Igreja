-- =====================================================================
-- SGDE — 0014: campanha_aplicacoes — histórico DATADO de aplicações
-- (gastos) de campanha, espelhando do lado das saídas o que
-- campanha_lancamentos já é do lado das entradas.
-- =====================================================================
-- Contexto: "Total aplicado" em campanhas (aba Prestação de contas) é um
-- número único, digitado manualmente, sem data — por isso nunca entrava
-- no Balancete & Caixa mensal (não há como saber em que mês o dinheiro
-- saiu). Esta tabela resolve isso *daqui pra frente*: cada gasto de
-- campanha passa a ser lançado com data, igual já acontece com as
-- entradas em campanha_lancamentos, permitindo detalhamento mês a mês.
--
-- Decisão deliberada: esta migração NÃO mexe em campanhas.total_aplicado
-- nem tenta recalculá-lo a partir daqui. Esse campo continua sendo o
-- resumo manual da aba Prestação de Contas (usado na prestação de contas
-- pública) — não seria seguro sobrescrevê-lo automaticamente sem saber
-- se o valor já lançado ali é ou não a mesma coisa que será lançada
-- aqui. O saldo já aplicado antes desta migração (sem data conhecida)
-- fica de fora do detalhamento mensal do Balancete; só os lançamentos
-- datados a partir de agora aparecem lá.

create table if not exists campanha_aplicacoes (
  id_aplicacao      uuid primary key default gen_random_uuid(),
  campanha_id       uuid not null references campanhas(id_campanha),
  valor             numeric(14,2) not null,
  data_aplicacao    date not null default current_date,
  responsavel_id    uuid not null references usuarios(id_usuario),
  descricao         text,
  criado_em         timestamptz not null default now()
);
create index if not exists idx_campanha_aplicacoes_campanha on campanha_aplicacoes(campanha_id);
create index if not exists idx_campanha_aplicacoes_data on campanha_aplicacoes(data_aplicacao);

-- Append-only (mesma filosofia de campanha_lancamentos e do log de
-- auditoria): nunca sobrescreve, correção entra como novo lançamento
-- (inclusive negativo).
create or replace function trg_campanha_aplicacoes_imutavel()
returns trigger language plpgsql as $$
begin
  raise exception 'campanha_aplicacoes é append-only: registre uma correção como novo lançamento (inclusive negativo), nunca altere um existente.';
end;
$$;
drop trigger if exists trg_campanha_aplicacoes_bloqueia_update on campanha_aplicacoes;
create trigger trg_campanha_aplicacoes_bloqueia_update
  before update on campanha_aplicacoes for each row execute function trg_campanha_aplicacoes_imutavel();
drop trigger if exists trg_campanha_aplicacoes_bloqueia_delete on campanha_aplicacoes;
create trigger trg_campanha_aplicacoes_bloqueia_delete
  before delete on campanha_aplicacoes for each row execute function trg_campanha_aplicacoes_imutavel();

-- responsavel_id nunca vem do client: sempre a sessão validada.
create or replace function trg_campanha_aplicacoes_set_responsavel()
returns trigger language plpgsql as $$
begin
  new.responsavel_id := app_usuario_id();
  if new.responsavel_id is null then
    raise exception 'Lançamento de aplicação de campanha exige sessão administrativa autenticada.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_campanha_aplicacoes_responsavel on campanha_aplicacoes;
create trigger trg_campanha_aplicacoes_responsavel
  before insert on campanha_aplicacoes for each row execute function trg_campanha_aplicacoes_set_responsavel();

alter table campanha_aplicacoes enable row level security;
drop policy if exists p_campanha_aplicacoes_select on campanha_aplicacoes;
create policy p_campanha_aplicacoes_select on campanha_aplicacoes for select using (app_usuario_id() is not null);
drop policy if exists p_campanha_aplicacoes_insert on campanha_aplicacoes;
create policy p_campanha_aplicacoes_insert on campanha_aplicacoes for insert with check (app_papel_conteudo());

drop trigger if exists trg_audit_campanha_aplicacoes on campanha_aplicacoes;
create trigger trg_audit_campanha_aplicacoes
  after insert on campanha_aplicacoes for each row execute function trg_auditoria_generica('id_aplicacao');

comment on table campanha_aplicacoes is
  'Histórico datado de aplicações (gastos) de campanha — alimenta o detalhamento mensal do Balancete & Caixa. Independente de campanhas.total_aplicado (resumo manual da prestação de contas pública).';
