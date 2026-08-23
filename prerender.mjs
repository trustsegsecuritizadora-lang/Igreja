#!/usr/bin/env node
/* =====================================================================
 * prerender.mjs
 * ---------------------------------------------------------------------
 * Regenera o conteúdo estático (marcadores <!--SSR:...--> ) das páginas
 * públicas em site/ a partir dos dados reais do Supabase, para que o
 * HTML bruto entregue por rastreadores (Google, Bing, WhatsApp, etc.)
 * já contenha o conteúdo publicado, sem depender de JavaScript.
 *
 * Roda automaticamente a cada build do site Netlify "igreja-salvador-
 * setimo-dia" (Build command), ANTES do deploy publicar a pasta site/.
 *
 * Regras de escopo (Rodada 4 / automação pós-Rodada 4):
 *   - NÃO altera layout, CSS, textos fixos aprovados ou identidade visual.
 *   - Só substitui o conteúdo entre marcadores <!--SSR:id-->...<!--/SSR:id-->
 *     (ou, para atributos, o valor do atributo do elemento com o id dado),
 *     replicando exatamente o HTML que o JavaScript client-side já gera
 *     em tempo de execução (mesmas classes, mesma estrutura).
 *   - O JavaScript client-side de cada página continua intocado e roda
 *     normalmente no navegador do visitante, substituindo esse conteúdo
 *     pré-renderizado por dados sempre atualizados (camada "live").
 *   - Falha ao buscar dados de uma seção NUNCA derruba o build inteiro:
 *     essa seção fica com o conteúdo já existente no arquivo (o último
 *     commitado), e um aviso é impresso no log do Netlify.
 *
 * Sem dependências externas — usa apenas fetch nativo (Node >= 18).
 * ===================================================================== */

import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE_DIR = path.join(__dirname, 'site');

const SUPABASE_URL = 'https://fragxrqofweahrhgozhq.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZyYWd4cnFvZndlYWhyaGdvemhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzcyNzUsImV4cCI6MjEwMjgxMzI3NX0.A1mEQtBloGuuJJt9QhL7002RHCgBKOV5dIPdCsTvVyo';

/* --------------------------- utilidades HTTP --------------------------- */

async function sb(pathAndQuery) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
  });
  if (!res.ok) throw new Error(`Supabase ${pathAndQuery} -> HTTP ${res.status}`);
  return res.json();
}

/* -------------------- utilidades de formatação (== site/js/site.js) -------------------- */

function formatarMoeda(v) {
  return (Number(v) || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}
function formatarDataLonga(iso) {
  return new Date(iso + 'T00:00:00').toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric' });
}
function diasRestantes(dataLimiteISO) {
  const hoje = new Date(); hoje.setHours(0, 0, 0, 0);
  const alvo = new Date(dataLimiteISO + 'T00:00:00');
  return Math.max(0, Math.ceil((alvo - hoje) / 86400000));
}

/* ----------------------------- escaping ----------------------------- */

function escAttr(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;').replace(/"/g, '&quot;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/* ------------------------- manipulação de HTML ------------------------- */

function replaceMarker(html, id, novoConteudo) {
  const abre = `<!--SSR:${id}-->`;
  const fecha = `<!--/SSR:${id}-->`;
  const i = html.indexOf(abre);
  const j = html.indexOf(fecha);
  if (i === -1 || j === -1 || j < i) {
    console.warn(`  [aviso] marcador SSR:${id} não encontrado — bloco não alterado.`);
    return html;
  }
  return html.slice(0, i + abre.length) + '\n' + novoConteudo.trim() + '\n' + html.slice(j);
}

// Substitui o valor de um atributo (ex.: content=, href=, style=) da tag
// que tem o id indicado, sem depender de posição/ordem dos atributos.
function setAttrById(html, elId, attr, novoValor) {
  const tagRe = new RegExp(`<[a-zA-Z][a-zA-Z0-9]*\\b[^>]*\\bid="${elId}"[^>]*>`);
  const m = html.match(tagRe);
  if (!m) { console.warn(`  [aviso] elemento id="${elId}" não encontrado — atributo ${attr} não alterado.`); return html; }
  const tag = m[0];
  const attrRe = new RegExp(`(\\b${attr}=")([^"]*)(")`);
  if (!attrRe.test(tag)) { console.warn(`  [aviso] atributo ${attr} não encontrado em id="${elId}".`); return html; }
  const novaTag = tag.replace(attrRe, `$1${novoValor}$3`);
  return html.slice(0, m.index) + novaTag + html.slice(m.index + tag.length);
}

// Substitui o texto entre a tag de abertura (id=elId) e a tag de
// fechamento correspondente (uso simples, sem tags aninhadas do mesmo nome).
function setTextById(html, elId, tagName, novoTexto) {
  const re = new RegExp(`(<${tagName}\\b[^>]*\\bid="${elId}"[^>]*>)([\\s\\S]*?)(</${tagName}>)`);
  if (!re.test(html)) { console.warn(`  [aviso] elemento <${tagName} id="${elId}"> não encontrado.`); return html; }
  return html.replace(re, (_, a, _b, c) => a + novoTexto + c);
}

async function lerHtml(nome) { return readFile(path.join(SITE_DIR, nome), 'utf8'); }
async function gravarHtml(nome, conteudo) { await writeFile(path.join(SITE_DIR, nome), conteudo, 'utf8'); }

/* ============================ chave PIX (compartilhada) ============================ */

async function buscarChavePix() {
  const rows = await sb(`configuracoes_publicas?select=valor&chave=eq.pix_doacao_avulsa&limit=1`);
  return rows?.[0]?.valor || null;
}

function aplicarPixEmTodasAsPaginas(paginas, chavePix) {
  if (!chavePix) return paginas;
  for (const nome of Object.keys(paginas)) {
    paginas[nome] = replaceMarker(paginas[nome], 'pix', escAttr(chavePix));
  }
  return paginas;
}

/* ============================ index.html ============================ */

function templateCampanhaFeature(c, i) {
  const arrecadado = Number(c.total_arrecadado_confirmado) || 0;
  const pct = c.meta_valor ? Math.min(100, Math.round((arrecadado / c.meta_valor) * 100)) : 0;
  const paginaPorSlug = {
    'nossa-casa-nosso-proposito': 'campanhas/nossa-casa-nosso-proposito.html',
    'um-dia-para-sorrir': 'campanhas/um-dia-para-sorrir.html',
  };
  const link = (c.slug && paginaPorSlug[c.slug]) || 'eventos.html';
  const tag = c.categoria === 'dia_das_criancas' ? 'Dia das Crianças 2026' : 'Campanha institucional';
  const foto = c.imagem_url ? `background-image:url('${escAttr(c.imagem_url)}')` : '';
  const fmtData = (iso) => (iso ? formatarDataLonga(iso) : '—');
  const datasHtml = (c.data_fim || c.data_entrega || c.data_evento) ? `
        <div class="cf-datas">
          ${c.data_fim ? `<div><span class="rotulo">Encerramento</span><span class="val">${fmtData(c.data_fim)}</span></div>` : ''}
          ${c.data_entrega ? `<div><span class="rotulo">Entrega</span><span class="val">${fmtData(c.data_entrega)}</span></div>` : ''}
          ${c.data_evento ? `<div><span class="rotulo">Evento</span><span class="val">${fmtData(c.data_evento)}</span></div>` : ''}
        </div>` : '';
  const instituicaoHtml = c.instituicao_beneficiada
    ? `<p class="cf-instituicao">Instituição beneficiada: ${c.instituicao_beneficiada}</p>`
    : `<p class="cf-instituicao">Instituição parceira em processo de definição.</p>`;
  return `
    <article class="campanha-feature${i % 2 === 1 ? ' reverse' : ''}">
        <div class="cf-foto" style="${foto}"><span class="cf-tag">${tag}</span></div>
        <div class="cf-conteudo">
          <h3>${c.titulo}</h3>
          <p class="cf-desc">${c.descricao || ''}</p>
          ${c.meta_valor ? `
            <div class="cf-numero-linha">
              <span class="cf-arrecadado">${formatarMoeda(arrecadado)}</span>
              <span class="cf-meta">arrecadados de ${formatarMoeda(c.meta_valor)}</span>
            </div>
            <div class="barra"><div style="width:${pct}%"></div></div>
            <div class="cf-progresso-linha">
              <span class="pct">${pct}% da meta</span>
              ${c.data_fim ? `<span class="restante">${diasRestantes(c.data_fim)} dias restantes</span>` : ''}
            </div>
          ` : ''}
          ${datasHtml}
          ${instituicaoHtml}
          <div class="cf-cta-row">
            <a class="btn btn-secundario on-light" href="${link}">Conhecer a campanha →</a>
            <span class="btn btn-primario btn-contribuir-card" role="button" tabindex="0" data-destino-slug="${c.slug || ''}">Contribuir</span>
          </div>
        </div>
      </article>`;
}

function templateFrenteCard(p) {
  return `
      <div class="projeto-card frente">
        <p class="eyebrow-frente">Frente de atuação</p>
        <h3>${p.titulo}</h3>
        <p>${p.headline || p.descricao || ''}</p>
      </div>`;
}

function templateEventoCardSimples(ev) {
  const capa = ev.imagem_url || "data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22220%22 height=%22140%22%3E%3Crect width=%22220%22 height=%22140%22 fill=%22%23EFE9DD%22/%3E%3C/svg%3E";
  const quando = new Date(ev.data_inicio).toLocaleString('pt-BR', { dateStyle: 'long', timeStyle: 'short' }) + (ev.local ? ' · ' + ev.local : '');
  return `
      <div class="evento-card">
        <div class="capa"><img src="${escAttr(capa)}" alt="" loading="lazy"></div>
        <div>
          <h3>${ev.titulo}</h3>
          <div class="quando">${quando}</div>
        </div>
      </div>`;
}

async function gerarIndex() {
  let html = await lerHtml('index.html');

  try {
    const campanhas = await sb(`campanhas?select=id_campanha,titulo,descricao,meta_valor,data_inicio,data_fim,data_entrega,data_evento,imagem_url,slug,categoria,instituicao_beneficiada,total_arrecadado_confirmado&publicado=eq.true&destaque_home=eq.true&order=criado_em`);
    const bloco = (!campanhas || campanhas.length === 0)
      ? `<p style="color:var(--ink-500)">Nenhuma campanha em destaque no momento.</p>`
      : campanhas.map(templateCampanhaFeature).join('\n');
    html = replaceMarker(html, 'campanhas-home', bloco);
  } catch (e) { console.warn('  [aviso] index.html campanhas-home:', e.message); }

  try {
    const frentes = await sb(`projetos?select=titulo,headline,descricao,ordem&status=eq.frente_atuacao&order=ordem`);
    const bloco = (!frentes || frentes.length === 0) ? '' : frentes.map(templateFrenteCard).join('\n');
    html = replaceMarker(html, 'frentes', bloco);
  } catch (e) { console.warn('  [aviso] index.html frentes:', e.message); }

  try {
    const agora = new Date().toISOString();
    const eventos = await sb(`eventos?select=id_evento,titulo,data_inicio,local,imagem_url&publicado=eq.true&data_inicio=gte.${agora}&order=data_inicio&limit=2`);
    const bloco = (!eventos || eventos.length === 0)
      ? `<p style="color:var(--ink-500)">Nenhum evento programado no momento — acompanhe as campanhas em andamento.</p>`
      : eventos.map(templateEventoCardSimples).join('\n');
    html = replaceMarker(html, 'eventos-home', bloco);
  } catch (e) { console.warn('  [aviso] index.html eventos-home:', e.message); }

  return html;
}

/* ============================ eventos.html ============================ */

function templateEventoCardCompleto(ev) {
  const capa = ev.imagem_url || "data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22220%22 height=%22140%22%3E%3Crect width=%22220%22 height=%22140%22 fill=%22%23EFE9DD%22/%3E%3C/svg%3E";
  const quando = new Date(ev.data_inicio).toLocaleString('pt-BR', { dateStyle: 'long', timeStyle: 'short' }) + (ev.local ? ' · ' + ev.local : '');
  const form = ev.inscricao_aberta ? `
            <form class="form-inscricao" data-evento="${ev.id_evento}">
              <input type="text" name="nome" placeholder="Seu nome" required>
              <input type="text" name="contato" placeholder="E-mail ou telefone" required>
              <button type="submit" class="btn btn-primario">Inscrever-se</button>
            </form>
            <div class="msg" style="font-size:.85rem;margin-top:6px"></div>
          ` : '';
  return `
        <div class="evento-card">
          <div class="capa"><img src="${escAttr(capa)}" alt="" loading="lazy"></div>
          <div>
            <h3>${ev.titulo}</h3>
            <div class="quando">${quando}</div>
            <p>${ev.descricao || ''}</p>
            ${form}
          </div>
        </div>`;
}

function templateCampanhaCardSimples(c) {
  const arrecadado = Number(c.total_arrecadado_confirmado) || 0;
  const pct = c.meta_valor ? Math.min(100, Math.round((arrecadado / c.meta_valor) * 100)) : 0;
  const paginaPorSlug = {
    'nossa-casa-nosso-proposito': 'campanhas/nossa-casa-nosso-proposito.html',
    'um-dia-para-sorrir': 'campanhas/um-dia-para-sorrir.html',
  };
  const link = (c.slug && paginaPorSlug[c.slug]) || '#';
  const tag = c.categoria === 'dia_das_criancas' ? 'Dia das Crianças 2026' : 'Campanha institucional';
  const desc = (c.descricao || '').slice(0, 150) + ((c.descricao || '').length > 150 ? '…' : '');
  const barraEProgresso = c.meta_valor ? `
          <div class="barra"><div style="width:${pct}%"></div></div>
          <div class="progresso-linha"><span class="valor">${formatarMoeda(arrecadado)}</span><span class="pct">${pct}% da meta</span></div>
        ` : '';
  return `
      <a class="campanha-card-simples" href="${link}">
        <span class="tag">${tag}</span>
        <h3>${c.titulo}</h3>
        <p class="desc">${desc}</p>
        ${barraEProgresso}
        <div class="rodape">
          <span class="saiba-mais">Conhecer a campanha →</span>
          ${c.data_fim ? `<span class="contador-mini">${diasRestantes(c.data_fim)} dias restantes</span>` : ''}
        </div>
      </a>`;
}

async function gerarEventos() {
  let html = await lerHtml('eventos.html');

  try {
    const agora = new Date().toISOString();
    const eventos = await sb(`eventos?select=id_evento,titulo,descricao,data_inicio,local,imagem_url,inscricao_aberta,vagas_limite&publicado=eq.true&data_inicio=gte.${agora}&order=data_inicio`);
    const bloco = (!eventos || eventos.length === 0)
      ? `<p style="color:var(--ink-500)">Nossa próxima agenda está sendo preparada. Acompanhe as novidades da ISSD por aqui.</p>`
      : eventos.map(templateEventoCardCompleto).join('\n');
    html = replaceMarker(html, 'eventos-lista', bloco);
  } catch (e) { console.warn('  [aviso] eventos.html eventos-lista:', e.message); }

  try {
    const campanhas = await sb(`campanhas?select=id_campanha,titulo,descricao,meta_valor,data_fim,slug,categoria,total_arrecadado_confirmado&publicado=eq.true&order=criado_em`);
    const bloco = (!campanhas || campanhas.length === 0)
      ? `<p style="color:var(--ink-500)">Nenhuma campanha ativa no momento.</p>`
      : campanhas.map(templateCampanhaCardSimples).join('\n');
    html = replaceMarker(html, 'campanhas-eventos', bloco);
  } catch (e) { console.warn('  [aviso] eventos.html campanhas-eventos:', e.message); }

  return html;
}

/* ============================ transparencia.html ============================ */

function templateResultadoTransparencia(c, docsPorCampanha) {
  const numeros = [];
  if (c.total_arrecadado_confirmado != null) numeros.push(['Arrecadado', formatarMoeda(c.total_arrecadado_confirmado)]);
  if (c.total_aplicado != null) numeros.push(['Aplicado', formatarMoeda(c.total_aplicado)]);
  if (c.saldo != null) numeros.push(['Saldo', formatarMoeda(c.saldo)]);
  if (c.entregues_cestas != null) numeros.push(['Cestas entregues', c.entregues_cestas]);
  if (c.entregues_brinquedos != null) numeros.push(['Brinquedos entregues', c.entregues_brinquedos]);
  if (c.criancas_familias_beneficiadas != null) numeros.push(['Famílias/crianças beneficiadas', c.criancas_familias_beneficiadas]);
  const docsCampanha = docsPorCampanha[c.id_campanha] || [];
  return `
      <article class="transp-resultado reveal">
        <div class="cabecalho">
          <h3>${c.titulo}</h3>
          <div class="quando">${c.data_fim ? 'Encerrada em ' + formatarDataLonga(c.data_fim) : 'Resultado final'}${c.instituicao_beneficiada ? ' · Instituição: ' + c.instituicao_beneficiada : ''}</div>
        </div>
        <div class="transp-corpo">
          ${numeros.length ? `
            <div class="transp-numeros">
              ${numeros.map(([rotulo, val]) => `<div class="transp-numero"><p class="rotulo">${rotulo}</p><p class="val">${val}</p></div>`).join('')}
            </div>` : ''}
          ${c.destinacao_saldo ? `<p style="color:var(--ink-500);font-size:.92rem;margin:0 0 16px"><strong>Destinação do saldo:</strong> ${c.destinacao_saldo}</p>` : ''}
          ${c.resultados_texto ? `<div class="transp-resultados-texto">${c.resultados_texto}</div>` : ''}
          ${docsCampanha.length ? `
            <div class="transp-docs">
              ${docsCampanha.map(d => `<a href="${escAttr(d.url)}" target="_blank" rel="noopener">${d.nome}</a>`).join('')}
            </div>` : ''}
        </div>
      </article>`;
}

async function gerarTransparencia() {
  let html = await lerHtml('transparencia.html');
  try {
    const campanhas = await sb(`campanhas?select=id_campanha,titulo,data_fim,meta_valor,total_arrecadado_confirmado,total_aplicado,saldo,destinacao_saldo,entregues_cestas,entregues_brinquedos,criancas_familias_beneficiadas,instituicao_beneficiada,resultados_texto&publicado=eq.true&prestacao_contas_publicada=eq.true&status=in.(encerrada,prestacao_contas)&order=data_fim.desc`);
    if (!campanhas || campanhas.length === 0) {
      html = replaceMarker(html, 'transparencia', `<div class="transp-vazio"><p>Nossas primeiras ações estão em andamento. Ao final de cada campanha, os resultados serão publicados aqui.</p></div>`);
    } else {
      const docs = await sb(`campanha_documentos?select=campanha_id,nome,url&publico=eq.true`);
      const docsPorCampanha = {};
      (docs || []).forEach(d => { (docsPorCampanha[d.campanha_id] ||= []).push(d); });
      html = replaceMarker(html, 'transparencia', campanhas.map(c => templateResultadoTransparencia(c, docsPorCampanha)).join('\n'));
    }
  } catch (e) { console.warn('  [aviso] transparencia.html:', e.message); }
  return html;
}

/* ============================ proposito.html ============================ */

function templateDestaque(a) {
  const foto = a.imagem_url ? `background-image:url('${escAttr(a.imagem_url)}')` : '';
  return `
        <a class="prop-destaque" href="proposito/${encodeURIComponent(a.slug)}">
          <div class="pd-foto" style="${foto}"></div>
          <div class="pd-conteudo">
            <p class="pd-eyebrow">7 Minutos de Propósito #${a.numero}</p>
            <h2>${a.titulo}</h2>
            <p class="pd-resumo">${a.meta_description || a.subtitulo || ''}</p>
            <p class="pd-meta">${a.tempo_leitura_min ? a.tempo_leitura_min + ' min de leitura' : ''}</p>
            <div class="pd-cta-row"><span class="btn-texto">Ler reflexão →</span></div>
          </div>
        </a>`;
}

function templateCardGrid(a) {
  const foto = a.imagem_url ? `background-image:url('${escAttr(a.imagem_url)}')` : '';
  return `
      <a class="prop-card" href="proposito/${encodeURIComponent(a.slug)}">
        <div class="capa" style="${foto}"></div>
        <div class="miolo">
          <p class="categoria">${a.categoria || 'Propósito'}</p>
          <h3>${a.titulo}</h3>
          <p class="tempo">${a.tempo_leitura_min ? a.tempo_leitura_min + ' min de leitura' : ''}</p>
        </div>
      </a>`;
}

async function gerarProposito() {
  let html = await lerHtml('proposito.html');
  try {
    const dados = await sb(`conteudos_proposito?select=titulo,subtitulo,slug,imagem_url,categoria,tempo_leitura_min,data_publicacao,meta_description&status=eq.publicado&order=data_publicacao.asc`);
    if (!dados || dados.length === 0) {
      html = replaceMarker(html, 'proposito-lista', `<div class="prop-vazio"><p>Novos conteúdos de 7 Minutos de Propósito estão a caminho. Volte em breve.</p></div>`);
      html = setAttrById(html, 'lista-artigos', 'class', '');
      return html;
    }
    const numerados = dados.map((a, i) => ({ ...a, numero: String(i + 1).padStart(2, '0') }));
    if (numerados.length < 3) {
      html = replaceMarker(html, 'proposito-lista', numerados.slice().reverse().map(templateDestaque).join('\n'));
      html = setAttrById(html, 'lista-artigos', 'class', 'prop-destaque-lista');
    } else {
      html = replaceMarker(html, 'proposito-lista', numerados.slice().reverse().map(templateCardGrid).join('\n'));
      html = setAttrById(html, 'lista-artigos', 'class', 'prop-lista');
    }
  } catch (e) { console.warn('  [aviso] proposito.html:', e.message); }
  return html;
}

/* ============================ proposito-artigo.html ============================ */
// Limitação conhecida: como proposito-artigo.html é um único arquivo estático
// que serve qualquer artigo via ?slug= (roteado pelo _redirects para a URL
// bonita /proposito/<slug>), só é possível "assar" o SEO de UM artigo por
// build. Escolhido: o mais recentemente publicado — é o que mais provavelmente
// será compartilhado/rastreado logo após a publicação. Artigos mais antigos
// continuam funcionando normalmente para visitantes reais (via JS), mas sem
// SEO estático próprio — a solução completa exigiria gerar um arquivo por
// artigo, fora do escopo desta automação (ver relatório).

async function gerarPropositoArtigo() {
  let html = await lerHtml('proposito-artigo.html');
  try {
    const dados = await sb(`conteudos_proposito?select=titulo,subtitulo,autor,categoria,tempo_leitura_min,conteudo,seo_title,meta_description,data_publicacao,slug,imagem_url&status=eq.publicado&order=data_publicacao.desc&limit=1`);
    const a = dados?.[0];
    if (!a) { console.warn('  [aviso] proposito-artigo.html: nenhum artigo publicado encontrado.'); return html; }

    const urlBonita = `https://salvadordosetimodia.com.br/proposito/${encodeURIComponent(a.slug)}`;
    const tituloAba = escAttr(a.seo_title || `${a.titulo} · ISSD`);
    const desc = escAttr(a.meta_description || a.subtitulo || '');

    html = setTextById(html, 'titulo-aba', 'title', a.seo_title || `${a.titulo} · ISSD`);
    html = setAttrById(html, 'meta-desc', 'content', desc);
    html = setAttrById(html, 'og-type', 'content', 'article');
    html = setAttrById(html, 'og-title', 'content', escAttr(a.titulo));
    html = setAttrById(html, 'og-desc', 'content', desc);
    html = setAttrById(html, 'og-url', 'content', escAttr(urlBonita));
    if (a.imagem_url) html = setAttrById(html, 'og-image', 'content', escAttr(a.imagem_url));
    if (a.data_publicacao) html = setAttrById(html, 'og-published', 'content', escAttr(a.data_publicacao));
    html = setAttrById(html, 'link-canonical', 'href', escAttr(urlBonita));

    const cabecalho = `
    <p class="categoria">${a.categoria || 'Propósito'}</p>
    <h1>${a.titulo}</h1>
    <p class="meta">${a.autor ? a.autor + ' · ' : ''}${a.tempo_leitura_min ? a.tempo_leitura_min + ' min de leitura' : ''}</p>
  `;
    html = replaceMarker(html, 'cabecalho', cabecalho);
    html = replaceMarker(html, 'corpo', a.conteudo || '');
    if (a.imagem_url) html = setAttrById(html, 'capa-artigo', 'style', `background-image:url('${escAttr(a.imagem_url)}')`);

    console.log(`  [ok] proposito-artigo.html assado para o artigo mais recente: "${a.titulo}" (${a.slug})`);
  } catch (e) { console.warn('  [aviso] proposito-artigo.html:', e.message); }
  return html;
}

/* ============================ páginas de campanha ============================ */

async function gerarCampanha(arquivo, slug, { comDias, dataEncerramento } = {}) {
  let html = await lerHtml(`campanhas/${arquivo}`);
  try {
    const campos = 'id_campanha,meta_valor,instituicao_beneficiada,total_arrecadado_confirmado';
    const dados = await sb(`campanhas?select=${campos}&slug=eq.${slug}&limit=1`);
    const c = dados?.[0];
    if (!c) { console.warn(`  [aviso] campanha slug=${slug} não encontrada.`); return html; }

    const arrecadado = Number(c.total_arrecadado_confirmado) || 0;
    const pct = c.meta_valor ? Math.min(100, Math.round((arrecadado / c.meta_valor) * 100)) : 0;

    html = replaceMarker(html, 'arrecadado', formatarMoeda(arrecadado));
    html = replaceMarker(html, 'meta', formatarMoeda(c.meta_valor));
    html = replaceMarker(html, 'pct', `${pct}% da meta`);
    if (comDias && dataEncerramento) {
      html = replaceMarker(html, 'dias', String(diasRestantes(dataEncerramento)));
    }
    if (c.instituicao_beneficiada) {
      html = replaceMarker(html, 'instituicao', c.instituicao_beneficiada);
    }
  } catch (e) { console.warn(`  [aviso] campanhas/${arquivo}:`, e.message); }
  return html;
}

/* ================================== main ================================== */

async function main() {
  console.log('=== prerender.mjs — regenerando conteúdo estático a partir do Supabase ===');

  const paginas = {};

  console.log('> index.html');
  paginas['index.html'] = await gerarIndex();

  console.log('> eventos.html');
  paginas['eventos.html'] = await gerarEventos();

  console.log('> transparencia.html');
  paginas['transparencia.html'] = await gerarTransparencia();

  console.log('> proposito.html');
  paginas['proposito.html'] = await gerarProposito();

  console.log('> proposito-artigo.html');
  paginas['proposito-artigo.html'] = await gerarPropositoArtigo();

  console.log('> campanhas/nossa-casa-nosso-proposito.html');
  paginas['campanhas/nossa-casa-nosso-proposito.html'] = await gerarCampanha(
    'nossa-casa-nosso-proposito.html', 'nossa-casa-nosso-proposito'
  );

  console.log('> campanhas/um-dia-para-sorrir.html');
  paginas['campanhas/um-dia-para-sorrir.html'] = await gerarCampanha(
    'um-dia-para-sorrir.html', 'um-dia-para-sorrir', { comDias: true, dataEncerramento: '2026-10-08' }
  );

  console.log('> chave PIX (compartilhada entre as páginas acima)');
  try {
    const chavePix = await buscarChavePix();
    if (chavePix) aplicarPixEmTodasAsPaginas(paginas, chavePix);
    else console.warn('  [aviso] chave PIX não encontrada em configuracoes_publicas — mantendo valor já existente nos arquivos.');
  } catch (e) { console.warn('  [aviso] chave PIX:', e.message); }

  for (const [nome, conteudo] of Object.entries(paginas)) {
    await gravarHtml(nome, conteudo);
    console.log(`  [gravado] site/${nome}`);
  }

  console.log('=== prerender.mjs concluído ===');
}

main().catch((e) => {
  // Erro catastrófico (ex.: site/ ausente) — aqui sim falha o build,
  // porque não há nada seguro para publicar.
  console.error('ERRO FATAL no prerender.mjs:', e);
  process.exit(1);
});
