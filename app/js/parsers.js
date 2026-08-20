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

function parseCSV(texto) {
  // Espera cabeçalho com colunas data,valor,descricao (nessa ordem ou
  // nomeadas). Aceita separador ; ou ,. Datas em DD/MM/AAAA ou AAAA-MM-DD.
  const linhas = texto.split(/\r?\n/).filter(l => l.trim().length > 0);
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

async function hashSha256Hex(texto) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}
