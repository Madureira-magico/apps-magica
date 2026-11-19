/* =====================================================================
   PEÇA PRONTA (comum/telas): BARRA DE CIMA FALSA igual à do iPhone
   (hora, sinal, Wi-Fi e bateria de verdade). Medidas tiradas do print do iPhone (402 pontos de largura).
   Serve para mostrar coisas escondidas no relógio (ex.: "17;05" na Calculadora).
   Uso: const bf = criarBarraFalsa({ raiz: elemento, nativo: cmd => Promise, opcoes: () => ({sinal: 1-4, wifi: 1-3, soHora: false}) })
        bf.mostrar(true/false)   bf.hora(texto ou null = hora certa)   bf.desenhar()
        soHora: desenha só o relógio (o resto da barra vem de outro lugar, ex.: a foto congelada da barra de verdade).
        operadora: 'Claro BR' -> como na TELA BLOQUEADA: o nome da operadora no lugar da hora (medidas do print do Paint).
        puxador: true -> a barrinha curta embaixo do Wi-Fi e da bateria (aparece na tela bloqueada).
        Na troca do relógio, só os caracteres que mudam fazem um fade de 0,75 s (como no original); o resto fica parado.
   O app esconde a barra de verdade enquanto esta aparece (recado "barra" = true).
   ===================================================================== */
function criarBarraFalsa(o){
  const raiz = o.raiz;
  raiz.insertAdjacentHTML('beforeend', '<canvas class="bfCv" style="position:absolute;left:0;top:0;pointer-events:none;z-index:5"></canvas>');
  const cv = raiz.querySelector('.bfCv'), cx = cv.getContext('2d');
  let texto = null, bat = {nivel:0.8, carregando:false, economia:false}, wifi = null, tick = null, ligada = false;
  let mostrado = '', antigo = '', fadeIni = 0, fadeRaf = 0;
  const FADE = 750;
  const op = () => Object.assign({sinal:4, wifi:3, soHora:false}, o.opcoes ? o.opcoes() : {});
  const px = v => v / 3;   // medidas do print estão em pixels de 3x
  function horaCerta(){ const d = new Date(); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); }   // como o relógio do iPhone em 24 h (00:46)
  function desenhar(){
    if(!ligada) return;
    const W = innerWidth, K = W / 402, H = 54 * K, dpr = window.devicePixelRatio || 2;
    if(cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)){ cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    cx.setTransform(dpr * K, 0, 0, dpr * K, 0, 0); cx.clearRect(0, 0, 402, 54);
    cx.fillStyle = '#fff';
    const p = op();
    // hora: altura dos números igual ao print, centrada no lado esquerdo.
    // Cada caractere tem largura fixa (nada anda para os lados) e, na troca, só os que mudam fazem o fade
    // (o velho some enquanto o novo aparece, uns 0,75 s, como no original); os iguais ficam parados.
    if(p.operadora != null){
      // tela bloqueada: operadora à esquerda (largura de "Claro BR" = 57,7 pontos; linha de base em 38 pontos)
      cx.font = '600 100px -apple-system, system-ui, "Inter", sans-serif';
      const mo = cx.measureText('Claro BR'), to = 100 * 57.7 / (mo.actualBoundingBoxLeft + mo.actualBoundingBoxRight);
      cx.font = '600 ' + to + 'px -apple-system, system-ui, "Inter", sans-serif';
      cx.textAlign = 'left'; cx.textBaseline = 'alphabetic';
      cx.fillText(String(p.operadora), 44.8 + cx.measureText(String(p.operadora)).actualBoundingBoxLeft, 38);
      if(p.puxador){
        cx.fillStyle = 'rgba(255,255,255,.6)';
        cx.beginPath(); cx.roundRect ? cx.roundRect(299.5, 47.3, 54.6, 2.4, 1.2) : cx.rect(299.5, 47.3, 54.6, 2.4); cx.fill();
        cx.fillStyle = '#fff';
      }
    } else {
    const t = texto || horaCerta();
    if(t !== mostrado){ antigo = mostrado; mostrado = t; fadeIni = antigo ? performance.now() : 0; if(fadeIni && !fadeRaf) fadeRaf = requestAnimationFrame(animar); }
    const f = fadeIni ? Math.min(1, (performance.now() - fadeIni) / FADE) : 1;
    cx.font = '600 100px -apple-system, system-ui, "Inter", sans-serif';
    const m0 = cx.measureText('22:55'), tam = 100 * px(36) / m0.actualBoundingBoxAscent;
    cx.font = '600 ' + tam + 'px -apple-system, system-ui, "Inter", sans-serif';
    cx.textAlign = 'center'; cx.textBaseline = 'alphabetic';
    const cel = c => /[0-9]/.test(c) ? larDig : cx.measureText(':').width;   // dígitos com a mesma largura; separador com a dos dois pontos
    const larDig = Math.max(...'0123456789'.split('').map(d => cx.measureText(d).width));
    const posicoes = s2 => { const ws = s2.split('').map(cel), tot = ws.reduce((a, b) => a + b, 0); let x = px(187.5) - tot / 2; return ws.map(w => { const c = x + w / 2; x += w; return c; }); };
    const pn = posicoes(t), pa = antigo ? posicoes(antigo) : [];
    const mesmoLayout = antigo && antigo.length === t.length;
    t.split('').forEach((c, i) => {
      const igual = mesmoLayout && antigo[i] === c;
      cx.globalAlpha = (igual || f >= 1) ? 1 : f; cx.fillText(c, pn[i], px(115));
    });
    if(f < 1 && antigo) antigo.split('').forEach((c, i) => {
      if(mesmoLayout && t[i] === c) return;
      cx.globalAlpha = 1 - f; cx.fillText(c, pa[i], px(115));
    });
    cx.globalAlpha = 1;
    if(p.soHora) return;
    }
    // sinal: 4 barras (as que passam do escolhido ficam apagadas, como no iPhone)
    [[864, 97], [880, 91], [896, 84], [912, 77]].forEach(([x, y], i) => {
      const w = px(9), h = px(115 - y), r = w / 2;
      cx.fillStyle = i < p.sinal ? '#fff' : 'rgba(255,255,255,.25)';   // apagada = cinza escuro (64,64,64 no fundo preto)
      cx.beginPath(); cx.roundRect ? cx.roundRect(px(x), px(y), w, h, r) : cx.rect(px(x), px(y), w, h); cx.fill();
    });
    cx.fillStyle = '#fff';
    // Wi-Fi: 3 ondas (as que passam do escolhido ficam apagadas)
    const cxw = px(968), cyw = px(116);
    cx.save(); cx.lineCap = 'round';
    [[px(37), 3], [px(24), 2]].forEach(([r, nivel]) => {
      cx.strokeStyle = p.wifi >= nivel ? '#fff' : 'rgba(255,255,255,.25)'; cx.lineWidth = px(8);
      cx.beginPath(); cx.arc(cxw, cyw - px(2), r, Math.PI * 1.27, Math.PI * 1.73); cx.stroke();
    });
    cx.fillStyle = '#fff'; cx.beginPath(); cx.moveTo(cxw, cyw); cx.arc(cxw, cyw - px(2), px(13), Math.PI * 1.27, Math.PI * 1.73); cx.closePath(); cx.fill();
    cx.restore();
    // bateria: corpo, nível, número dentro e a pontinha
    const bx = px(1017), by = px(77), bw = px(75), bh = px(40), br = px(13), n = Math.max(0, Math.min(1, bat.nivel));
    const caixa = () => { cx.beginPath(); cx.roundRect ? cx.roundRect(bx, by, bw, bh, br) : cx.rect(bx, by, bw, bh); };
    cx.save(); caixa(); cx.clip();
    cx.fillStyle = 'rgba(255,255,255,.5)'; cx.fillRect(bx, by, bw, bh);   // trilho cinza (127 no fundo preto, medido na calculadora de verdade)
    cx.fillStyle = bat.carregando ? '#34c759' : bat.economia ? '#f8d849' : '#fff'; cx.fillRect(bx, by, bw * n, bh);
    cx.restore();
    cx.fillStyle = 'rgba(255,255,255,.5)';
    cx.beginPath(); cx.roundRect ? cx.roundRect(px(1094), px(90), px(6), px(14), px(3)) : cx.rect(px(1094), px(90), px(6), px(14)); cx.fill();
    cx.font = '700 100px -apple-system, system-ui, "Inter", sans-serif';
    const m1 = cx.measureText('20'), tb = 100 * px(23) / m1.actualBoundingBoxAscent;
    cx.font = '700 ' + tb + 'px -apple-system, system-ui, "Inter", sans-serif';
    cx.fillStyle = '#000'; cx.textAlign = 'center';
    cx.fillText(String(Math.round(n * 100)), bx + bw / 2, px(110));
  }
  function animar(){ fadeRaf = 0; desenhar(); if(fadeIni && performance.now() - fadeIni < FADE) fadeRaf = requestAnimationFrame(animar); else fadeIni = 0; }
  function atualizarBateria(){
    if(!o.nativo) return;
    Promise.resolve().then(() => o.nativo('bateria')).then(r => { if(r && r.nivel >= 0){ bat = r; desenhar(); } }).catch(() => {});
  }
  function mostrar(sim){
    if(!ligada && sim){ mostrado = ''; antigo = ''; fadeIni = 0; }   // ao aparecer, sem fade
    ligada = !!sim; cv.style.display = ligada ? 'block' : 'none';
    clearInterval(tick); tick = null;
    if(ligada){ atualizarBateria(); desenhar(); tick = setInterval(() => { desenhar(); if(Date.now() % 30000 < 1000) atualizarBateria(); }, 1000); }
  }
  function hora(t){ texto = t || null; desenhar(); }
  cv.style.display = 'none';
  return {mostrar, hora, desenhar, ligada: () => ligada};
}
