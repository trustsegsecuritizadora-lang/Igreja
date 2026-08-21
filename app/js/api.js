/* =====================================================================
   SGDE — camada fina sobre o Supabase JS client.
   Preencha SUPABASE_URL / SUPABASE_ANON_KEY antes de publicar.
   Sessão (token) fica em sessionStorage — some ao fechar a aba, como
   convém a um sistema financeiro (não usa localStorage persistente).
   ===================================================================== */

const SUPABASE_URL = 'https://fragxrqofweahrhgozhq.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZyYWd4cnFvZndlYWhyaGdvemhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzcyNzUsImV4cCI6MjEwMjgxMzI3NX0.A1mEQtBloGuuJJt9QhL7002RHCgBKOV5dIPdCsTvVyo';

window.supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);


const SGDE = (() => {
  function getToken() { return sessionStorage.getItem('sgde_token'); }
  function getSessao() {
    const raw = sessionStorage.getItem('sgde_sessao');
    return raw ? JSON.parse(raw) : null;
  }
  function setSessao(dados) {
    sessionStorage.setItem('sgde_token', dados.token);
    sessionStorage.setItem('sgde_sessao', JSON.stringify(dados));
  }
  function limparSessao() {
    sessionStorage.removeItem('sgde_token');
    sessionStorage.removeItem('sgde_sessao');
  }

  async function chamarRpc(fn, params = {}) {
    const { data, error } = await supabase.rpc(fn, params);
    if (error) throw new Error(error.message || 'Erro ao chamar o servidor.');
    return data;
  }

  // Toda operação sensível primeiro valida a sessão (renova a expiração
  // deslizante de 12h e popula app.usuario_id/app.papel na transação),
  // depois faz a query normal via PostgREST — protegida por RLS.
  async function comSessaoValida() {
    const token = getToken();
    if (!token) { window.location.href = 'login.html'; throw new Error('Sem sessão.'); }
    try {
      await chamarRpc('verificar_sessao', { p_token: token });
    } catch (e) {
      limparSessao();
      window.location.href = 'login.html';
      throw e;
    }
    return token;
  }

  async function login(loginUsuario, senha) {
    const rows = await chamarRpc('login', { p_login: loginUsuario, p_senha: senha });
    const row = Array.isArray(rows) ? rows[0] : rows;
    if (!row) throw new Error('Usuário ou senha inválidos.');
    setSessao(row);
    return row;
  }

  async function logout() {
    const token = getToken();
    if (token) { try { await chamarRpc('logout', { p_token: token }); } catch (e) {} }
    limparSessao();
    window.location.href = 'login.html';
  }

  function exigirPapel(...papeis) {
    const sessao = getSessao();
    if (!sessao || !papeis.includes(sessao.papel)) {
      throw new Error('Seu papel não tem permissão para esta ação.');
    }
  }

  async function tabela(nome) {
    await comSessaoValida();
    return supabase.from(nome);
  }

  return { getToken, getSessao, setSessao, limparSessao, chamarRpc, comSessaoValida, login, logout, exigirPapel, tabela };
})();

function protegerPagina() {
  if (!SGDE.getToken()) { window.location.href = 'login.html'; }
  SGDE.comSessaoValida().catch(() => {});
  const sessao = SGDE.getSessao();
  const badge = document.querySelector('.papel-badge');
  if (badge && sessao) badge.textContent = `${sessao.nome} · ${sessao.papel}`;
}

function formatarMoeda(v) {
  return (Number(v) || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

function mostrarErro(msg, container = '.alert-area') {
  const el = document.querySelector(container);
  if (!el) { alert(msg); return; }
  el.innerHTML = `<div class="alert error">${msg}</div>`;
}

function mostrarSucesso(msg, container = '.alert-area') {
  const el = document.querySelector(container);
  if (!el) { alert(msg); return; }
  el.innerHTML = `<div class="alert success">${msg}</div>`;
}
