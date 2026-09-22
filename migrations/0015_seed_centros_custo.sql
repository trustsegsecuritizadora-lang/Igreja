-- =====================================================================
-- SGDE — 0015: conjunto inicial de centros de custo
-- =====================================================================
-- Contexto: centros_custo estava vazio — por isso não dava pra lançar
-- nenhuma solicitação em Saídas (o campo é obrigatório) até que alguém
-- cadastrasse o primeiro pela tela (ver commit "Saidas: cadastro inline
-- de centro de custo"). Este seed cobre as frentes mais comuns de
-- contabilidade de igreja, incluindo as que o usuário pediu
-- explicitamente (aquisição de imóvel próprio, despesas cartorárias).
-- Idempotente (on conflict do nothing) — seguro rodar mais de uma vez.

insert into centros_custo (nome) values
  ('Culto e Louvor'),
  ('Escola Sabatina'),
  ('Ministério Infantil'),
  ('Ministério de Jovens e Adolescentes'),
  ('Ministério da Mulher'),
  ('Ministério do Homem'),
  ('Evangelismo e Missões'),
  ('Manutenção Predial'),
  ('Utilidades (Água, Luz, Telefone, Internet)'),
  ('Segurança'),
  ('Limpeza'),
  ('Prebenda Pastoral'),
  ('Secretaria e Administrativo'),
  ('Ação Social'),
  ('Aquisição de Imóvel Próprio'),
  ('Despesas Cartorárias e Registros'),
  ('Reformas e Obras'),
  ('Comunicação e Mídia'),
  ('Eventos e Congressos'),
  ('Literatura e Publicações'),
  ('Transporte e Frota')
on conflict (nome) do nothing;
