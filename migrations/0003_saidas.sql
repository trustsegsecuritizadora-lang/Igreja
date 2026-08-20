-- =====================================================================
-- SGDE — 0003: módulo de Saídas (solicitação → alçada → NF → liquidação)
-- =====================================================================

create table fornecedores (
  id_fornecedor    uuid primary key default gen_random_uuid(),
  razao_social     text not null,
  cnpj_cpf         text not null unique,
  categoria        text not null check (categoria in ('Fornecedor','Prestador_Servico','Pastor_Prebenda')),
  ativo            boolean not null default true
);

-- Dados bancários do fornecedor: sensível, nunca exposto direto pela API
-- pública — só acessível via função SECURITY DEFINER (ver 0006/0009).
create table fornecedores_dados_bancarios (
  fornecedor_id  uuid primary key references fornecedores(id_fornecedor),
  banco          text,
  agencia        text,
  conta          text,
  chave_pix      text,
  atualizado_em  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- ALCADAS_APROVACAO — configurável por valor (igreja única, mas evita
-- hardcode: R$0 a R$500.000,00 = 1 aprovador (Tesoureiro);
-- acima de R$500.000,00 = 2 aprovadores (Tesoureiro + Diretoria)
-- ---------------------------------------------------------------------
create table alcadas_aprovacao (
  id_alcada         uuid primary key default gen_random_uuid(),
  valor_limite      numeric(14,2),   -- limite superior da faixa (null = sem limite)
  papeis_exigidos   text[] not null,          -- ex: '{Tesoureiro}' ou '{Tesoureiro,Diretoria}'
  ordem             int not null unique
);

insert into alcadas_aprovacao (valor_limite, papeis_exigidos, ordem) values
  (500000.00, array['Tesoureiro'], 1),
  (null,      array['Tesoureiro','Diretoria'], 2);

-- ---------------------------------------------------------------------
-- SOLICITACOES_PAGAMENTO
-- ---------------------------------------------------------------------
create table solicitacoes_pagamento (
  id_solicitacao      uuid primary key default gen_random_uuid(),
  fornecedor_id       uuid not null references fornecedores(id_fornecedor),
  centro_custo_id     uuid not null references centros_custo(id_centro),
  valor               numeric(14,2) not null check (valor > 0),
  data_vencimento     date not null,
  descricao           text not null,
  solicitante_id      uuid not null references usuarios(id_usuario),
  status              text not null default 'pendente_aprovacao'
                        check (status in ('pendente_aprovacao','aprovado','reprovado','liquidado')),
  documento_fiscal_id uuid,   -- FK adicionada depois de criar documentos_fiscais (referência circular)
  criado_em           timestamptz not null default now(),
  liquidado_em        timestamptz
);

create table documentos_fiscais (
  id_documento     uuid primary key default gen_random_uuid(),
  solicitacao_id   uuid not null references solicitacoes_pagamento(id_solicitacao),
  tipo             text not null check (tipo in ('NFe','NFSe','RPA','Recibo_Simples')),
  arquivo_url      text not null,
  chave_acesso_nfe text,
  validado_por_id  uuid references usuarios(id_usuario),
  criado_em        timestamptz not null default now()
);

alter table solicitacoes_pagamento
  add constraint fk_solicitacoes_documento_fiscal
  foreign key (documento_fiscal_id) references documentos_fiscais(id_documento);

-- TRAVA: status só pode ser 'liquidado' se houver documento fiscal vinculado
create or replace function trg_liquidacao_exige_documento_fiscal()
returns trigger language plpgsql as $$
begin
  if new.status = 'liquidado' and new.documento_fiscal_id is null then
    raise exception 'Não é possível liquidar sem documento fiscal (NF/RPA) vinculado.';
  end if;
  if new.status = 'liquidado' and old.status <> 'aprovado' then
    raise exception 'Só é possível liquidar uma solicitação que esteja aprovada.';
  end if;
  if new.status = 'liquidado' and new.liquidado_em is null then
    new.liquidado_em := now();
  end if;
  return new;
end;
$$;

create trigger trg_solicitacoes_liquidacao
  before update on solicitacoes_pagamento
  for each row execute function trg_liquidacao_exige_documento_fiscal();

-- ---------------------------------------------------------------------
-- APROVACOES
-- ---------------------------------------------------------------------
create table aprovacoes (
  id_aprovacao   uuid primary key default gen_random_uuid(),
  solicitacao_id uuid not null references solicitacoes_pagamento(id_solicitacao),
  aprovador_id   uuid not null references usuarios(id_usuario),
  nivel_alcada   uuid not null references alcadas_aprovacao(id_alcada),
  decisao        text not null check (decisao in ('aprovado','reprovado')),
  timestamp_decisao timestamptz not null default now(),
  justificativa  text,
  unique (solicitacao_id, aprovador_id)   -- mesmo aprovador não decide duas vezes na mesma solicitação
);

-- TRAVA DURA: solicitante nunca pode aprovar a própria solicitação
-- (aplica-se a TODOS os papéis, sem exceção — inclusive Administrador)
create or replace function trg_aprovacoes_bloqueia_autoaprovacao()
returns trigger language plpgsql as $$
declare
  v_solicitante_id uuid;
begin
  select solicitante_id into v_solicitante_id
    from solicitacoes_pagamento where id_solicitacao = new.solicitacao_id;

  if v_solicitante_id = new.aprovador_id then
    raise exception 'Trava de segregação de função: o solicitante não pode aprovar a própria solicitação.';
  end if;
  return new;
end;
$$;

create trigger trg_aprovacoes_autoaprovacao
  before insert on aprovacoes
  for each row execute function trg_aprovacoes_bloqueia_autoaprovacao();

-- Fecha a solicitação (aprovado/reprovado) quando todos os papéis exigidos
-- pela alçada da faixa de valor já decidiram.
create or replace function processar_decisao_solicitacao()
returns trigger language plpgsql as $$
declare
  v_solicitacao   solicitacoes_pagamento;
  v_alcada        alcadas_aprovacao;
  v_papeis_ok     text[];
  v_reprovado     boolean;
  v_qtd_admin_aprovadores int;
  v_qtd_papeis_faltantes  int;
begin
  select * into v_solicitacao from solicitacoes_pagamento where id_solicitacao = new.solicitacao_id for update;

  select a.* into v_alcada
    from alcadas_aprovacao a
    where v_solicitacao.valor <= coalesce(a.valor_limite, 'infinity'::numeric)
    order by a.ordem asc
    limit 1;

  select exists (
    select 1 from aprovacoes ap
    join usuarios u on u.id_usuario = ap.aprovador_id
    where ap.solicitacao_id = new.solicitacao_id and ap.decisao = 'reprovado'
  ) into v_reprovado;

  if v_reprovado then
    update solicitacoes_pagamento set status = 'reprovado' where id_solicitacao = new.solicitacao_id;
    return new;
  end if;

  -- Um Administrador PREENCHE uma vaga de qualquer papel que falte na
  -- alçada (útil em igrejas pequenas onde a mesma pessoa acumula função),
  -- mas cada vaga ainda exige uma pessoa distinta: a trava
  -- unique(solicitacao_id, aprovador_id) e a de autoaprovação continuam
  -- exigindo assinaturas de humanos diferentes — um único Administrador
  -- aprovando sozinho NÃO basta para uma alçada que exige 2 papéis.
  select array_agg(distinct u.papel) filter (where u.papel <> 'Administrador') into v_papeis_ok
    from aprovacoes ap
    join usuarios u on u.id_usuario = ap.aprovador_id
    where ap.solicitacao_id = new.solicitacao_id and ap.decisao = 'aprovado';

  select count(*) into v_qtd_admin_aprovadores
    from aprovacoes ap
    join usuarios u on u.id_usuario = ap.aprovador_id
    where ap.solicitacao_id = new.solicitacao_id and ap.decisao = 'aprovado' and u.papel = 'Administrador';

  select coalesce(array_length(array(
    select unnest(v_alcada.papeis_exigidos)
    except
    select unnest(coalesce(v_papeis_ok, array[]::text[]))
  ), 1), 0) into v_qtd_papeis_faltantes;

  if v_qtd_papeis_faltantes <= v_qtd_admin_aprovadores then
    update solicitacoes_pagamento set status = 'aprovado' where id_solicitacao = new.solicitacao_id;
  end if;

  return new;
end;
$$;

create trigger trg_aprovacoes_processa_decisao
  after insert on aprovacoes
  for each row execute function processar_decisao_solicitacao();

-- ---------------------------------------------------------------------
-- PREBENDAS_PASTORAIS — tratamento à parte, com aprovação simples
-- registrada (não passa pelo fluxo comum de fornecedor/NF)
-- ---------------------------------------------------------------------
create table prebendas_pastorais (
  id_prebenda        uuid primary key default gen_random_uuid(),
  membro_id          uuid not null references membros(id_membro),
  valor_mensal       numeric(14,2) not null check (valor_mensal > 0),
  data_referencia    date not null,
  tipo               text not null check (tipo in ('Prebenda','Ajuda_Custo','Auxilio_Moradia')),
  status_declaracao  text default 'pendente',
  status             text not null default 'pendente_aprovacao'
                       check (status in ('pendente_aprovacao','aprovado','pago')),
  solicitado_por_id  uuid not null references usuarios(id_usuario),
  aprovado_por_id    uuid references usuarios(id_usuario),
  aprovado_em        timestamptz,
  unique (membro_id, data_referencia, tipo)
);

-- TRAVA: mesma regra de segregação de função vale para prebenda
create or replace function trg_prebenda_bloqueia_autoaprovacao_e_papel()
returns trigger language plpgsql as $$
declare
  v_papel text;
begin
  if new.status = 'aprovado' then
    if new.aprovado_por_id is null then
      raise exception 'Aprovação de prebenda exige aprovador identificado.';
    end if;
    if new.aprovado_por_id = new.solicitado_por_id then
      raise exception 'Trava de segregação de função: quem solicitou a prebenda não pode aprová-la.';
    end if;
    select papel into v_papel from usuarios where id_usuario = new.aprovado_por_id;
    if v_papel not in ('Diretoria','Administrador') then
      raise exception 'Aprovação de prebenda exige papel Diretoria.';
    end if;
    if new.aprovado_em is null then
      new.aprovado_em := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_prebendas_aprovacao
  before update on prebendas_pastorais
  for each row execute function trg_prebenda_bloqueia_autoaprovacao_e_papel();
