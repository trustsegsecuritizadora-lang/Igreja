-- =====================================================================
-- SGDE — 0016: redefinir_senha_usuario — Administrador reseta a senha
-- de um usuário
-- =====================================================================
-- Contexto: senha nunca é armazenada em texto puro (só hash_senha +
-- salt), então não existe — nem pra mim, nem pra ninguém — um jeito de
-- "ver" a senha de um usuário depois de criada. Isso é proposital (boa
-- prática de segurança), mas faltava a contrapartida óbvia: uma forma
-- de redefinir a senha quando ela se perde, sem precisar recriar o
-- usuário do zero. Mesmo padrão de validação de sessão/papel das
-- funções SECURITY DEFINER já existentes (criar_usuario, fechar_lote
-- etc. — ver 0011).

create or replace function redefinir_senha_usuario(p_token uuid, p_usuario_id uuid, p_nova_senha text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sessao record;
  v_salt   text := encode(gen_random_bytes(16), 'hex');
begin
  select * into v_sessao from verificar_sessao(p_token);
  if v_sessao.papel <> 'Administrador' then
    raise exception 'Apenas Administrador pode redefinir senha de usuário.';
  end if;

  if p_nova_senha is null or length(p_nova_senha) < 6 then
    raise exception 'A nova senha deve ter pelo menos 6 caracteres.';
  end if;

  update usuarios set hash_senha = hash_senha(p_nova_senha, v_salt), salt = v_salt
    where id_usuario = p_usuario_id;

  if not found then
    raise exception 'Usuário não encontrado.';
  end if;

  perform registrar_auditoria(v_sessao.usuario_id, 'usuarios', p_usuario_id::text, 'UPDATE',
    null, jsonb_build_object('evento', 'senha_redefinida'));
end;
$$;
