-- =====================================================================
-- SGDE — Sistema de Gestão Digital Eclesiástico
-- 0001: extensões + núcleo (pessoas, estrutura, usuários, sessões)
-- =====================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid(), digest()

-- ---------------------------------------------------------------------
-- DEPARTAMENTOS
-- ---------------------------------------------------------------------
create table departamentos (
  id_departamento   uuid primary key default gen_random_uuid(),
  nome              text not null unique,
  lider_id          uuid,               -- FK -> membros, adicionada depois (referência circular)
  criado_em         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- MEMBROS
-- ---------------------------------------------------------------------
create table membros (
  id_membro                 uuid primary key default gen_random_uuid(),
  nome                      text not null,
  cpf                       text unique,
  data_nascimento           date,
  contato                   text,
  status                    text not null default 'ativo'
                              check (status in ('ativo','afastado','transferido','disciplinado')),
  departamento_id           uuid references departamentos(id_departamento),
  data_ingresso             date,
  data_batismo              date,
  responsavel_cadastro_id   uuid,       -- FK -> usuarios, adicionada depois
  criado_em                 timestamptz not null default now()
);

alter table departamentos
  add constraint fk_departamentos_lider
  foreign key (lider_id) references membros(id_membro);

-- ---------------------------------------------------------------------
-- USUARIOS (acesso ao sistema — nem todo membro é usuário)
-- Papéis: Administrador, Tesoureiro, Diretoria, Secretaria, Pastor,
--         Auditor_Externo, Contador
-- ---------------------------------------------------------------------
create table usuarios (
  id_usuario     uuid primary key default gen_random_uuid(),
  membro_id      uuid references membros(id_membro),  -- nullable: contador/auditor externo
  login          text not null unique,
  nome           text not null,
  papel          text not null
                   check (papel in ('Administrador','Tesoureiro','Diretoria','Secretaria',
                                     'Pastor','Auditor_Externo','Contador')),
  hash_senha     text not null,
  salt           text not null,
  mfa_ativo      boolean not null default false,
  status         text not null default 'ativo' check (status in ('ativo','revogado')),
  criado_em      timestamptz not null default now()
);

alter table membros
  add constraint fk_membros_responsavel_cadastro
  foreign key (responsavel_cadastro_id) references usuarios(id_usuario);

-- Impede remover/desativar o último Administrador ativo (trava operacional,
-- não é regra financeira mas evita lockout do sistema)
create or replace function trg_impedir_remocao_ultimo_admin()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'UPDATE' and old.papel = 'Administrador' and old.status = 'ativo'
     and (new.papel <> 'Administrador' or new.status <> 'ativo') then
    if (select count(*) from usuarios
        where papel = 'Administrador' and status = 'ativo' and id_usuario <> old.id_usuario) = 0 then
      raise exception 'Não é possível remover/desativar o único Administrador ativo do sistema.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_usuarios_protege_admin
  before update on usuarios
  for each row execute function trg_impedir_remocao_ultimo_admin();

-- ---------------------------------------------------------------------
-- SESSOES (sessão deslizante de 12h — mesmo padrão dos outros sistemas)
-- ---------------------------------------------------------------------
create table sessoes (
  token        uuid primary key default gen_random_uuid(),
  usuario_id   uuid not null references usuarios(id_usuario),
  papel        text not null,
  criada_em    timestamptz not null default now(),
  expira_em    timestamptz not null
);

create index idx_sessoes_expira_em on sessoes(expira_em);

comment on table usuarios is 'Papel Administrador gerencia usuários/senhas/papéis; demais papéis operam os módulos financeiros conforme alçada.';
