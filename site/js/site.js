/* =====================================================================
   ISSD — site público. Utilitários compartilhados entre index.html,
   eventos.html e as páginas de campanha.
   ===================================================================== */

const SUPABASE_URL = 'https://fragxrqofweahrhgozhq.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZyYWd4cnFvZndlYWhyaGdvemhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzcyNzUsImV4cCI6MjEwMjgxMzI3NX0.A1mEQtBloGuuJJt9QhL7002RHCgBKOV5dIPdCsTvVyo';
// Site 100% público: só a anon key, sem sessão. RLS garante que apenas
// linhas com publicado=true (e, em campanha_parceiros, autorizado_exibir=true)
// chegam até aqui.
window.supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function formatarMoeda(v) {
  return (Number(v) || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

function formatarDataLonga(iso) {
  return new Date(iso + 'T00:00:00').toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric' });
}

// Contagem regressiva simples em dias inteiros até uma data-limite (string YYYY-MM-DD).
function diasRestantes(dataLimiteISO) {
  const hoje = new Date(); hoje.setHours(0, 0, 0, 0);
  const alvo = new Date(dataLimiteISO + 'T00:00:00');
  return Math.max(0, Math.ceil((alvo - hoje) / 86400000));
}

// Chave PIX de doação avulsa: usada tanto na seção "Generosidade" da Home
// quanto na doação avulsa de eventos.html.
async function carregarChavePixAvulsa(elChaveId = 'chave-pix', elWrapId = 'chave-pix-wrap', elBtnId = 'btn-copiar-pix') {
  const { data } = await supabase.from('configuracoes_publicas').select('valor').eq('chave', 'pix_doacao_avulsa').maybeSingle();
  if (data && data.valor) {
    const elChave = document.getElementById(elChaveId);
    const elWrap = document.getElementById(elWrapId);
    const elBtn = document.getElementById(elBtnId);
    if (!elChave || !elWrap || !elBtn) return;
    elChave.textContent = data.valor;
    elWrap.style.display = 'flex';
    elBtn.addEventListener('click', () => {
      navigator.clipboard.writeText(data.valor);
      elBtn.textContent = 'Copiado!';
      setTimeout(() => { elBtn.textContent = 'Copiar chave'; }, 2000);
    });
  }
}

// Progresso real (arrecadado) de todas as campanhas publicadas, via RPC que já
// existe no banco (campanha_progresso_publica) — nunca estimado no front.
async function carregarProgressoCampanhas() {
  const { data } = await supabase.rpc('campanha_progresso_publica');
  const porId = {};
  (data || []).forEach(p => { porId[p.id_campanha] = Number(p.valor_arrecadado) || 0; });
  return porId;
}

// Próximo culto — vem de configuracoes_publicas (proximo_culto_dia / proximo_culto_horario),
// administrável sem hardcode.
async function carregarProximoCulto() {
  const { data } = await supabase.from('configuracoes_publicas').select('chave, valor')
    .in('chave', ['proximo_culto_dia', 'proximo_culto_horario']);
  const porChave = Object.fromEntries((data || []).map(r => [r.chave, r.valor]));
  return { dia: porChave.proximo_culto_dia || '—', horario: porChave.proximo_culto_horario || '—' };
}

// Scroll reveal discreto (respeita prefers-reduced-motion via CSS já sem transição).
function ativarRevelacaoScroll() {
  const alvos = document.querySelectorAll('.reveal');
  if (!alvos.length) return;
  if (!('IntersectionObserver' in window)) { alvos.forEach(el => el.classList.add('in')); return; }
  const obs = new IntersectionObserver((entries) => {
    entries.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); obs.unobserve(e.target); } });
  }, { threshold: 0.12 });
  alvos.forEach(el => obs.observe(el));
}

document.addEventListener('DOMContentLoaded', ativarRevelacaoScroll);
