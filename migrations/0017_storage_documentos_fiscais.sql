-- =====================================================================
-- SGDE — 0017: bucket de Storage para anexar NF/RPA em Saídas
-- =====================================================================
-- Contexto: "Anexar NF/RPA" (pré-requisito pra Liquidar) pedia uma URL já
-- hospedada via prompt() — mas não existia nenhum bucket de Storage no
-- projeto, então na prática ninguém conseguia anexar nada, nenhuma saída
-- avançava de 'aprovado' pra 'liquidado', e por isso: (a) o Balancete não
-- listava essas saídas (só soma status='liquidado') e (b) a conciliação
-- bancária automática nunca casava despesas (mesma exigência de
-- status='liquidado'). Este bucket + políticas resolve o gargalo.
--
-- Bucket privado (não público) — os documentos fiscais não ficam
-- acessíveis por URL direta; a visualização usa signed URL, gerada sob
-- demanda a partir do client (ver saidas.html: verDocumento()).
--
-- Políticas de storage.objects seguem o mesmo modelo de confiança já
-- usado no restante do app: operações client-side com a chave anon,
-- sem depender de auth.uid() (não há Supabase Auth aqui — a sessão é
-- própria, validada em funções SECURITY DEFINER). Aqui não há uma
-- SECURITY DEFINER function server-side pra mediar o upload porque a
-- Storage API do Supabase não passa por RPC; a política fica restrita
-- ao bucket específico.

insert into storage.buckets (id, name, public)
values ('documentos-fiscais', 'documentos-fiscais', false)
on conflict (id) do nothing;

drop policy if exists "documentos_fiscais_insert" on storage.objects;
create policy "documentos_fiscais_insert" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'documentos-fiscais');

drop policy if exists "documentos_fiscais_select" on storage.objects;
create policy "documentos_fiscais_select" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'documentos-fiscais');
