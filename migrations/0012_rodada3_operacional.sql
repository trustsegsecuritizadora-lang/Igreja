-- =====================================================================
-- SGDE — 0012: Rodada 3 — ISSD como plataforma operacional
-- Gestão de Campanhas (status + arrecadação confirmada com histórico),
-- Rede de Talentos (voluntários), Instituições Indicadas,
-- 7 Minutos de Propósito (CMS), Transparência (documentos públicos).
-- Reaproveita a infraestrutura existente: app_papel_conteudo(),
-- trg_auditoria_generica()/registrar_auditoria() (log hash-encadeado),
-- campanha_fotos e campanha_parceiros (já existiam, seguem intactos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. campanhas — novos campos para o ciclo de vida completo
-- ---------------------------------------------------------------------
alter table campanhas
  add column if not exists status text not null default 'ativa'
    check (status in ('rascunho','ativa','encerrada','prestacao_contas','arquivada')),
  add column if not exists destaque_home boolean not null default false,
  add column if not exists texto_completo text,
  add column if not exists resultados_texto text,
  add column if not exists total_arrecadado_confirmado numeric(14,2) not null default 0,
  add column if not exists prestacao_contas_publicada boolean not null default false;

-- Backfill: as duas campanhas já publicadas e ativas entram em destaque na Home.
update campanhas set status = 'ativa', destaque_home = true
  where publicado = true and (modo = 'ativa' or modo is null);

comment on column campanhas.total_arrecadado_confirmado is
  'Único valor usado para calcular a barra de progresso pública. Nunca deriva de clique/acesso/seleção — só de campanha_lancamentos (lançamento manual por administrador autorizado) via trigger.';

-- Público só vê campanhas publicadas, ativas/encerradas/em prestação de contas
-- (nunca rascunho nem arquivada) — substitui a policy anterior, mais estrita.
drop policy if exists p_campanhas_select_publico on campanhas;
create policy p_campanhas_select_publico on campanhas for select
  to anon, authenticated using (publicado = true and status not in ('rascunho','arquivada'));

-- ---------------------------------------------------------------------
-- 2. campanha_lancamentos — histórico/audit trail de arrecadação confirmada
--    Append-only (mesma filosofia do log_auditoria): nunca sobrescreve,
--    correção entra como novo lançamento (inclusive negativo).
-- ---------------------------------------------------------------------
create table if not exists campanha_lancamentos (
  id_lancamento     uuid primary key default gen_random_uuid(),
  campanha_id       uuid not null references campanhas(id_campanha),
  valor             numeric(14,2) not null,
  data_lancamento   date not null default current_date,
  responsavel_id    uuid not null references usuarios(id_usuario),
  observacao        text,
  criado_em         timestamptz not null default now()
);
create index if not exists idx_campanha_lancamentos_campanha on campanha_lancamentos(campanha_id);

create or replace function trg_campanha_lancamentos_imutavel()
returns trigger language plpgsql as $$
begin
  raise exception 'campanha_lancamentos é append-only: registre uma correção como novo lançamento, nunca altere um existente.';
end;
$$;
drop trigger if exists trg_campanha_lancamentos_bloqueia_update on campanha_lancamentos;
create trigger trg_campanha_lancamentos_bloqueia_update
  before update on campanha_lancamentos for each row execute function trg_campanha_lancamentos_imutavel();
drop trigger if exists trg_campanha_lancamentos_bloqueia_delete on campanha_lancamentos;
create trigger trg_campanha_lancamentos_bloqueia_delete
  before delete on campanha_lancamentos for each row execute function trg_campanha_lancamentos_imutavel();

-- responsavel_id nunca vem do client: sempre a sessão validada.
create or replace function trg_campanha_lancamentos_set_responsavel()
returns trigger language plpgsql as $$
begin
  new.responsavel_id := app_usuario_id();
  if new.responsavel_id is null then
    raise exception 'Lançamento de arrecadação exige sessão administrativa autenticada.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_campanha_lancamentos_responsavel on campanha_lancamentos;
create trigger trg_campanha_lancamentos_responsavel
  before insert on campanha_lancamentos for each row execute function trg_campanha_lancamentos_set_responsavel();

-- Mantém campanhas.total_arrecadado_confirmado = soma de todos os lançamentos.
create or replace function trg_campanha_lancamentos_recalcula_total()
returns trigger language plpgsql as $$
begin
  update campanhas set total_arrecadado_confirmado = (
    select coalesce(sum(valor), 0) from campanha_lancamentos where campanha_id = new.campanha_id
  ) where id_campanha = new.campanha_id;
  return new;
end;
$$;
drop trigger if exists trg_campanha_lancamentos_after_insert on campanha_lancamentos;
create trigger trg_campanha_lancamentos_after_insert
  after insert on campanha_lancamentos for each row execute function trg_campanha_lancamentos_recalcula_total();

alter table campanha_lancamentos enable row level security;
drop policy if exists p_campanha_lancamentos_select on campanha_lancamentos;
create policy p_campanha_lancamentos_select on campanha_lancamentos for select using (app_usuario_id() is not null);
drop policy if exists p_campanha_lancamentos_insert on campanha_lancamentos;
create policy p_campanha_lancamentos_insert on campanha_lancamentos for insert with check (app_papel_conteudo());

drop trigger if exists trg_audit_campanha_lancamentos on campanha_lancamentos;
create trigger trg_audit_campanha_lancamentos
  after insert on campanha_lancamentos for each row execute function trg_auditoria_generica('id_lancamento');

-- ---------------------------------------------------------------------
-- 3. campanha_documentos — documentos públicos da prestação de contas
--    (relatórios, comprovantes). Só "publico=true" aparece no site.
-- ---------------------------------------------------------------------
create table if not exists campanha_documentos (
  id_documento   uuid primary key default gen_random_uuid(),
  campanha_id    uuid not null references campanhas(id_campanha),
  nome           text not null,
  url            text not null,
  publico        boolean not null default false,
  criado_em      timestamptz not null default now()
);
alter table campanha_documentos enable row level security;
drop policy if exists p_campanha_documentos_select_publico on campanha_documentos;
create policy p_campanha_documentos_select_publico on campanha_documentos for select
  to anon, authenticated using (publico = true);
drop policy if exists p_campanha_documentos_select_interno on campanha_documentos;
create policy p_campanha_documentos_select_interno on campanha_documentos for select
  using (app_usuario_id() is not null);
drop policy if exists p_campanha_documentos_insert on campanha_documentos;
create policy p_campanha_documentos_insert on campanha_documentos for insert with check (app_papel_conteudo());
drop policy if exists p_campanha_documentos_update on campanha_documentos;
create policy p_campanha_documentos_update on campanha_documentos for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
drop policy if exists p_campanha_documentos_delete on campanha_documentos;
create policy p_campanha_documentos_delete on campanha_documentos for delete using (app_papel_conteudo());
grant select on campanha_documentos to anon;

drop trigger if exists trg_audit_campanha_documentos on campanha_documentos;
create trigger trg_audit_campanha_documentos
  after insert or update or delete on campanha_documentos for each row execute function trg_auditoria_generica('id_documento');

-- ---------------------------------------------------------------------
-- 4. projetos — "Frentes de Atuação" (Alimenta/Criança/Capacita): editorial,
--    sem selo "Em breve", sem CTA funcional ainda (evita botão falso).
-- ---------------------------------------------------------------------
alter table projetos drop constraint if exists projetos_status_check;
alter table projetos add constraint projetos_status_check
  check (status in ('ativo','em_breve','frente_atuacao'));

insert into projetos (titulo, slug, headline, descricao, status, ordem)
values
  ('ISSD Alimenta', 'issd-alimenta', 'Segurança alimentar e mobilização para doação de alimentos.',
   'Frente de atuação dedicada a campanhas de arrecadação e distribuição de alimentos para famílias em situação de vulnerabilidade.',
   'frente_atuacao', 1),
  ('ISSD Criança', 'issd-crianca', 'Infância, brinquedos, material escolar e apoio a instituições.',
   'Frente de atuação voltada ao cuidado com a infância — brinquedos, material escolar e apoio a instituições que atendem crianças.',
   'frente_atuacao', 2),
  ('ISSD Capacita', 'issd-capacita', 'Conhecimento, empregabilidade, empreendedorismo e educação financeira.',
   'Frente de atuação que mobiliza o conhecimento da comunidade ISSD em prol de empregabilidade, empreendedorismo e educação financeira.',
   'frente_atuacao', 3)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- 5. voluntarios — Rede de Talentos em produção real
-- ---------------------------------------------------------------------
create table if not exists voluntarios (
  id_voluntario     uuid primary key default gen_random_uuid(),
  nome              text not null,
  profissao         text,
  empresa           text,
  especialidade     text,
  disponibilidade   text,
  telefone          text,
  email             text,
  como_contribuir   text,
  status            text not null default 'novo'
    check (status in ('novo','contatado','disponivel','participando','inativo')),
  observacoes       text,
  criado_em         timestamptz not null default now(),
  atualizado_por_id uuid references usuarios(id_usuario),
  atualizado_em     timestamptz
);
alter table voluntarios enable row level security;
create policy p_voluntarios_insert_publico on voluntarios for insert to anon, authenticated with check (true);
create policy p_voluntarios_select_interno on voluntarios for select using (app_papel_conteudo());
create policy p_voluntarios_update_interno on voluntarios for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
grant insert on voluntarios to anon;

create trigger trg_audit_voluntarios
  after insert or update on voluntarios for each row execute function trg_auditoria_generica('id_voluntario');

-- ---------------------------------------------------------------------
-- 6. instituicoes_indicadas — CTA "Quero indicar uma instituição"
-- ---------------------------------------------------------------------
create table if not exists instituicoes_indicadas (
  id_instituicao          uuid primary key default gen_random_uuid(),
  nome_instituicao        text not null,
  responsavel             text,
  telefone                text,
  email                   text,
  endereco_regiao         text,
  site_rede_social        text,
  atividade_realizada     text,
  publico_atendido        text,
  como_issd_poderia_ajudar text,
  nome_indicante          text,
  contato_indicante       text,
  status                  text not null default 'nova_indicacao'
    check (status in ('nova_indicacao','em_analise','contatada','parceira','nao_aderente','arquivada')),
  observacoes             text,
  criado_em               timestamptz not null default now(),
  atualizado_por_id       uuid references usuarios(id_usuario),
  atualizado_em           timestamptz
);
alter table instituicoes_indicadas enable row level security;
create policy p_instituicoes_indicadas_insert_publico on instituicoes_indicadas for insert to anon, authenticated with check (true);
create policy p_instituicoes_indicadas_select_interno on instituicoes_indicadas for select using (app_papel_conteudo());
create policy p_instituicoes_indicadas_update_interno on instituicoes_indicadas for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
grant insert on instituicoes_indicadas to anon;

create trigger trg_audit_instituicoes_indicadas
  after insert or update on instituicoes_indicadas for each row execute function trg_auditoria_generica('id_instituicao');

-- ---------------------------------------------------------------------
-- 7. conteudos_proposito — CMS "7 Minutos de Propósito"
-- ---------------------------------------------------------------------
create table if not exists conteudos_proposito (
  id_conteudo       uuid primary key default gen_random_uuid(),
  titulo            text not null,
  subtitulo         text,
  autor             text,
  imagem_url        text,
  conteudo          text not null,
  slug              text not null unique,
  categoria         text,
  tempo_leitura_min integer,
  destaque          boolean not null default false,
  seo_title         text,
  meta_description  text,
  status            text not null default 'rascunho'
    check (status in ('rascunho','agendado','publicado','despublicado')),
  data_publicacao   date,
  criado_por_id     uuid references usuarios(id_usuario),
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz
);
create index if not exists idx_conteudos_proposito_publico on conteudos_proposito(status, data_publicacao);

alter table conteudos_proposito enable row level security;
create policy p_conteudos_proposito_select_publico on conteudos_proposito for select
  to anon, authenticated using (status = 'publicado' and (data_publicacao is null or data_publicacao <= current_date));
create policy p_conteudos_proposito_select_interno on conteudos_proposito for select using (app_papel_conteudo());
create policy p_conteudos_proposito_insert on conteudos_proposito for insert with check (app_papel_conteudo());
create policy p_conteudos_proposito_update on conteudos_proposito for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
create policy p_conteudos_proposito_delete on conteudos_proposito for delete using (app_papel_conteudo());
grant select on conteudos_proposito to anon;

create trigger trg_audit_conteudos_proposito
  after insert or update or delete on conteudos_proposito for each row execute function trg_auditoria_generica('id_conteudo');

-- ---------------------------------------------------------------------
-- 8. Log de atividades — reaproveita log_auditoria (já é hash-encadeado
--    e append-only) para todas as tabelas novas acima; nenhuma tabela
--    nova é necessária para o requisito de governança.
-- ---------------------------------------------------------------------
comment on table log_auditoria is
  'Log append-only hash-encadeado. Cobre: financeiro (0005), eventos/campanhas (0008), e a partir da 0012 também campanha_lancamentos, campanha_documentos, voluntarios, instituicoes_indicadas e conteudos_proposito.';
