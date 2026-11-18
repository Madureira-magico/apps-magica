/* =====================================================================
   PEÇA PRONTA (comum/telas): BARRA DE CIMA FALSA igual à do iPhone
   (hora, sinal, Wi-Fi e bateria de verdade). Medidas tiradas do print do iPhone (402 pontos de largura).
   Serve para mostrar coisas escondidas no relógio (ex.: "17;05" na Calculadora).
   Uso: const bf = criarBarraFalsa({ raiz: elemento, nativo: cmd => Promise })
        bf.mostrar(true/false)   bf.hora(texto ou null = hora certa)   bf.desenhar()
   O app esconde a barra de verdade enquanto esta aparece (recado "barra" = true).
   ===================================================================== */
function criarBarraFalsa(o){
  const raiz = o.raiz;
  raiz.insertAdjacentHTML('beforeend', '<canvas class="bfCv" style="position:absolute;left:0;top:0;pointer-events:none;z-index:5"></canvas>');
  const cv = raiz.querySelector('.bfCv'), cx = cv.getContext('2d');
  let texto = null, bat = {nivel:0.8, carregando:false, economia:false}, wifi = null, tick = null, ligada = false;
  const px = v => v / 3;   // medidas do print estão em pixels de 3x
  function horaCerta(){ const d = new Date(); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); }   // como o relógio do iPhone em 24 h (00:46)
  function desenhar(){
    if(!ligada) return;
    const W = innerWidth, K = W / 402, H = 54 * K, dpr = window.devicePixelRatio || 2;
    if(cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)){ cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    cx.setTransform(dpr * K, 0, 0, dpr * K, 0, 0); cx.clearRect(0, 0, 402, 54);
    cx.fillStyle = '#fff';
    // hora: altura dos números igual ao print, centrada no lado esquerdo
    const t = texto || horaCerta();
    cx.font = '600 100px -apple-system, system-ui, "Inter", sans-serif';
    const m0 = cx.measureText('22:55'), tam = 100 * px(36) / m0.actualBoundingBoxAscent;
    cx.font = '600 ' + tam + 'px -apple-system, system-ui, "Inter", sans-serif';
    cx.textAlign = 'center'; cx.textBaseline = 'alphabetic';
    cx.fillText(t, px(187.5), px(115));
    // sinal: 4 barras
    [[864, 97], [880, 91], [896, 84], [912, 77]].forEach(([x, y]) => {
      const w = px(9), h = px(115 - y), r = w / 2;
      cx.beginPath(); cx.roundRect ? cx.roundRect(px(x), px(y), w, h, r) : cx.rect(px(x), px(y), w, h); cx.fill();
    });
    // Wi-Fi: o desenho do próprio iPhone (ou um parecido)
    if(wifi) cx.drawImage(wifi, px(941), px(77), px(55), px(39));
    else {
      const cxw = px(968), cyw = px(116);
      cx.save(); cx.lineCap = 'round'; cx.strokeStyle = '#fff';
      [[px(36), px(7)], [px(23), px(7)]].forEach(([r, lw]) => { cx.lineWidth = lw; cx.beginPath(); cx.arc(cxw, cyw - px(4), r, Math.PI * 1.25, Math.PI * 1.75); cx.stroke(); });
      cx.beginPath(); cx.moveTo(cxw, cyw); cx.lineTo(cxw - px(9), cyw - px(10)); cx.arc(cxw, cyw - px(14), px(11), Math.PI * 1.25, Math.PI * 1.75); cx.closePath(); cx.fill(); cx.restore();
    }
    // bateria: corpo, nível, número dentro e a pontinha
    const bx = px(1017), by = px(77), bw = px(75), bh = px(40), br = px(13), n = Math.max(0, Math.min(1, bat.nivel));
    const caixa = () => { cx.beginPath(); cx.roundRect ? cx.roundRect(bx, by, bw, bh, br) : cx.rect(bx, by, bw, bh); };
    cx.save(); caixa(); cx.clip();
    cx.fillStyle = 'rgba(255,255,255,.42)'; cx.fillRect(bx, by, bw, bh);
    cx.fillStyle = bat.carregando ? '#34c759' : bat.economia ? '#ffd60a' : '#fff'; cx.fillRect(bx, by, bw * n, bh);
    cx.restore();
    cx.fillStyle = 'rgba(255,255,255,.42)';
    cx.beginPath(); cx.roundRect ? cx.roundRect(px(1094), px(90), px(6), px(14), px(3)) : cx.rect(px(1094), px(90), px(6), px(14)); cx.fill();
    cx.font = '700 100px -apple-system, system-ui, "Inter", sans-serif';
    const m1 = cx.measureText('20'), tb = 100 * px(23) / m1.actualBoundingBoxAscent;
    cx.font = '700 ' + tb + 'px -apple-system, system-ui, "Inter", sans-serif';
    cx.fillStyle = '#000'; cx.textAlign = 'center';
    cx.fillText(String(Math.round(n * 100)), bx + bw / 2, px(110));
  }
  function atualizarBateria(){
    if(!o.nativo) return;
    Promise.resolve().then(() => o.nativo('bateria')).then(r => { if(r && r.nivel >= 0){ bat = r; desenhar(); } }).catch(() => {});
  }
  function mostrar(sim){
    ligada = !!sim; cv.style.display = ligada ? 'block' : 'none';
    clearInterval(tick); tick = null;
    if(ligada){ atualizarBateria(); desenhar(); tick = setInterval(() => { desenhar(); if(Date.now() % 30000 < 1000) atualizarBateria(); }, 1000); }
  }
  function hora(t){ texto = t || null; desenhar(); }
  if(o.nativo) Promise.resolve().then(() => o.nativo('wifi')).then(r => { if(r){ const i = new Image(); i.onload = () => { wifi = i; desenhar(); }; i.src = r; } }).catch(() => {});
  cv.style.display = 'none';
  return {mostrar, hora, desenhar, ligada: () => ligada};
}
