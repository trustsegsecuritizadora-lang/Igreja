-- =====================================================================
-- SGDE — 0018: corrige trigger de liquidação (bloqueava editar uma
-- solicitação já liquidada) + permite escolher a data de liquidação
-- =====================================================================
-- Contexto: usuário liquidou solicitações de agosto só hoje (setembro),
-- e como liquidar não deixava escolher a data do pagamento, liquidado_em
-- ficou = hoje (now()) — e por isso essas saídas apareceram no Balancete
-- de setembro, não no de agosto (o Balancete filtra por liquidado_em).
-- A tela (saidas.html) já vai passar a permitir escolher a data na hora
-- de liquidar; o trigger só usa now() quando NENHUMA data é informada
-- (comportamento já existente, mantido).
--
-- Só que ao tentar corrigir liquidado_em de uma solicitação já
-- liquidada, o UPDATE também falhava — e essa é a causa raiz mais grave
-- encontrada aqui: a trigger tinha uma condição escrita pensando só na
-- transição PARA liquidado, mas ela reavalia em QUALQUER UPDATE da
-- linha. Como um UPDATE que não mexe na coluna status mantém
-- new.status = old.status = 'liquidado', a checagem
-- "new.status = 'liquidado' and old.status <> 'aprovado'" ficava
-- verdadeira sempre que a linha já estava liquidada — bloqueando
-- qualquer edição posterior (não só a data; qualquer coluna), mesmo sem
-- nenhuma tentativa de liquidar de novo. Corrigido isolando essa
-- checagem (e a exigência de documento fiscal na transição) para quando
-- a linha está de fato entrando em 'liquidado' agora
-- (old.status is distinct from 'liquidado'). A trava de nunca ficar sem
-- documento fiscal enquanto liquidado continua valendo sempre, inclusive
-- em edições posteriores.

create or replace function trg_liquidacao_exige_documento_fiscal()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Vale sempre, inclusive em edições de uma linha que já estava
  -- liquidada (ex.: corrigir a data de pagamento): nunca pode ficar
  -- liquidada sem documento fiscal vinculado.
  if new.status = 'liquidado' and new.documento_fiscal_id is null then
    raise exception 'Não é possível liquidar sem documento fiscal (NF/RPA) vinculado.';
  end if;

  -- As travas abaixo valem só na transição PARA liquidado — não devem
  -- barrar uma edição feita depois, numa linha que já estava liquidada.
  if new.status = 'liquidado' and old.status is distinct from 'liquidado' then
    if old.status <> 'aprovado' then
      raise exception 'Só é possível liquidar uma solicitação que esteja aprovada.';
    end if;
    if new.liquidado_em is null then
      new.liquidado_em := now();
    end if;
  end if;

  return new;
end;
$$;
