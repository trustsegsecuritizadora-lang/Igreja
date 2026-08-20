-- =====================================================================
-- SGDE — 0002: módulo de Entradas (lote → contagem dupla → lançamento → recibo)
-- =====================================================================

create table centros_custo (
  id_centro        uuid primary key default gen_random_uuid(),
  nome             text not null unique,
  orcamento_anual  numeric(14,2),
  ativo            boolean not null default true
);

-- ---------------------------------------------------------------------
-- LOTES_ARRECADACAO — o "envelope" de cada culto/evento
-- ---------------------------------------------------------------------
create table lotes_arrecadacao (
  id_lote              uuid primary key default gen_random_uuid(),
  data_culto           date not null,
  tipo_culto           text not null,
  valor_apurado_total  numeric(14,2) not null check (valor_apurado_total >= 0),
  status               text not null default 'aberto'
                         check (status in ('aberto','aguardando_conferencia','conferido',
                                            'depositado','divergente')),
  usuario_abertura_id  uuid not null references usuarios(id_usuario),
  criado_em            timestamptz not null default now(),
  fechado_em           timestamptz
);

-- ---------------------------------------------------------------------
-- CONTAGEM_LOTE — trava de dupla checagem
-- ---------------------------------------------------------------------
create table contagem_lote (
  id_contagem            uuid primary key default gen_random_uuid(),
  lote_id                uuid not null references lotes_arrecadacao(id_lote),
  usuario_conferente_id  uuid not null references usuarios(id_usuario),
  valor_contado          numeric(14,2) not null check (valor_contado >= 0),
  timestamp_conferencia  timestamptz not null default now(),
  de_acordo              boolean not null,
  justificativa_divergencia text,
  -- mesmo conferente não pode contar o mesmo lote duas vezes
  unique (lote_id, usuario_conferente_id)
);

-- Exige justificativa sempre que a contagem não bate com o valor apurado do lote
create or replace function trg_contagem_exige_justificativa()
returns trigger language plpgsql as $$
declare
  v_valor_lote numeric(14,2);
  v_tolerancia numeric(14,2) := 0.01;
begin
  select valor_apurado_total into v_valor_lote
    from lotes_arrecadacao where id_lote = new.lote_id;

  if abs(new.valor_contado - v_valor_lote) > v_tolerancia then
    new.de_acordo := false;
    if new.justificativa_divergencia is null or length(trim(new.justificativa_divergencia)) = 0 then
      raise exception 'Contagem divergente do valor apurado do lote: é obrigatório registrar justificativa.';
    end if;
  else
    new.de_acordo := true;
  end if;
  return new;
end;
$$;

create trigger trg_contagem_lote_justificativa
  before insert or update on contagem_lote
  for each row execute function trg_contagem_exige_justificativa();

-- ---------------------------------------------------------------------
-- LANCAMENTOS_ENTRADA
-- ---------------------------------------------------------------------
create table lancamentos_entrada (
  id_entrada         uuid primary key default gen_random_uuid(),
  lote_id            uuid references lotes_arrecadacao(id_lote),   -- nullable: PIX direto
  membro_id          uuid references membros(id_membro),           -- nullable: oferta anônima
  tipo_entrada       text not null
                       check (tipo_entrada in ('Dizimo','Oferta_Geral','Oferta_Missionaria',
                                                'Oferta_Especial','Doacao_Patrimonial','Voto')),
  valor              numeric(14,2) not null check (valor > 0),
  forma_recebimento  text not null check (forma_recebimento in ('Especie','PIX','Cartao','Transferencia')),
  centro_custo_id    uuid references centros_custo(id_centro),
  criado_por_id      uuid not null references usuarios(id_usuario),
  criado_em          timestamptz not null default now()
);

-- Dízimo identificado exige membro vinculado (para fins de recibo/dedução)
alter table lancamentos_entrada
  add constraint chk_dizimo_precisa_membro
  check (tipo_entrada <> 'Dizimo' or membro_id is not null);

create index idx_lancamentos_entrada_lote on lancamentos_entrada(lote_id);
create index idx_lancamentos_entrada_membro on lancamentos_entrada(membro_id);

-- ---------------------------------------------------------------------
-- RECIBOS — numeração sequencial imutável, reinicia por ano civil
-- ---------------------------------------------------------------------
create table recibos (
  id_recibo       uuid primary key default gen_random_uuid(),
  entrada_id      uuid not null unique references lancamentos_entrada(id_entrada),
  ano_referencia  int not null,
  numero_recibo   int not null,
  hash_documento  text not null,
  data_emissao    timestamptz not null default now(),
  unique (ano_referencia, numero_recibo)
);

-- contador por ano civil (uma linha por ano, incrementada de forma atômica)
create table recibos_contador_anual (
  ano_referencia  int primary key,
  ultimo_numero   int not null default 0
);

create or replace function emitir_recibo(p_entrada_id uuid)
returns recibos
language plpgsql
security definer
set search_path = public, extensions   -- digest() mora em "extensions" nos projetos Supabase
as $$
declare
  v_ano      int := extract(year from now())::int;
  v_numero   int;
  v_valor    numeric(14,2);
  v_recibo   recibos;
begin
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

alter table lancamentos_entrada add column recibo_id_cache uuid references recibos(id_recibo);

-- Nunca permitir UPDATE ou DELETE de recibo já emitido (imutabilidade)
create or replace function trg_recibos_imutavel()
returns trigger language plpgsql as $$
begin
  raise exception 'Recibos são imutáveis: não podem ser alterados nem excluídos.';
end;
$$;

create trigger trg_recibos_bloqueia_update
  before update on recibos
  for each row execute function trg_recibos_imutavel();

create trigger trg_recibos_bloqueia_delete
  before delete on recibos
  for each row execute function trg_recibos_imutavel();

-- ---------------------------------------------------------------------
-- Fechamento do lote — só permite avançar para 'conferido' quando:
--   (a) existem >= 2 contagens com de_acordo = true e valores convergentes
--   (b) soma dos lançamentos = valor_apurado_total
-- ---------------------------------------------------------------------
create or replace function fechar_lote(p_lote_id uuid, p_usuario_id uuid)
returns lotes_arrecadacao
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lote            lotes_arrecadacao;
  v_qtd_conferencias int;
  v_soma_lancamentos numeric(14,2);
  v_tolerancia       numeric(14,2) := 0.01;
begin
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
