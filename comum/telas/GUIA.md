# Peças prontas: telas falsas do iPhone

Padrão para todos os apps de mágica:
- **Tela bloqueada** = a do Timeline (data "Ter. 17 de nov.", relógio grande com letra e grossura ajustáveis, botões de vidro com a lanterna e a câmera do próprio iPhone, barrinha).
- **Tela de ícones** = a do Mosaico (print com ícones transparentes sobre o papel de parede, duas páginas com a 2ª voltando sozinha, um toque abre, vidro da base e do Buscar redesenhado ao abrir).
- **Abrir e fechar** = a animação do Mosaico (o app cresce do ícone; ao fechar encolhe até ele, como no iOS 26).

Primeiro app que usa as peças: `apps/calculadora` (veja `fonte/app.html` e `fonte/build.py`).

## Arquivos

| Arquivo | O que é |
|---|---|
| `tela-inicio.css` / `tela-inicio.js` | tela de ícones: `criarTelaInicio({...})` |
| `tela-bloqueio.css` / `tela-bloqueio.js` | tela bloqueada: `criarTelaBloqueio({...})` |
| `TelasNativas.swift` | parte do iPhone: animação de abrir/fechar e ícones da lanterna e câmera |
| `ini/` | imagens padrão: `pag1.webp` (1ª página), `pag2.webp` (2ª), `dock.webp` (base), `papel.jpg` (papel de parede) |

## Como colocar num app novo

1. **Imagens:** copie `ini/` para `apps/<app>/www/ini/`. Para trocar um ícone, edite `pag1.webp` no app (não aqui). Os ícones são o print de 1184 x 2576; as posições são frações dessa imagem (ex.: Ajustes x 0.1546, y 0.1390; 1ª coluna x 0.1546; colunas a cada 0.2299; linhas a cada 0.1145 a partir de y 0.1390).
2. **Página:** no `app.html`, coloque `/*PECA:tela-inicio.css*/` e `/*PECA:tela-bloqueio.css*/` dentro do `<style>`, e `/*PECA:tela-inicio.js*/` e `/*PECA:tela-bloqueio.js*/` no começo do `<script>`. O `build.py` do app troca essas marcas pelos arquivos daqui (copie o da Calculadora).
3. **Tela de ícones:**
   ```js
   const ti = criarTelaInicio({
     raiz: document.querySelector('#inicio'),      // div em tela cheia (position:fixed; inset:0)
     nativo: (cmd, args) => webkit.messageHandlers.<app>.postMessage(Object.assign({cmd}, args)), // ou null fora do app
     rotulos: [{texto: 'Instagram', cx: .6153, topo: .6471, larg: .1588}],  // nomes desenhados pelo app (opcional)
     icones: [{x: .1546, y: .1390, acao: () => abrirAjustes()}],           // o que abre ao tocar
     segurar: {ms: 1500, quando: () => true, acao: () => {}}               // opcional
   });
   ti.papel(urlOuNull);   ti.desenhar();   ti.acordarVidros();
   ti.abrirApp(icone, telaDoApp, antes, depois);   ti.fecharApp(icone, telaDoApp, antes, depois);
   ```
   `antes()` troca as telas por baixo (ao abrir: esconde a tela de início; ao fechar: mostra).
4. **Tela bloqueada:**
   ```js
   const tb = criarTelaBloqueio({raiz: elemento, opcoes: () => ({letra: 'normal'|'redonda', peso: '400'|'500'|'600'}), nativo});
   tb.mostrar();  tb.parar();  tb.medir();   // medir de novo ao mudar letra/grossura
   ```
   Para o papel de parede, ponha uma div com a foto atrás da `raiz`. Para a letra e a grossura, use dois botões no menu (como na Calculadora: Geral › Papel de parede e bloqueio).
5. **Parte do iPhone:** o `build.py` copia `TelasNativas.swift` para `apps/<app>/extras/`. No `PonteExtra.swift` do app: `private let telas = TelasNativas()`, em `ligar` faça `telas.web = webView`, e no começo do recebimento de recados: `if telas.tratar(cmd, d, responder) { return }`. A resposta precisa voltar (use `WKScriptMessageHandlerWithReply`).
6. **Voltar para a tela de ícones:** arrastar para cima no meio da tela (não na barrinha, que é do iPhone e fecha o app de verdade).
