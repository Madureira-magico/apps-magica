# Mosaico — como funciona (guia para refazer ou fazer um app parecido)

Versão de referência: **3.36** (16/11/2026), considerada "muito boa" pelo Ricardo.
App nativo de iPhone no projeto `apps-magica` (pasta `apps/mosaico`), montado pelo GitHub Actions
(`scripts/montar.sh`), instalado pelo site https://madureira-magico.github.io/apps-magica/.

## 1. Estrutura

- `fonte/app.html` + `fonte/app.js` → página (telas falsas, menu, lógica do nome, montagem do mosaico).
  `python3 build.py` junta tudo em `www/index.html`.
- `extras/GaleriaNativa.swift` → a Fototeca de verdade, nativa (grade, pinça, linhas, encaixes).
- `extras/PonteExtra.swift` → comandos nativos da ponte (fotos, cores, miniaturas, voz, câmera, animações de abrir/fechar app, Inject).
- A página roda num WKWebView; a galeria nativa fica atrás da página transparente
  (`vista` dentro do webView) e uma camada de toques (`CapaToques`) recebe os gestos.

## 2. A galeria É o mosaico (a ideia central)

- A Fototeca é **uma grade gigante** (UIScrollView + uma view `plano` + `TilesMosaico`, um CATiledLayer).
  A pinça é só o zoom dessa grade: nada troca de lugar, as próprias fotos formam o rosto.
- Com artista: a grade tem `C` colunas (o menu "Colunas", usado 25). Sem artista: 3 colunas.
- **Zoom máximo** = fotos grandes (3 colunas na tela): `C / 3`. **Zoom mínimo (1)** = largura inteira = rosto.
- Layout (JS `prepararMosaico`):
  - a imagem do famoso ocupa **a última tela inteira** (fileiras `primeira`…`ultima`);
  - a **faixa de fotos de verdade** fica **no meio** (`cS = floor((n-3)/2)`), **lá embaixo**, dentro da imagem,
    com **6 fileiras = as 18 fotos da primeira tela** (com o bebê) → no rosto pronto ela fica quase toda
    escondida atrás da barra "Fototeca" (como no original Mozaic);
  - se o nome chega com a grade aberta e a pessoa subiu, **todas as fileiras visíveis** continuam verdadeiras
    (`fReais` vem de `galeriaEstado`: (alt - y) / (W/3));
  - acima da faixa, tudo é mosaico; acima do rosto, uma "cortina" (`cobre`) da cor do fundo.
- Último quadrado (ou 2 últimos) da primeira tela vazio de propósito → última fileira incompleta, como no iPhone.

## 3. Escolha das fotos (cores)

- Cada foto da galeria tem: cor média + **4 quadrantes** (12 valores) + "foto boa" (filtro Vision: pessoas/paisagens).
  Miniaturas quadradas de 64 px ficam guardadas em `Caches/minis`.
- Alvo: a foto do famoso amostrada com **o dobro de detalhe** (A4: 4 pedaços por quadradinho).
- Para cada quadradinho: pega as 28 fotos de cor mais parecida (índice 8x8x8), reordena pelos 4 quadrantes,
  sorteia entre as **2 melhores**, sem repetir a mesma foto do lado nem em cima.
- Claridade: o claro/escuro do rosto é mapeado para a faixa de claridade que existe na galeria (`porLuz`).
- Saem do mosaico: fotos **brancas lisas** (`brancaLisa`) e **pretas lisas** (`pretaLisa`) — parecem buracos.
- Lugares vazios da grade recebem fotos da galeria embaralhadas (nunca branco).
- "Reforço do rosto" (pintura de cor por cima) bem fraco (5%) e "Momento da cor" tarde (6–8) imita o original.

## 4. A pinça (o que fez parar de tremer)

- **Não usar a pinça do UIScrollView** (`pinchGestureRecognizer.isEnabled = false`). Corrigir `contentOffset`
  dentro de `scrollViewDidZoom` briga com o iPhone e **treme** (relatado nos fóruns).
- Pinça própria (`UIPinchGestureRecognizer` na camada de toques), **conta exata a cada quadro**:
  - no começo guarda o ponto da grade entre os dedos: `anc = (offset + dedos) / zoom`;
  - a cada quadro: `zoom = base * g.scale` (limitado), `offset = anc * zoom - dedos`;
  - se **um dedo sai** (muda `numberOfTouches`), refaz a base a partir do lugar atual → não pula para o dedo que ficou;
  - pan com `maximumNumberOfTouches = 1`; durante a pinça `isScrollEnabled = false`; embalo parado no começo.
- **Ajuda na volta** (abrindo a pinça): peso `k` vai de 0 (zoom do começo do gesto) a 1 (fotos grandes), suavizado;
  `x` puxa para a faixa (`xFaixa`), e `y` (chave "Voltar até as 18 fotos") puxa até o fim da grade. Determinístico → sem tremer.
- **Limites** por zoom (`limitar` / `limitesY`): nunca vazio dos lados; embaixo, o espaço acima da barra só existe com
  as fotos grandes (diminui com o zoom); em cima, perto do rosto, não passa do topo da cabeça.
- Fim da pinça: no rosto → anima até o rosto inteiro e trava; perto das fotos grandes (≥ 75%) → encaixa 3 colunas na faixa.
- **Animações quadro a quadro** com `CADisplayLink` (não `UIView.animate`), para a linha acompanhar. Arrastar para a animação.

## 5. Linhas entre as fotos e "piscadas"

- As fotos são desenhadas **coladas**; a linha (5 px, cantos arredondados ~1,5× a linha, medido no Fotos do iPhone)
  é um `CAShapeLayer` **por cima, na tela**, redesenhado a cada movimento (`atualizarLinhas`), afinando suave até sumir no rosto.
  Desenhar a linha dentro dos tiles fazia ela mudar de espessura de repente (piscava).
- Cor da linha = fundo (preto no escuro, branco no claro).
- CATiledLayer guarda pedaços antigos em outros níveis de zoom → **a cada mosaico novo, criar uma `TilesMosaico` nova**
  (não só `setNeedsDisplay`), senão aparece o mosaico do nome escrito num salto.
- Por baixo da grade: `baseMos` (o mosaico pronto em miniatura) e `fundo` (últimas 24 fileiras em miniatura) → nunca preto
  enquanto a grade se desenha. `tiles` com fundo transparente e `isOpaque = false`.
- "Tela pronta" (`capaInicio`): imagem exata da tela atual, **dentro da grade** (anda com o dedo), mostrada ao abrir,
  quando a grade é refeita com ela aberta e ao voltar de uma foto; sai sem fade (4 s ou ao começar a pinça).
- Ao refazer a grade, guardar o lugar em **colunas e fileiras** (colunas na tela, coluna do meio a partir da faixa,
  fileiras a partir de baixo) e repor depois — vale também com uma foto aberta por cima.

## 6. Nome do famoso

- Entradas: Notas falso (apagar envia), Inject (11z.co, lido a cada 0,5 s), câmera (lupa), Pesquisar (2 toques em
  "Fototeca"), microfone (lixeira da foto do bebê, espera 1,5 s de silêncio).
- `limparPedido` → `acharFamoso` (lista ~300 com apelidos, distância Damerau) → Wikipédia (título tem que bater) →
  IA (worker da Cloudflare com o Gemini; a chave fica na Cloudflare, nunca no app) → aprende o apelido.
- Primeiro monta com o **nome escrito** (rápido), depois troca pelo **rosto** quando a foto chega.
- Sinal secreto: segurar o botão do meio mostra o nome (laranja procurando, azul pronto com foto, cinza sem foto)
  e uma bolinha com o rosto no ícone; "1" vermelho e vibração quando pronto.
- Volume para cima / "Selecionar" com o rosto inteiro → a foto real aparece.

## 7. Tela de início e apps falsos

- Imagens recortadas em camadas (`ini/papel.jpg`, `pag1.webp`, `pag2.webp`, `dock.webp`), vidro do dock desenhado pelo app,
  fundo trocável. Abrir/fechar app imitando o iOS 26 (cresce do ícone; ao fechar encolhe, vira o ícone e "chacoalha";
  a tela de início cresce de 0,94 para 1,0).
- Bebê: 4 fotos (menino/menina, branco/negro), escolhido sozinho pelo famoso; trava quando a Fototeca é vista com artista.
- Abrir o app do zero ou ficar fora mais de 3 min apaga o artista.

## 8. Lições (o que deu errado e como se resolveu)

- Tocar numa célula dentro do rosto: conferir primeiro se é da faixa de fotos de verdade (`verDeCelFaixa`), senão o bebê não abre.
- Ao medir posição antes de refazer a grade, usar as colunas de **antes** (senão volta para o começo ou pula para o rosto).
- `snapshotView` para esconder a troca saiu deslocado → trocado pela "tela pronta" desenhada pelo app.
- Analisar sempre os vídeos quadro a quadro (ffmpeg 30 fps) e medir pixels antes de mudar algo.

---
## Mozaic Plus (cópia do Mosaico 3.38 + Post-It Iarvel)
- App separado (bundle br.com.ricardomadureira.mosaicoplus), sem dividir ajustes com o Mosaico. Abre na tela de início.
- Post-It: mesmo protocolo do app Relógio (serviço 58570001…, abrir com `58 57 tipo 51 00 00 00 00` duas vezes, bateria = byte 3, pontos com op 0x00: [10]=qtd, 5 bytes por ponto).
  Conexão pela ponte Bluetooth do `comum/`; `getDevices` + `connect` pendente (o iPhone conecta sozinho quando o Post-It liga/volta).
- Escrita guardada em `pit.tracos` sem mostrar nada. Zera quando o rosto inteiro aparece (`postitRevelou`) ou com o "sinal de apagar" escolhido no menu.
- Volume + na tela de início (`postitVolume`): desenha a escrita em JPEG preto no branco em inclinações 0/±8 → ±16/180 → ±25/±90 e manda para `lerImagens` (Vision .accurate, com e sem correção + customWords = nomes da lista). Para no primeiro texto que bate com a lista (`acharFamoso`/`acharFamosoEm`) → `definirNome(nome,'postit')`. Sem nome: `PIT.falhou` → "Atualizando…" embaixo do Instagram, sem o 1.
- Segurar o Instagram: `#ilha` (janela preta que cresce do topo como a ilha dinâmica) com a escrita recortada; some ao soltar.
- Bateria no Telefone: `dock.webp` sem o "5" impresso; `#cvDock` desenha floor(bat/10) (mín. 1, 10 = 100%); sem conexão, sem número.
