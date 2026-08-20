-- =====================================================================
-- SGDE — 0009: configurações públicas do site (ex: chave PIX de doação
-- avulsa), editável só por Administrador, leitura livre para anon.
-- =====================================================================

create table configuracoes_publicas (
  chave        text primary key,
  valor        text not null,
  descricao    text,
  atualizado_em timestamptz not null default now(),
  atualizado_por_id uuid references usuarios(id_usuario)
);

alter table configuracoes_publicas enable row level security;

create policy p_config_publica_select on configuracoes_publicas
  for select to anon, authenticated using (true);

create policy p_config_publica_write on configuracoes_publicas
  for all using (app_papel() = 'Administrador') with check (app_papel() = 'Administrador');

grant select on configuracoes_publicas to anon;

insert into configuracoes_publicas (chave, valor, descricao) values
  ('pix_doacao_avulsa', '1d3dc28b-dec0-4dac-ba1b-fb257f6cbb21', 'Chave PIX aleatória para doações espontâneas exibida no site público.');

create trigger trg_audit_configuracoes_publicas
  after insert or update or delete on configuracoes_publicas
  for each row execute function trg_auditoria_generica('chave');
