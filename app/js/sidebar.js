function montarSidebar(paginaAtiva) {
  const links = [
    { href: 'dashboard.html', label: 'Balancete & Caixa', icon: '▤' },
    { href: 'entradas.html', label: 'Entradas', icon: '⌂' },
    { href: 'saidas.html', label: 'Saídas', icon: '⌇' },
    { href: 'conciliacao.html', label: 'Conciliação', icon: '⇄' },
    { href: 'eventos.html', label: 'Eventos & Campanhas', icon: '✦' },
    { href: 'oracao.html', label: 'Pedidos de Oração', icon: '🕊' },
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
