/* =====================================================================
   PEÇA PRONTA (comum/telas): TELA BLOQUEADA igual à do Timeline (iPhone novo)
   data "Ter. 17 de nov.", relógio grande (letra e grossura ajustáveis),
   botões de vidro com a lanterna e a câmera do próprio iPhone e a barrinha.
   Uso:  const tb = criarTelaBloqueio({ raiz: elemento, opcoes: () => ({letra, peso, zeroHora}), nativo: cmd => Promise })
         tb.mostrar()  (quando a tela aparece: mede, desenha, acorda o vidro e liga o relógio)
         tb.parar()    (quando some)        tb.medir() (mudou tamanho ou opções)
   ===================================================================== */
const TB_SVG_LAN = 'data:image/svg+xml;utf8,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="300" viewBox="0 0 40 100"><path fill="#fff" fill-rule="evenodd" d="M4 0h32a4 4 0 0 1 4 4v8H0V4a4 4 0 0 1 4-4zM0 17h40v4c0 6-8 12-8 18v54a7 7 0 0 1-7 7H15a7 7 0 0 1-7-7V39c0-6-8-12-8-18zm20 30a5 5 0 0 0-5 5v14a5 5 0 0 0 10 0V52a5 5 0 0 0-5-5zm0 12.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z"/></svg>');
const TB_SVG_CAM = 'data:image/svg+xml;utf8,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="234" viewBox="0 0 100 78"><path fill="#fff" fill-rule="evenodd" d="M36 0h28c4 0 6 2 8 5l4 7h12a12 12 0 0 1 12 12v42a12 12 0 0 1-12 12H12A12 12 0 0 1 0 66V24a12 12 0 0 1 12-12h12l4-7c2-3 4-5 8-5zm14 24a20 20 0 1 0 0 40 20 20 0 0 0 0-40zm0 8a12 12 0 1 1 0 24 12 12 0 0 1 0-24zm34-8a5 5 0 1 0 0 10 5 5 0 0 0 0-10z"/></svg>');
/* medidas tiradas do print do iPhone (tela de 402 pontos de largura) */
const TB_M = {dataTopo:87.3, dataLarg:135.5, relTopo:119.2, relLarg:242.1, relAlt:85.2,
              botDiam:58.5, botX:74.9, botBaixo:79.6, lanW:12.6, lanH:31.2, camW:27.5, camH:21.4,
              barraLarg:143.6, barraAlt:4.75, barraBaixo:8.5};
const TB_DIAS = ['Dom.', 'Seg.', 'Ter.', 'Qua.', 'Qui.', 'Sex.', 'Sáb.'];
const TB_MESES = ['jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.', 'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.'];
let tbIcones = null;   // {lan: Image, cam: Image} — os mesmos para todas as telas
function tbCarregarIcones(nativo){
  if(tbIcones) return Promise.resolve(tbIcones);
  const carregar = src => new Promise(ok => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => ok(null); i.src = src; });
  const svg = () => Promise.all([carregar(TB_SVG_LAN), carregar(TB_SVG_CAM)]);
  const pedir = nativo ? Promise.resolve().then(() => nativo('icones')).then(r => (r && r.lan) ? Promise.all([carregar(r.lan), carregar(r.cam)]) : svg()).catch(svg) : svg();
  return pedir.then(([lan, cam]) => (tbIcones = {lan, cam}));
}
function criarTelaBloqueio(o){
  const raiz = o.raiz;
  raiz.insertAdjacentHTML('beforeend', '<canvas class="tbRel"></canvas><div class="tbBot tbLan"></div><div class="tbBot tbCam"></div><div class="tbBarra"></div>');
  const cv = raiz.querySelector('.tbRel'), cx = cv.getContext('2d'), bLan = raiz.querySelector('.tbLan'), bCam = raiz.querySelector('.tbCam'), barra = raiz.querySelector('.tbBarra');
  let K = 1, W = 0, H = 0, fonteRel = '', escRel = 1, baseRel = 0, fonteData = '', baseData = 0, tick = null;
  const op = () => Object.assign({letra:'normal', peso:'500', zeroHora:true}, o.opcoes ? o.opcoes() : {});
  const familia = l => l === 'redonda' ? 'ui-rounded, "SF Pro Rounded", system-ui, -apple-system, sans-serif' : 'system-ui, -apple-system, "Inter", sans-serif';
  function textoData(d){ return TB_DIAS[d.getDay()] + ' ' + d.getDate() + ' de ' + TB_MESES[d.getMonth()]; }
  function textoHora(d){ const h = d.getHours(); return (op().zeroHora && h < 10 ? '0' : '') + h + ':' + String(d.getMinutes()).padStart(2, '0'); }
  function colocarIcone(b, img, w, h){
    b.innerHTML = '';
    const dpr = window.devicePixelRatio || 1, c = document.createElement('canvas');
    c.width = Math.round(w * K * dpr); c.height = Math.round(h * K * dpr);
    c.style.width = w * K + 'px'; c.style.height = h * K + 'px';
    b.appendChild(c);
    if(!img) return;
    // corta as sobras transparentes do desenho e estica na caixa medida no print
    const t = document.createElement('canvas'); t.width = img.width; t.height = img.height;
    const tg = t.getContext('2d'); tg.drawImage(img, 0, 0);
    const px = tg.getImageData(0, 0, t.width, t.height).data;
    let x0 = t.width, y0 = t.height, x1 = 0, y1 = 0;
    for(let y = 0; y < t.height; y++) for(let x = 0; x < t.width; x++) if(px[(y * t.width + x) * 4 + 3] > 40){ if(x < x0) x0 = x; if(x > x1) x1 = x; if(y < y0) y0 = y; if(y > y1) y1 = y; }
    if(x1 <= x0) return;
    c.getContext('2d').drawImage(img, x0, y0, x1 - x0 + 1, y1 - y0 + 1, 0, 0, c.width, c.height);
  }
  function icones(){ if(!tbIcones) return; colocarIcone(bLan, tbIcones.lan, TB_M.lanW, TB_M.lanH); colocarIcone(bCam, tbIcones.cam, TB_M.camW, TB_M.camH); }
  function medir(){
    W = raiz.clientWidth || innerWidth; H = raiz.clientHeight || innerHeight; K = W / 402;
    if(!W || !H) return;
    const dpr = window.devicePixelRatio || 1, p = op();
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    cx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // relógio: tamanho para a altura dos números bater com o print, depois estica na largura
    cx.font = p.peso + ' 100px ' + familia(p.letra);
    let m = cx.measureText('11:57');
    const tam = 100 * (TB_M.relAlt * K) / m.actualBoundingBoxAscent;
    fonteRel = p.peso + ' ' + tam + 'px ' + familia(p.letra);
    cx.font = fonteRel; m = cx.measureText('11:57');
    escRel = (TB_M.relLarg * K) / (m.actualBoundingBoxLeft + m.actualBoundingBoxRight);
    baseRel = TB_M.relTopo * K + m.actualBoundingBoxAscent;
    // data: tamanho para a largura de "Ter. 17 de nov." bater com o print
    cx.font = '600 100px system-ui, -apple-system, "Inter", sans-serif';
    m = cx.measureText('Ter. 17 de nov.');
    const td = 100 * (TB_M.dataLarg * K) / (m.actualBoundingBoxLeft + m.actualBoundingBoxRight);
    fonteData = '600 ' + td + 'px system-ui, -apple-system, "Inter", sans-serif';
    cx.font = fonteData; m = cx.measureText('Ter. 17 de nov.');
    baseData = TB_M.dataTopo * K + m.actualBoundingBoxAscent;
    [[bLan, TB_M.botX], [bCam, 402 - TB_M.botX]].forEach(([b, x]) => {
      const d = TB_M.botDiam * K;
      Object.assign(b.style, {width:d + 'px', height:d + 'px', left:(x * K - d / 2) + 'px', bottom:(TB_M.botBaixo * K - d / 2) + 'px'});
    });
    Object.assign(barra.style, {width:TB_M.barraLarg * K + 'px', height:TB_M.barraAlt * K + 'px', bottom:TB_M.barraBaixo * K + 'px', borderRadius:TB_M.barraAlt * K / 2 + 'px'});
    icones(); desenhar();
  }
  function desenhar(){
    if(!W) return;
    cx.clearRect(0, 0, W, H);
    const d = new Date();
    cx.save(); cx.font = fonteData; cx.fillStyle = '#fff'; cx.textAlign = 'center'; cx.textBaseline = 'alphabetic';
    cx.fillText(textoData(d), W / 2, baseData); cx.restore();
    const txt = textoHora(d);
    cx.save(); cx.font = fonteRel; cx.textBaseline = 'alphabetic';
    const m = cx.measureText(txt), larg = (m.actualBoundingBoxLeft + m.actualBoundingBoxRight) * escRel;
    cx.translate(W / 2 - larg / 2, baseRel); cx.scale(escRel, 1);
    cx.fillStyle = '#fff'; cx.fillText(txt, m.actualBoundingBoxLeft, 0);
    cx.restore();
  }
  /* força o iPhone a redesenhar o vidro dos botões (sem isso às vezes fica escuro até tocar na tela) */
  function acordar(){
    const bs = [bLan, bCam];
    const f = () => {
      bs.forEach(b => { b.style.webkitBackdropFilter = 'none'; b.style.backdropFilter = 'none'; b.style.transform = 'translateZ(0)'; void b.offsetWidth; });
      requestAnimationFrame(() => bs.forEach(b => { b.style.webkitBackdropFilter = ''; b.style.backdropFilter = ''; b.style.transform = ''; }));
    };
    requestAnimationFrame(f); [120, 350, 700, 1500].forEach(t => setTimeout(f, t));
  }
  function mostrar(){ medir(); acordar(); clearInterval(tick); tick = setInterval(desenhar, 1000); }
  function parar(){ clearInterval(tick); tick = null; }
  tbCarregarIcones(o.nativo).then(icones);
  return {medir, desenhar, mostrar, parar, acordar};
}
