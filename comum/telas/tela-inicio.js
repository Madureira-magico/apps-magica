/* =====================================================================
   PEÇA PRONTA (comum/telas): TELA DE INÍCIO FALSA igual à do Mosaico
   print com os ícones transparentes por cima do papel de parede (1184 x 2576),
   duas páginas (a 2ª volta sozinha), vidro da base e do Buscar (acordado ao abrir),
   ícone escurece no toque, e o app abre crescendo do ícone / fecha encolhendo até ele
   (animação de verdade do iPhone quando há a parte nativa; sem ela, uma parecida na página).
   Uso: ver comum/telas/GUIA.md
   ===================================================================== */
function criarTelaInicio(o){
  const raiz = o.raiz, ini = o.ini || 'ini/', PALCO = 1184 / 2576;
  raiz.insertAdjacentHTML('beforeend',
    '<div class="tiPalco"><div class="tiFundo"></div><div class="vidro tiDock"></div>' +
    '<div class="vidro tiBusca"><span class="txt"><svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="7" fill="none" stroke="currentColor" stroke-width="3"/><path d="M15.5 15.5 22 22" stroke="currentColor" stroke-width="3" stroke-linecap="round"/></svg><span>Buscar</span></span><span class="pts"><i class="on"></i><i></i></span></div>' +
    '<div class="tiPags"><div class="pag"><img src="' + ini + 'pag1.webp" alt=""><canvas class="tiRot"></canvas><div class="tiToque"></div></div><div class="pag p2"><img src="' + ini + 'pag2.webp" alt=""></div></div>' +
    '<img class="tiDockIc" src="' + ini + 'dock.webp" alt=""></div>');
  const q = s => raiz.querySelector(s);
  const palco = q('.tiPalco'), pg = q('.tiPags'), bu = q('.tiBusca'), pts = Array.from(raiz.querySelectorAll('.tiBusca .pts i')), toque = q('.tiToque');
  let pal = {x:0, y:0, w:1, h:1};
  function ajustar(){
    const W = innerWidth, H = innerHeight; let w = W, h = W / PALCO; if(h < H){ h = H; w = H * PALCO; }
    pal = {x:(W - w) / 2, y:(H - h) / 2, w, h};
    Object.assign(palco.style, {left:pal.x + 'px', top:pal.y + 'px', width:w + 'px', height:h + 'px'});
    q('.tiDock').style.borderRadius = (0.1014 * w) + 'px';
    const g = document.createElement('canvas').getContext('2d'); g.font = '600 10px -apple-system, system-ui';
    const f = 10 * (0.0946 * w) / g.measureText('Buscar').width, t = q('.tiBusca .txt'); t.style.fontSize = f + 'px';
    const sv = t.querySelector('svg'); sv.style.width = sv.style.height = (0.0233 * w) + 'px'; sv.style.marginRight = (0.0135 * w) + 'px';
    pts.forEach(i => { const d = 0.0195 * w; Object.assign(i.style, {width:d + 'px', height:d + 'px', margin:'0 ' + (0.0105 * w) + 'px'}); });
    const s = 0.1588 * w; Object.assign(toque.style, {width:s + 'px', height:s + 'px'});
  }
  /* nomes desenhados na letra do iPhone (ex.: "Instagram"), do mesmo tamanho dos outros */
  function desenhar(){
    if(innerWidth > innerHeight) return;
    ajustar();
    const DPR = Math.max(2, devicePixelRatio || 2), c = q('.tiRot'), cw = Math.round(pal.w * DPR), ch = Math.round(pal.h * DPR);
    c.width = cw; c.height = ch; const g = c.getContext('2d'); g.clearRect(0, 0, cw, ch);
    (o.rotulos || []).forEach(r => {
      const txt = typeof r.texto === 'function' ? r.texto() : r.texto; if(!txt) return;
      g.font = '500 10px -apple-system, system-ui'; const f = 10 * (r.larg * cw) / g.measureText('Instagram').width;
      g.font = '500 ' + f + 'px -apple-system, system-ui'; g.fillStyle = '#fff'; g.textAlign = 'center'; g.textBaseline = 'alphabetic';
      g.fillText(txt, r.cx * cw, r.topo * ch + 0.705 * f);
    });
  }
  function papel(url){ q('.tiFundo').style.backgroundImage = 'url("' + (url || ini + 'papel.jpg') + '")'; }
  /* força o iPhone a redesenhar o vidro da base e do Buscar (na abertura às vezes fica escuro até tocar na tela) */
  function acordarVidros(){
    const vs = Array.from(raiz.querySelectorAll('.vidro'));
    const f = () => {
      vs.forEach(v => { v.style.webkitBackdropFilter = 'none'; v.style.backdropFilter = 'none'; v.style.transform = 'translateZ(0)'; void v.offsetWidth; });
      requestAnimationFrame(() => vs.forEach(v => { v.style.webkitBackdropFilter = ''; v.style.backdropFilter = ''; v.style.transform = ''; }));
    };
    requestAnimationFrame(f); [150, 400, 800, 1500].forEach(t => setTimeout(f, t));
  }
  /* deslizar para o lado: só os ícones andam (papel de parede, Buscar e base ficam); a 2ª página volta sozinha */
  let x0 = 0, y0 = 0, dx = 0, modo = '', na2 = false, tVolta = 0, tPts = 0, t0 = 0, arrastou = false;
  const pos = (x, anim) => { pg.style.transition = anim ? 'transform .42s cubic-bezier(.25,.95,.3,1)' : 'none'; pg.style.transform = 'translate3d(' + x + 'px,0,0)'; };
  const ponto = i => pts.forEach((p, k) => p.classList.toggle('on', k === i));
  const mostrarPts = () => { clearTimeout(tPts); bu.classList.add('pg'); };
  const esconderPts = () => { clearTimeout(tPts); tPts = setTimeout(() => bu.classList.remove('pg'), 700); };
  const voltar = () => { clearTimeout(tVolta); mostrarPts(); na2 = false; pos(0, true); ponto(0); esconderPts(); };
  raiz.addEventListener('touchstart', e => { const t = e.touches[0]; x0 = t.clientX; y0 = t.clientY; dx = 0; modo = ''; t0 = Date.now(); }, {passive:true});
  raiz.addEventListener('touchmove', e => {
    const t = e.touches[0]; dx = t.clientX - x0;
    if(!modo && Math.hypot(dx, t.clientY - y0) > 10){ modo = Math.abs(dx) > Math.abs(t.clientY - y0) ? 'lado' : 'outro'; if(modo === 'lado'){ clearTimeout(tVolta); mostrarPts(); soltar(); } }
    if(modo !== 'lado') return;
    let x = (na2 ? -pal.w : 0) + dx;
    if(x > 0) x = x * 0.3; if(x < -pal.w) x = -pal.w + (x + pal.w) * 0.3;   // borrachinha nas pontas, igual ao iPhone
    pos(x); ponto(x < -pal.w / 2 ? 1 : 0);
  }, {passive:true});
  raiz.addEventListener('touchend', () => {
    if(modo !== 'lado') return;
    const rapido = Math.abs(dx) / Math.max(1, Date.now() - t0) > 0.4;
    if(!na2 && (dx < -pal.w * 0.4 || (rapido && dx < -30))){ na2 = true; pos(-pal.w, true); ponto(1); tVolta = setTimeout(voltar, 1000 + 420); }
    else if(na2 && (dx > pal.w * 0.4 || (rapido && dx > 30))) voltar();
    else { pos(na2 ? -pal.w : 0, true); ponto(na2 ? 1 : 0); if(na2) tVolta = setTimeout(voltar, 1000); else esconderPts(); }
    arrastou = true; setTimeout(() => { arrastou = false; }, 60);
  }, {passive:true});
  function pagina1(){ clearTimeout(tVolta); na2 = false; pos(0); ponto(0); bu.classList.remove('pg'); }
  /* toque nos ícones (posições em frações do print) */
  const noPalco = e => ({x:(e.clientX - pal.x) / pal.w, y:(e.clientY - pal.y) / pal.h});
  const perto = (e, p) => { const c = noPalco(e); return Math.abs(p.x - c.x) < 0.095 && Math.abs(p.y - c.y) < 0.05; };
  let hold = null, xy = null;
  function soltar(){ toque.classList.remove('on'); clearTimeout(hold); }
  raiz.addEventListener('pointerdown', e => {
    if(!e.isPrimary || na2) return; xy = [e.clientX, e.clientY];
    const p = (o.icones || []).find(i => perto(e, i));
    if(p){ const s = 0.1588 * pal.w; toque.style.left = (p.x * pal.w - s / 2) + 'px'; toque.style.top = (p.y * pal.h - s / 2) + 'px'; toque.classList.add('on'); }
    clearTimeout(hold); if(o.segurar && o.segurar.quando()) hold = setTimeout(() => { soltar(); o.segurar.acao(); }, o.segurar.ms || 1500);
  });
  raiz.addEventListener('pointermove', e => { if(xy && Math.hypot(e.clientX - xy[0], e.clientY - xy[1]) > 12) soltar(); });
  ['pointerup', 'pointercancel'].forEach(t => raiz.addEventListener(t, () => setTimeout(soltar, 80)));
  raiz.addEventListener('click', e => { if(arrastou || na2) return; const p = (o.icones || []).find(i => perto(e, i)); if(p && p.acao) p.acao(p); });
  /* abrir e fechar um app como no iPhone */
  const icone = p => ({x:pal.x + p.x * pal.w, y:pal.y + p.y * pal.h, s:0.1588 * pal.w});
  const doisQuadros = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const espera = ms => new Promise(r => setTimeout(r, ms));
  const anim = (el, fr, d) => { try { return el.animate(fr, {duration:d, easing:'cubic-bezier(.2,.8,.2,1)'}); } catch(_) { return null; } };
  let animando = false;
  /* el = a tela do app; antes() mostra o app por baixo (e esconde a tela de início); depois() no fim */
  async function abrirApp(p, el, antes, depois){
    if(animando) return; animando = true; const ic = icone(p);
    try {
      if(o.nativo){
        await Promise.resolve(o.nativo('telaCobrir')).catch(() => {});
        antes(); await doisQuadros(); await espera(30);
        await Promise.resolve(o.nativo('telaAbrir', ic)).catch(() => {});
      } else {
        el.style.zIndex = 45; el.style.transformOrigin = ic.x + 'px ' + ic.y + 'px';
        const a = anim(el, [{transform:'scale(.14)', opacity:0, borderRadius:'60px'}, {transform:'scale(1)', opacity:1, borderRadius:'0px'}], 380);
        await new Promise(r => { if(a) a.onfinish = r; else r(); });
        antes(); el.style.zIndex = '';
      }
    } catch(_) { antes(); } finally { animando = false; }
    depois && depois();
  }
  /* antes() mostra a tela de início por baixo */
  async function fecharApp(p, el, antes, depois){
    if(animando) return; animando = true; pagina1(); const ic = icone(p);
    try {
      if(o.nativo){
        await Promise.resolve(o.nativo('telaFechar', ic)).catch(() => {});
        antes(); acordarVidros(); await doisQuadros();
        await Promise.resolve(o.nativo('telaFecharVai', ic)).catch(() => {});
      } else {
        antes(); acordarVidros(); el.style.zIndex = 45; el.style.transformOrigin = ic.x + 'px ' + ic.y + 'px';
        const a = anim(el, [{transform:'scale(1)', opacity:1, borderRadius:'0px'}, {transform:'scale(.14)', opacity:0, borderRadius:'60px'}], 320);
        await new Promise(r => { if(a) a.onfinish = r; else r(); });
        el.style.zIndex = '';
      }
    } catch(_) { antes(); } finally { animando = false; }
    depois && depois();
  }
  document.addEventListener('visibilitychange', () => { if(!document.hidden) acordarVidros(); });
  papel(null);
  return {ajustar, desenhar, papel, acordarVidros, pagina1, abrirApp, fecharApp, icone, animando:() => animando};
}
