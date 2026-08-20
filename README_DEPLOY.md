# SGDE — Guia de Deploy (passo a passo técnico)

## Status atual (atualizado por mim, direto no seu projeto Supabase)

✅ Projeto Supabase criado (`Igreja`, região sa-east-1) e todas as 11 migrations aplicadas.
✅ Corrigi e apliquei um problema crítico de segurança que os advisors do próprio Supabase
   detectaram: `criar_usuario`, `fechar_lote`, `emitir_recibo` e `conciliar_extrato_automatico`
   agora exigem token de sessão válido antes de fazer qualquer coisa (antes, qualquer pessoa com
   a anon key podia chamá-las direto pela API sem estar logada).
✅ Dois usuários reais criados: `pr.gleisson` (Administrador) e `tesoureiro1` (Tesoureiro) — as
   senhas temporárias foram te enviadas em separado nesta conversa. Troquem no primeiro login.
✅ Conta bancária Banco do Brasil (ag 1251-3 / cc 46650-6) cadastrada, com titularidade
   confirmada pelo cartão CNPJ: **IGREJA SALVADOR DO SETIMO DIA — CNPJ 68.162.102/0001-47**.
✅ Chave PIX de doação avulsa cadastrada e já aparecendo no site público.
✅ `app/js/api.js` e `site/index.html` já apontam para a URL e a anon key do seu projeto.

O que falta é só GitHub + Netlify + DNS — abaixo o passo a passo.

## 1. GitHub (versionamento)

1. No repositório que você já criou e logou, suba as pastas `migrations/`, `app/`, `site/`,
   `docs/`, `netlify.toml`, `README_DEPLOY.md`. Elas já estão prontas no zip que te enviei —
   é só extrair na pasta do repositório local e commitar.
2. Comandos (rodando no terminal, dentro da pasta onde você extraiu o zip):
   ```
   git init
   git remote add origin https://github.com/SEU-USUARIO/SEU-REPO.git
   git add migrations app site docs netlify.toml README_DEPLOY.md
   git commit -m "SGDE: schema inicial + app + site público"
   git branch -M main
   git push -u origin main
   ```
   Troque a URL do `remote add` pela do seu repositório (aparece no botão verde "Code" do GitHub).
3. As credenciais do Supabase já estão embutidas em `app/js/api.js` e `site/index.html` — não
   precisa editar nada, só confirmar que não vão para um repositório público sem querer (se o
   repo for público, considere trocar depois para variáveis de ambiente do Netlify — me avise se
   quiser que eu ajuste isso).
   **Nunca** existe `service_role key` em nenhum arquivo deste projeto — só a anon key, que é
   segura para expor porque tudo que ela acessa passa pela RLS.

## 2. Netlify — dois sites separados

Recomendo dois sites Netlify a partir do mesmo repositório, para manter a área interna fora do
alcance de buscadores e do público:

**Site A — área interna (sistema financeiro)**
- New site from Git → escolha o repositório.
- Publish directory: `app`
- Build command: (vazio — são arquivos estáticos, nada para compilar)
- Depois do deploy, em Site settings → Domain management, configure um subdomínio tipo
  `sistema.salvadordosetimodia.com.br`.
- Em Site settings → Access control, ative "Password protection" (planos pagos) ou IP
  restriction como camada extra — o sistema já exige login próprio, isso é só reforço.

**Site B — site público (eventos e campanhas)**
- New site from Git → mesmo repositório.
- Publish directory: `site`
- Domain: `www.salvadordosetimodia.com.br` ou `salvadordosetimodia.com.br`.

## 3. Domínio (DNS) — salvadordosetimodia.com.br

O domínio já está **Publicado** no Registro.br (expira em 20/08/2031) — o registro foi concluído,
a pendência de DNS de antes já não existe mais. Falta só apontar para a Netlify:

1. Crie os dois sites Netlify primeiro (passo 2 acima) — cada um recebe uma URL temporária tipo
   `nome-aleatorio.netlify.app`. Confirme que ambos abrem certo antes de mexer no DNS.
2. Em cada site Netlify → Domain management → Add custom domain, digite o domínio/subdomínio.
3. A Netlify mostra os registros DNS exatos a cadastrar. No painel do Registro.br (Painel → seu
   domínio → DNS), cadastre:
   - Para o domínio raiz (`salvadordosetimodia.com.br`): o `A`/`ALIAS` que a Netlify indicar.
   - Para o subdomínio interno (`sistema.salvadordosetimodia.com.br`): o `CNAME` que a Netlify
     indicar.
4. Aguarde a propagação (geralmente 15min-2h, pode levar até 24h) e confirme na Netlify que o
   certificado HTTPS (Let's Encrypt) foi emitido automaticamente. Isso também resolve a pendência
   "checagem de servidor DNS" do Registro.br, porque a partir daí o domínio responde de verdade.

## 4. Primeiro acesso

1. Acesse `sistema.salvadordosetimodia.com.br/login.html` (ou a URL temporária da Netlify,
   enquanto o DNS não propaga).
2. Entre com `pr.gleisson` — te mandei a senha temporária em mensagem separada. Troque assim que
   entrar (ainda não construí a tela de troca de senha própria — se quiser, faço a seguir; por
   ora, um Administrador pode recriar o usuário com `criar_usuario` ou eu troco a senha direto no
   banco a seu pedido).
3. Cadastre os demais dados: fornecedores, centros de custo, e confirme a conta bancária.
4. Publique o primeiro evento/campanha pela tela "Eventos & Campanhas" para testar o site público.

## 5. Pendências que dependem de você

- Me enviar o QR code da chave PIX quando tiver, caso queira que eu troque a exibição de texto
  por uma imagem de QR code no site público.

## 6. Depois disso

- Toda alteração enviada ao repositório GitHub republica os dois sites automaticamente (deploy
  contínuo da Netlify) — não precisa reenviar arquivos manualmente.
- Mudanças no banco eu aplico direto, já que tenho acesso ao projeto Supabase — é só me pedir.
- Erros de execução que aparecerem na tela (RLS negando algo, trigger disparando exceção) me
  envie a mensagem exata e eu ajusto.
