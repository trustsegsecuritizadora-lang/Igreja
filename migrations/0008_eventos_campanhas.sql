-- =====================================================================
-- SGDE — 0008: Eventos, Campanhas e área pública (site institucional)
-- Estas tabelas têm um recorte PÚBLICO (publicado=true, legível por
-- qualquer visitante sem login) além do uso interno pela Diretoria/
-- Secretaria. Isso é uma exceção deliberada ao padrão "sem sessão =
-- sem acesso" das tabelas financeiras — nada sensível é exposto aqui.
-- =====================================================================

create table eventos (
  id_evento         uuid primary key default gen_random_uuid(),
  titulo            text not null,
  descricao         text,
  data_inicio       timestamptz not null,
  data_fim          timestamptz,
  local             text,
  imagem_url        text,
  inscricao_aberta  boolean not null default false,
  vagas_limite      int,
  publicado         boolean not null default false,
  criado_por_id     uuid not null references usuarios(id_usuario),
  criado_em         timestamptz not null default now()
);

create index idx_eventos_publicado_data on eventos(publicado, data_inicio);

create table inscricoes_evento (
  id_inscricao   uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references eventos(id_evento),
  nome           text not null,
  contato        text not null,   -- e-mail ou telefone, formulário público
  membro_id      uuid references membros(id_membro),  -- nullable: visitante não-membro
  criado_em      timestamptz not null default now(),
  unique (evento_id, contato)
);

-- Trava: não permite inscrição além do limite de vagas, nem em evento fechado
create or replace function trg_inscricao_valida_vagas()
returns trigger language plpgsql as $$
declare
  v_evento eventos%rowtype;
  v_total  int;
begin
  select * into v_evento from eventos where id_evento = new.evento_id;
  if v_evento is null or not v_evento.inscricao_aberta then
    raise exception 'Inscrições não estão abertas para este evento.';
  end if;
  if v_evento.vagas_limite is not null then
    select count(*) into v_total from inscricoes_evento where evento_id = new.evento_id;
    if v_total >= v_evento.vagas_limite then
      raise exception 'Vagas esgotadas para este evento.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_inscricoes_valida_vagas
  before insert on inscricoes_evento
  for each row execute function trg_inscricao_valida_vagas();

create table campanhas (
  id_campanha       uuid primary key default gen_random_uuid(),
  titulo            text not null,
  descricao         text,
  meta_valor        numeric(14,2),
  data_inicio       date not null,
  data_fim          date,
  centro_custo_id   uuid references centros_custo(id_centro),   -- liga a doação ao centro de custo correto
  imagem_url        text,
  publicado         boolean not null default false,
  criado_por_id     uuid not null references usuarios(id_usuario),
  criado_em         timestamptz not null default now()
);

create index idx_campanhas_publicado on campanhas(publicado, data_fim);

-- Doação de campanha é só uma etiqueta sobre um lançamento de entrada já
-- existente (Oferta_Especial/Doacao_Patrimonial) — não duplica o dado
-- financeiro, só amarra o lançamento à campanha para relatório de meta.
create table campanha_doacoes (
  id_campanha_doacao  uuid primary key default gen_random_uuid(),
  campanha_id         uuid not null references campanhas(id_campanha),
  entrada_id          uuid not null unique references lancamentos_entrada(id_entrada)
);

-- Progresso público de campanha — função SECURITY DEFINER (não uma view
-- comum) porque uma view roda com os privilégios de quem consulta: um
-- visitante anônimo esbarraria na RLS de lancamentos_entrada/campanha_doacoes
-- e sempre veria zero. A função contorna isso de propósito, mas só devolve
-- o agregado (total arrecadado + quantidade), nunca lançamentos individuais
-- nem identidade de doador.
create or replace function campanha_progresso_publica()
returns table(id_campanha uuid, titulo text, meta_valor numeric, valor_arrecadado numeric, qtd_doacoes bigint)
language sql
security definer
set search_path = public
stable
as $$
  select c.id_campanha, c.titulo, c.meta_valor,
         coalesce(sum(le.valor), 0) as valor_arrecadado,
         count(cd.id_campanha_doacao) as qtd_doacoes
  from campanhas c
  left join campanha_doacoes cd on cd.campanha_id = c.id_campanha
  left join lancamentos_entrada le on le.id_entrada = cd.entrada_id
  where c.publicado = true
  group by c.id_campanha, c.titulo, c.meta_valor;
$$;

revoke all on campanha_doacoes from anon;
grant execute on function campanha_progresso_publica() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Auditoria (mesmo padrão das demais tabelas de gestão)
-- ---------------------------------------------------------------------
create trigger trg_audit_eventos
  after insert or update or delete on eventos
  for each row execute function trg_auditoria_generica('id_evento');

create trigger trg_audit_campanhas
  after insert or update or delete on campanhas
  for each row execute function trg_auditoria_generica('id_campanha');

-- ---------------------------------------------------------------------
-- RLS: leitura pública (só do que está publicado=true), escrita restrita
-- a Secretaria/Diretoria/Administrador.
-- ---------------------------------------------------------------------
alter table eventos enable row level security;
alter table inscricoes_evento enable row level security;
alter table campanhas enable row level security;
alter table campanha_doacoes enable row level security;

create or replace function app_papel_conteudo() returns boolean
language sql stable as $$
  select app_papel() in ('Administrador','Diretoria','Secretaria')
$$;

create policy p_eventos_select_publico on eventos for select
  to anon, authenticated using (publicado = true);
create policy p_eventos_select_interno on eventos for select
  using (app_usuario_id() is not null);
create policy p_eventos_insert on eventos for insert with check (app_papel_conteudo());
create policy p_eventos_update on eventos for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
create policy p_eventos_delete on eventos for delete using (app_papel_conteudo());

-- Inscrição: qualquer visitante (mesmo sem login) pode se inscrever;
-- só a equipe interna lista/gerencia inscritos.
create policy p_inscricoes_insert_publico on inscricoes_evento for insert
  to anon, authenticated with check (true);
create policy p_inscricoes_select_interno on inscricoes_evento for select
  using (app_usuario_id() is not null);
create policy p_inscricoes_delete on inscricoes_evento for delete using (app_papel_conteudo());

create policy p_campanhas_select_publico on campanhas for select
  to anon, authenticated using (publicado = true);
create policy p_campanhas_select_interno on campanhas for select
  using (app_usuario_id() is not null);
create policy p_campanhas_insert on campanhas for insert with check (app_papel_conteudo());
create policy p_campanhas_update on campanhas for update
  using (app_papel_conteudo()) with check (app_papel_conteudo());
create policy p_campanhas_delete on campanhas for delete using (app_papel_conteudo());

create policy p_campanha_doacoes_select on campanha_doacoes for select using (app_usuario_id() is not null);
create policy p_campanha_doacoes_write on campanha_doacoes for insert with check (app_papel_pode_escrever());

grant select on eventos, campanhas to anon;
grant insert on inscricoes_evento to anon;

comment on table eventos is 'publicado=true expõe o evento no site público (sem sessão); demais campos internos seguem RLS padrão.';
comment on function campanha_progresso_publica() is 'Visão pública agregada — nunca expõe lançamentos individuais de doadores.';
