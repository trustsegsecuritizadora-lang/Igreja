function montarSidebar(paginaAtiva) {
  const links = [
    { href: 'dashboard-executivo.html', label: 'Visão Geral', icon: '◈' },
    { href: 'dashboard.html', label: 'Balancete & Caixa', icon: '▤' },
    { href: 'entradas.html', label: 'Entradas', icon: '⌂' },
    { href: 'saidas.html', label: 'Saídas', icon: '⌇' },
    { href: 'conciliacao.html', label: 'Conciliação', icon: '⇄' },
    { href: 'campanhas.html', label: 'Campanhas', icon: '✦' },
    { href: 'eventos.html', label: 'Eventos', icon: '⚑' },
    { href: 'oracao.html', label: 'Pedidos de Oração', icon: '🕊' },
    { href: 'voluntarios.html', label: 'Voluntários', icon: '☺' },
    { href: 'instituicoes.html', label: 'Instituições Indicadas', icon: '⌘' },
    { href: 'conteudos.html', label: '7 Minutos de Propósito', icon: '✎' },
    { href: 'log-atividades.html', label: 'Log de Atividades', icon: '☰' },
    { href: 'usuarios.html', label: 'Usuários', icon: '⚿' },
  ];
  const nav = links.map(l =>
    `<a href="${l.href}" class="${l.href === paginaAtiva ? 'active' : ''}"><span>${l.icon}</span>${l.label}</a>`
  ).join('');

  document.querySelector('.sidebar').innerHTML = `
    <div class="brand">SGDE</div>
    ${nav}
    <a href="#" id="link-sair"><span>⇥</span>Sair</a>
    <div class="papel-badge"></div>
  `;
  document.getElementById('link-sair').addEventListener('click', (e) => { e.preventDefault(); SGDE.logout(); });
}
