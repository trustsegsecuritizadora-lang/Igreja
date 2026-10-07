/* =====================================================================
   SGDE — parsers de extrato bancário (OFX e CSV), 100% client-side.
   Saída padronizada: [{ data: 'YYYY-MM-DD', valor: number, descricao: string, ref: string }]
   `ref` é usado para compor o hash_transacao (evita duplicidade em reimportação).
   ===================================================================== */

function parseOFX(texto) {
  // OFX é SGML "solto" (tags sem fechamento em muitas implementações de
  // banco brasileiro) — extraímos por regex em vez de exigir XML válido.
  const blocos = texto.split(/<STMTTRN>/i).slice(1);
  const movimentos = [];
  for (const bloco of blocos) {
    const trecho = bloco.split(/<\/STMTTRN>/i)[0];
    const campo = (tag) => {
      const m = trecho.match(new RegExp(`<${tag}>([^<\\r\\n]+)`, 'i'));
      return m ? m[1].trim() : '';
    };
    const dtposted = campo('DTPOSTED');   // formato AAAAMMDDHHMMSS ou AAAAMMDD
    const valor = parseFloat(campo('TRNAMT').replace(',', '.'));
    const memo = campo('MEMO') || campo('NAME') || '';
    const fitid = campo('FITID');
    if (!dtposted || isNaN(valor)) continue;
    const data = `${dtposted.slice(0, 4)}-${dtposted.slice(4, 6)}-${dtposted.slice(6, 8)}`;
    movimentos.push({ data, valor, descricao: memo, ref: fitid || `${data}-${valor}-${memo}` });
  }
  return movimentos;
}

// ---------------------------------------------------------------------
// CSV "legado" do Banco do Brasil (extrato baixado direto do site/app do
// BB): sem linha de cabeçalho, 13 colunas separadas por ';', data em
// DD.MM.AAAA (com pontos) e o sinal do valor fica numa coluna separada
// ('C' = crédito/entrada, 'D' = débito/saída) em vez de embutido no
// número. Ex. de linha real:
//   12513;000000466506; ;15.09.2026;15.09.2026;0000;13105;...;144;Pix - Enviado            ;450,00;D;15/09 16:24 ONR
// Colunas usadas: [3]=data, [8]=código histórico, [9]=histórico,
// [10]=valor (sem sinal), [11]=indicador C/D, [12]=complemento.
function pareceExtratoBBLegado(linhas) {
  if (!linhas.length) return false;
  const cols = linhas[0].split(';');
  return cols.length >= 12
    && /^\d{2}\.\d{2}\.\d{4}$/.test((cols[3] || '').trim())
    && /^[CD]$/i.test((cols[11] || '').trim());
}

function parseCSVExtratoBBLegado(linhas) {
  const movimentos = [];
  for (let i = 0; i < linhas.length; i++) {
    const cols = linhas[i].split(';');
    if (cols.length < 12) continue;

    const dataRaw = (cols[3] || '').trim();
    const m = dataRaw.match(/^(\d{2})\.(\d{2})\.(\d{4})$/);
    if (!m) continue;
    const data = `${m[3]}-${m[2]}-${m[1]}`;

    const codigoHistorico = (cols[8] || '').trim();
    const historico = (cols[9] || '').trim();
    // Linhas de saldo (abertura/fechamento do período do extrato) não são
    // movimentos de verdade — códigos reservados 000/999, ou histórico
    // "Saldo Anterior"/"S A L D O".
    if (codigoHistorico === '000' || codigoHistorico === '999' || /^s\s*a\s*l\s*d\s*o/i.test(historico)) continue;
    // "BB Rende Fácil" é a aplicação automática de saldo ocioso do próprio
    // BB: toda vez que uma saída sai da conta, o banco resgata o valor
    // equivalente do Rende Fácil (e vice-versa quando entra dinheiro),
    // gerando um lançamento espelho de mesmo valor/data. Não é receita
    // nem despesa da igreja — é só o banco movendo o saldo entre a conta
    // corrente e a aplicação automática — então não entra como movimento.
    const historicoSemAcento = historico.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    if (historicoSemAcento.includes('rende facil')) continue;

    const indicador = (cols[11] || '').trim().toUpperCase();
    const valorAbs = parseFloat((cols[10] || '').trim().replace(/\./g, '').replace(',', '.'));
    if (isNaN(valorAbs)) continue;
    const valor = indicador === 'D' ? -valorAbs : valorAbs;

    const complemento = (cols[12] || '').trim();
    const descricao = complemento ? `${historico} — ${complemento}` : historico;

    movimentos.push({ data, valor, descricao, ref: `${data}-${valor}-${historico}-${i}` });
  }
  return movimentos;
}

function parseCSV(texto) {
  const linhas = texto.split(/\r?\n/).filter(l => l.trim().length > 0);
  if (linhas.length < 1) return [];

  if (pareceExtratoBBLegado(linhas)) {
    return parseCSVExtratoBBLegado(linhas);
  }

  // Formato genérico: espera cabeçalho com colunas data,valor,descricao
  // (nessa ordem ou nomeadas). Aceita separador ; ou ,. Datas em
  // DD/MM/AAAA ou AAAA-MM-DD.
  if (linhas.length < 2) return [];
  const sep = linhas[0].includes(';') ? ';' : ',';
  const cab = linhas[0].split(sep).map(c => c.trim().toLowerCase());
  const idxData = cab.findIndex(c => c.includes('data'));
  const idxValor = cab.findIndex(c => c.includes('valor'));
  const idxDesc = cab.findIndex(c => c.includes('desc') || c.includes('hist'));

  const movimentos = [];
  for (let i = 1; i < linhas.length; i++) {
    const cols = linhas[i].split(sep);
    if (cols.length < 2) continue;
    let dataRaw = (cols[idxData >= 0 ? idxData : 0] || '').trim();
    let valorRaw = (cols[idxValor >= 0 ? idxValor : 1] || '').trim().replace(/\./g, '').replace(',', '.');
    const descricao = (cols[idxDesc >= 0 ? idxDesc : 2] || '').trim();

    let data;
    if (/^\d{2}\/\d{2}\/\d{4}$/.test(dataRaw)) {
      const [d, m, a] = dataRaw.split('/');
      data = `${a}-${m}-${d}`;
    } else if (/^\d{4}-\d{2}-\d{2}$/.test(dataRaw)) {
      data = dataRaw;
    } else {
      continue;
    }
    const valor = parseFloat(valorRaw);
    if (isNaN(valor)) continue;
    movimentos.push({ data, valor, descricao, ref: `${data}-${valor}-${descricao}-${i}` });
  }
  return movimentos;
}

// Lê o arquivo tentando UTF-8 primeiro; extratos de bancos brasileiros
// (ex.: este CSV legado do BB) costumam vir em ISO-8859-1/Windows-1252,
// o que sem isso vira "F�cil" em vez de "Fácil" em todo acento do
// histórico. TextDecoder com fatal:true rejeita bytes que não são UTF-8
// válido, então cai para ISO-8859-1 automaticamente nesse caso.
async function lerTextoArquivoBancario(arquivo) {
  const buf = await arquivo.arrayBuffer();
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch (e) {
    return new TextDecoder('iso-8859-1').decode(buf);
  }
}

async function hashSha256Hex(texto) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}
