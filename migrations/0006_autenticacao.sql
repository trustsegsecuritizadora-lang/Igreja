-- =====================================================================
-- SGDE — 0006: autenticação (hash SHA-256 + salt, sessão deslizante 12h)
-- Mesmo padrão usado nos demais sistemas (Codigo_ContaCorrente.gs /
-- Codigo_ControleNF.gs / Codigo_NecessidadeCaixa.gs), portado para
-- funções SECURITY DEFINER no Postgres.
-- =====================================================================

create or replace function hash_senha(p_senha text, p_salt text)
returns text
language sql immutable
set search_path = public, extensions   -- digest() mora em "extensions" nos projetos Supabase
as $$
  select encode(digest(p_salt || '::' || p_senha, 'sha256'), 'hex');
$$;

-- Cria usuário (uso restrito a Administrador — checado na camada de API/RLS)
create or replace function criar_usuario(
  p_login text, p_senha text, p_nome text, p_papel text, p_membro_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public, extensions   -- gen_random_bytes() mora em "extensions" nos projetos Supabase
as $$
declare
  v_salt text := encode(gen_random_bytes(16), 'hex');
  v_id   uuid;
begin
  insert into usuarios (login, hash_senha, salt, nome, papel, membro_id)
    values (lower(trim(p_login)), hash_senha(p_senha, v_salt), v_salt, p_nome, p_papel, p_membro_id)
    returning id_usuario into v_id;
  return v_id;
end;
$$;

-- Login: valida credenciais, cria sessão deslizante de 12h
create or replace function login(p_login text, p_senha text)
returns table(token uuid, papel text, nome text, usuario_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario usuarios%rowtype;
  v_token   uuid;
begin
  select * into v_usuario from usuarios
    where login = lower(trim(p_login)) and status = 'ativo';

  if v_usuario is null or v_usuario.hash_senha <> hash_senha(p_senha, v_usuario.salt) then
    perform registrar_auditoria(null, 'usuarios', coalesce(v_usuario.id_usuario::text, p_login), 'UPDATE',
      null, jsonb_build_object('evento','login_falhou','login_tentado',p_login));
    raise exception 'Usuário ou senha inválidos.';
  end if;

  insert into sessoes (usuario_id, papel, expira_em)
    values (v_usuario.id_usuario, v_usuario.papel, now() + interval '12 hours')
    returning sessoes.token into v_token;

  delete from sessoes where expira_em < now();

  perform registrar_auditoria(v_usuario.id_usuario, 'sessoes', v_token::text, 'INSERT',
    null, jsonb_build_object('evento','login'));

  return query select v_token, v_usuario.papel, v_usuario.nome, v_usuario.id_usuario;
end;
$$;

create or replace function logout(p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sessao sessoes%rowtype;
begin
  select * into v_sessao from sessoes where token = p_token;
  if v_sessao is null then
    return true;
  end if;
  delete from sessoes where token = p_token;
  perform registrar_auditoria(v_sessao.usuario_id, 'sessoes', p_token::text, 'DELETE', null,
    jsonb_build_object('evento','logout'));
  return true;
end;
$$;

-- Valida sessão e renova a expiração (sessão deslizante). Deve ser chamada
-- no início de toda operação sensível, e o resultado usado para popular
-- as variáveis de sessão (app.usuario_id / app.papel) que as policies de
-- RLS e os triggers de auditoria consultam.
create or replace function verificar_sessao(p_token uuid)
returns table(usuario_id uuid, papel text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sessao sessoes%rowtype;
begin
  select * into v_sessao from sessoes where token = p_token;
  if v_sessao is null then
    raise exception 'Sessão inválida. Faça login novamente.';
  end if;
  if v_sessao.expira_em < now() then
    delete from sessoes where token = p_token;
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  update sessoes set expira_em = now() + interval '12 hours' where token = p_token;

  perform set_config('app.usuario_id', v_sessao.usuario_id::text, true);
  perform set_config('app.papel', v_sessao.papel, true);

  return query select v_sessao.usuario_id, v_sessao.papel;
end;
$$;

-- ---------------------------------------------------------------------
-- Acesso a dados sensíveis SÓ via função SECURITY DEFINER, nunca pela
-- API pública direta: dados bancários de fornecedor e valor de prebenda.
-- ---------------------------------------------------------------------
create or replace function obter_dados_bancarios_fornecedor(p_token uuid, p_fornecedor_id uuid)
returns fornecedores_dados_bancarios
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sessao record;
  v_dados fornecedores_dados_bancarios;
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel not in ('Administrador','Tesoureiro','Diretoria','Auditor_Externo') then
    raise exception 'Acesso negado a dados bancários de fornecedor.';
  end if;

  select * into v_dados from fornecedores_dados_bancarios where fornecedor_id = p_fornecedor_id;

  perform registrar_auditoria(v_sessao.usuario_id, 'fornecedores_dados_bancarios', p_fornecedor_id::text,
    'EXPORT', null, jsonb_build_object('evento','consulta_dados_bancarios'));

  return v_dados;
end;
$$;

revoke all on fornecedores_dados_bancarios from anon, authenticated;
revoke all on log_auditoria from anon, authenticated;
