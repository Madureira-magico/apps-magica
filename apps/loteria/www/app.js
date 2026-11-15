/* Loterias — app de mágica (abertura, tela azul, cartões, volante, número da sorte, modo mágica, ajustes) */
'use strict';

const $ = s => document.querySelector(s);
const app = $('#app');
const NATIVO = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lt);
const W = 402;
let Z = 1, H = 874, ST = 62;

function nativo(cmd, extra) {
  if (!NATIVO) return Promise.reject(new Error('sem app'));
  return window.webkit.messageHandlers.lt.postMessage(Object.assign({cmd}, extra || {}));
}
function barra(estilo) {
  try { window.webkit.messageHandlers.barra.postMessage(false); } catch (e) {}
  try { window.webkit.messageHandlers.estilo.postMessage(estilo); } catch (e) {}
}

/* ---------- tamanho da tela: tudo é desenhado em 402 de largura e ampliado/reduzido ---------- */
function medir() {
  Z = window.innerWidth / W;
  document.body.style.zoom = Z;
  H = window.innerHeight / Z;
  app.style.height = H + 'px';
  const t = document.createElement('div');
  t.style.cssText = 'position:fixed;top:0;height:env(safe-area-inset-top);width:1px;visibility:hidden';
  document.body.appendChild(t);
  const st = t.getBoundingClientRect().height;
  t.remove();
  ST = st > 5 ? st : (NATIVO ? 20 : 62);
  app.style.setProperty('--st', ST + 'px');
}
medir();
window.addEventListener('resize', () => { medir(); posicionarAviso(); });

/* ---------- cores ---------- */
function hex2rgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; }
function mistura(h, b, t) { const a = hex2rgb(h), c = hex2rgb(b); return '#' + a.map((v, i) => Math.round(v + (c[i] - v) * t).toString(16).padStart(2, '0')).join(''); }

/* ---------- trevo genérico (folhas redondas) ---------- */
function trevoSVG(a, b, c, d) {
  return `<svg viewBox="0 0 24 24"><circle cx="7.2" cy="7.2" r="5.6" fill="${a}"/><circle cx="16.8" cy="7.2" r="5.6" fill="${b}"/><circle cx="7.2" cy="16.8" r="5.6" fill="${c}"/><circle cx="16.8" cy="16.8" r="5.6" fill="${d}"/></svg>`;
}

/* ---------- imagens escolhidas pelo mágico ---------- */
const IMGS = ['logo', 'icone', 'printAzul', 'printAbertura'];
function imgInfo(k) { return guarda.ler('img_' + k, null); }
function imgURL(k) {
  const i = imgInfo(k);
  if (!i) return null;
  if (NATIVO) return 'ltarq://f/' + i.nome + '?v=' + i.v;
  try { return localStorage.getItem('lt_dados_' + k); } catch (e) { return null; }
}
function carregarImagem(src) {
  return new Promise((ok, erro) => { const im = new Image(); im.crossOrigin = 'anonymous'; im.onload = () => ok(im); im.onerror = erro; im.src = src; });
}

/* ícone do usuário repintado para a faixa de cada jogo: partes claras -> branco, partes coloridas -> tom claro do jogo */
const cacheIcone = {};
let iconeBase = null;
async function prepararIcone() {
  Object.keys(cacheIcone).forEach(k => delete cacheIcone[k]);
  iconeBase = null;
  const u = imgURL('icone');
  if (!u) return;
  try { iconeBase = await carregarImagem(u); } catch (e) { iconeBase = null; }
}
function iconeDoJogo(j) {
  if (!iconeBase) return null;
  if (cacheIcone[j.id]) return cacheIcone[j.id];
  const lado = 96, c = document.createElement('canvas');
  c.width = c.height = lado;
  const x = c.getContext('2d');
  const r = Math.min(lado / iconeBase.width, lado / iconeBase.height);
  const w = iconeBase.width * r, h = iconeBase.height * r;
  x.drawImage(iconeBase, (lado - w) / 2, (lado - h) / 2, w, h);
  try {
    const d = x.getImageData(0, 0, lado, lado), p = d.data;
    const A = hex2rgb(j.trevoA || '#ffffff'), B = hex2rgb(j.trevoB || mistura(j.cor2, '#ffffff', .5));
    for (let i = 0; i < p.length; i += 4) {
      if (p[i + 3] < 8) continue;
      const mx = Math.max(p[i], p[i + 1], p[i + 2]), mn = Math.min(p[i], p[i + 1], p[i + 2]);
      const sat = mx ? (mx - mn) / mx : 0, claro = mx / 255;
      const alvo = (sat < .28 && claro > .62) ? A : B;
      p[i] = alvo[0]; p[i + 1] = alvo[1]; p[i + 2] = alvo[2];
    }
    x.putImageData(d, 0, 0);
    cacheIcone[j.id] = c.toDataURL('image/png');
  } catch (e) { cacheIcone[j.id] = imgURL('icone'); }
  return cacheIcone[j.id];
}
function trevoDoJogo(j) {
  const u = iconeDoJogo(j);
  if (u) return `<img src="${u}" alt="">`;
  const A = j.trevoA || '#ffffff', B = j.trevoB || mistura(j.cor2, '#ffffff', .5);
  return trevoSVG(A, B, B, A);
}

/* ---------- desenho da Mega da Virada (formas e fogos) ---------- */
function padraoVirada(w, h, fogos) {
  let s = 7, rnd = () => (s = (s * 16807) % 2147483647) / 2147483647;
  const tons = ['#7dc242', '#55b24a', '#0e8a44', '#a6d15a'];
  let f = '';
  const c = 22;
  for (let y = 0; y < h + c; y += c) for (let x = 0; x < w + c; x += c) {
    const t = rnd(), cor = tons[Math.floor(rnd() * tons.length)], op = (.22 + rnd() * .3).toFixed(2);
    if (t < .28) f += `<path d="M${x} ${y}h${c}a${c} ${c} 0 0 1-${c} ${c}z" fill="${cor}" opacity="${op}"/>`;
    else if (t < .46) f += `<path d="M${x + c} ${y + c}h-${c}a${c} ${c} 0 0 1 ${c}-${c}z" fill="${cor}" opacity="${op}"/>`;
    else if (t < .6) f += `<path d="M${x} ${y + c}a${c / 2} ${c / 2} 0 0 1 ${c} 0z" fill="${cor}" opacity="${op}"/>`;
    else if (t < .68) f += `<circle cx="${x + c / 2}" cy="${y + c / 2}" r="${c / 2.6}" fill="${cor}" opacity="${op}"/>`;
  }
  if (fogos) {
    const estouro = (cx, cy, r, cor, n) => {
      let g = '';
      for (let i = 0; i < n; i++) {
        const a = i / n * Math.PI * 2 + rnd() * .1, r1 = r * (.25 + rnd() * .2), r2 = r * (.75 + rnd() * .3);
        g += `<line x1="${(cx + Math.cos(a) * r1).toFixed(1)}" y1="${(cy + Math.sin(a) * r1).toFixed(1)}" x2="${(cx + Math.cos(a) * r2).toFixed(1)}" y2="${(cy + Math.sin(a) * r2).toFixed(1)}" stroke="${cor}" stroke-width="1.1" stroke-dasharray="1.5 2" stroke-linecap="round"/>`;
        g += `<circle cx="${(cx + Math.cos(a) * r2 * 1.05).toFixed(1)}" cy="${(cy + Math.sin(a) * r2 * 1.05).toFixed(1)}" r=".9" fill="${cor}"/>`;
      }
      return g;
    };
    f += estouro(w * .55, 2, 34, '#e9b6e6', 34);
    f += estouro(w * .86, 6, 40, '#f7d54a', 40);
    f += estouro(w * .97, 40, 22, '#f2a93b', 22);
    f += `<path d="M${w * .7} ${h} q6 -14 22 -20" stroke="#7fd3ff" stroke-width="1.3" fill="none" stroke-dasharray="2 2"/>`;
  }
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" height="100%" preserveAspectRatio="xMidYMid slice" style="position:absolute;inset:0">${f}</svg>`;
}

/* ======================================================================
   TELAS
   ====================================================================== */
let telaAtual = '';
function mostrar(id) {
  document.querySelectorAll('.tela').forEach(t => t.classList.toggle('on', t.id === id));
  telaAtual = id;
  if (id === 'cartoes') barra('escuro');
  else if (id === 'volante') barra(volJogo && volJogo.id === 'timemania' ? 'escuro' : 'claro');
  else barra('claro');
}

/* ---------- 1. abertura ---------- */
const TREVOS_FUNDO = [[300, 70, 70, 20], [338, 190, 110, -12], [-30, 470, 90, 30], [60, 560, 80, -20], [380, 330, 70, 15],
  [255, 410, 60, -30], [345, 820, 120, 10], [35, 820, 110, 25], [200, 760, 60, 5], [160, 30, 50, 40], [10, 250, 55, -15], [230, 600, 45, 20]];
function montarTrevosFundo() {
  $('#abTrevos').innerHTML = TREVOS_FUNDO.map(([x, y, s, r]) =>
    `<svg viewBox="0 0 24 24" style="left:${x - s / 2}px;top:${y - s / 2}px;width:${s}px;height:${s}px;transform:rotate(${r}deg)"><g fill="#003d82"><circle cx="7.2" cy="7.2" r="5.6"/><circle cx="16.8" cy="7.2" r="5.6"/><circle cx="7.2" cy="16.8" r="5.6"/><circle cx="16.8" cy="16.8" r="5.6"/></g></svg>`).join('');
}
montarTrevosFundo();

function bolha(cx, cy, rx, ry) {
  return `<g class="bo" style="transform-origin:${cx}px ${cy}px"><ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="none" stroke="#fff" stroke-width="1.8"/>` +
    `<path d="M${cx - rx} ${cy}a${rx} ${ry} 0 0 0 ${rx * 2} 0" fill="none" stroke="#fff" stroke-width="${ry * .55}" stroke-dasharray="1.2 1.6" transform="translate(0 ${ry * .18})" opacity=".9"/></g>`;
}
function arco(cx, cy, rx, ry, a1, a2) {
  // arco da elipse do ângulo a1 ao a2 (graus, sentido anti-horário na tela passando por baixo)
  const P = a => [cx + Math.cos(a * Math.PI / 180) * rx, cy + Math.sin(a * Math.PI / 180) * ry];
  const [x1, y1] = P(a1), [x2, y2] = P(a2);
  return `M${x1.toFixed(1)} ${y1.toFixed(1)}A${rx} ${ry} 0 0 0 ${x2.toFixed(1)} ${y2.toFixed(1)}`;
}
function desenharAnimacao() {
  const cx = 201, cy = 402, rx = 150, ry = 102;
  let ticks = '';
  for (let i = 0; i < 14; i++) {
    const a = -Math.PI * .95 + i * (Math.PI * 1.9 / 13) - .3;
    const r1 = 1.13, r2 = 1.22;
    ticks += `<line x1="${cx + Math.cos(a) * rx * r1}" y1="${cy + Math.sin(a) * ry * r1}" x2="${cx + Math.cos(a) * rx * r2}" y2="${cy + Math.sin(a) * ry * r2}" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>`;
  }
  $('#abAnim').innerHTML =
    `<style>#abAnim .bo,#abAnim .ba,#abAnim .ti{opacity:0;transform:scale(.4);transition:opacity .25s,transform .35s cubic-bezier(.2,1.5,.4,1)}#abAnim .on{opacity:1;transform:none}#abAnim .some{opacity:0!important;transform:scale(.35)!important;transition:opacity .35s,transform .4s ease-in}</style>` +
    `<g id="anB1">${bolha(221, 579, 9, 6)}</g><g id="anB2">${bolha(243, 559, 12, 8)}</g><g id="anB3">${bolha(268, 533, 16, 11)}</g>` +
    `<g id="anBal" class="ba" style="transform-origin:${cx}px ${cy + 40}px">` +
    `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="none" stroke="#fff" stroke-width="3"/>` +
    `<path d="${arco(cx, cy, rx - 7, ry - 7, 158, 52)}" fill="none" stroke="#fff" stroke-width="9" stroke-dasharray="1.4 3.2" opacity=".95"/>` +
    `<path d="${arco(cx, cy, rx - 12.5, ry - 12.5, 160, 50)}" fill="none" stroke="#fff" stroke-width="1.6"/>` +
    `</g><g id="anTi" class="ti" style="transform-origin:${cx}px ${cy}px">${ticks}</g>`;
}

let abTimers = [];
function abertura() {
  abTimers.forEach(clearTimeout); abTimers = [];
  const ab = $('#abertura');
  ab.classList.remove('claro');
  $('#abLogo').classList.remove('on');
  mostrar('abertura');
  prepararAzul();
  const depois = (ms, f) => abTimers.push(setTimeout(f, ms));

  if (guarda.ler('temVideo', false) && NATIVO) {
    // vídeo do mágico por cima; a tela azul já fica pronta por baixo (corte seco quando o vídeo acaba)
    $('#abAnim').innerHTML = '';
    nativo('tocarVideo').then(ok => { if (ok) irAzul(); else animacaoPadrao(depois); }).catch(() => animacaoPadrao(depois));
    depois(120, () => { if (telaAtual === 'abertura') mostrar('azul'); });
    return;
  }
  const pa = imgURL('printAbertura');
  const pr = $('#abPrint');
  if (pa) {
    pr.src = pa; pr.classList.add('on');
    $('#abAnim').innerHTML = '';
    depois(3500, irAzul);
    return;
  }
  pr.classList.remove('on');
  animacaoPadrao(depois);
}
function animacaoPadrao(depois) {
  desenharAnimacao();
  const on = id => { const e = document.getElementById(id); if (e) (e.querySelector('.bo') || e).classList.add('on'); };
  const lg = imgURL('logo'), abl = $('#abLogo');
  if (lg) abl.src = lg; else abl.removeAttribute('src');
  depois(650, () => $('#abertura').classList.add('claro'));
  depois(1400, () => on('anB1'));
  depois(1800, () => on('anB2'));
  depois(2200, () => on('anB3'));
  depois(2500, () => { $('#anBal').classList.add('on'); $('#anTi').classList.add('on'); });
  depois(2950, () => $('#anTi').classList.add('some'));
  depois(3050, () => { ['anBal', 'anB1', 'anB2', 'anB3'].forEach(id => { const e = document.getElementById(id); (e.querySelector('.bo') || e).classList.add('some'); }); });
  depois(3450, () => { if (lg) abl.classList.add('on'); });
  depois(4500, irAzul);
}

/* ---------- 2. tela azul ---------- */
function prepararAzul() {
  const lg = imgURL('logo'), az = $('#azLogo');
  if (lg) { az.src = lg; az.style.display = ''; } else { az.removeAttribute('src'); az.style.display = 'none'; }
  const p = imgURL('printAzul'), ap = $('#azPrint');
  if (p) { ap.src = p; ap.classList.add('on'); } else { ap.classList.remove('on'); ap.removeAttribute('src'); }
}
function irAzul() { abTimers.forEach(clearTimeout); abTimers = []; mostrar('azul'); }
$('#azZona').addEventListener('click', () => { pedirSensor(); irCartoes(); });

/* ---------- 3. cartões ---------- */
let lista = [], pos = 0, cartoesEl = [];
function montarCartoes() {
  lista = JOGOS.filter(j => !j.virada || viradaVisivel());
  const c = $('#carrossel');
  c.innerHTML = '';
  cartoesEl = lista.map(j => {
    const el = document.createElement('div');
    el.className = 'cartao';
    const corNome = j.nomeCor || j.texto || '#fff';
    const corTab = j.texto || '#fff';
    el.innerHTML =
      `<div class="ctab" style="background:${j.cor};color:${corTab}">Último resultado<svg viewBox="0 0 12 12"><path d="M2 4l4 4 4-4" fill="none" stroke="${corTab}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></div>` +
      `<div class="cban" style="background:${j.cor2}">${j.virada ? `<div class="cdeco">${padraoVirada(304, 63, true)}</div>` : ''}` +
      `<div class="cesq" style="background:${j.cor}"></div>` +
      `<div class="ctrevo">${trevoDoJogo(j)}</div><div class="cnome" style="color:${corNome}">${j.nome}</div></div>` +
      `<div class="ccorpo">` +
      `${decoTrevos()}` +
      `<div class="cpremio esmaece" style="color:${j.premioCor}"></div><div class="cmilhoes esmaece" style="color:${j.premioCor}"></div>` +
      `<div class="cconc esmaece"></div><div class="cdiv"></div>` +
      `<div class="cico esmaece" style="top:127.4px">${iconeCalendario(j.premioCor)}</div>` +
      `<div class="ctx esmaece csort" style="top:120.9px"></div>` +
      `<div class="cico esmaece" style="top:189.4px">${iconeRelogio(j.premioCor)}</div>` +
      `<div class="ctx esmaece cfecha" style="top:185.5px">Apostas se encerram em<b></b></div>` +
      `</div>` +
      `<div class="cbolao esmaece">Compre seu bolão</div>` +
      `<div class="caposte esmaece" style="background:${j.cor};color:${j.texto || '#fff'}"><b>Aposte</b><span>por ${reais(j.preco)}</span></div>`;
    el.dataset.id = j.id;
    c.appendChild(el);
    return el;
  });
  preencherCartoes();
  desenharCarrossel();
}
function decoTrevos() {
  const ts = [[262, 410, 22, 10], [215, 455, 52, -15], [180, 505, 30, 25], [40, 470, 26, -10], [235, 515, 60, 5], [15, 540, 22, 30]];
  return ts.map(([x, y, s, r]) => `<div class="cdec" style="left:${x}px;top:${y}px;width:${s}px;height:${s}px;transform:rotate(${r}deg)">${trevoSVG('#333', '#333', '#333', '#333')}</div>`).join('');
}
function iconeCalendario(c) {
  return `<svg viewBox="0 0 16 16"><rect x="1.2" y="2.4" width="13.6" height="12.4" rx="1" fill="none" stroke="${c}" stroke-width="1.4"/><path d="M1.2 5.8h13.6M4.5 1v3M11.5 1v3" stroke="${c}" stroke-width="1.4"/><g fill="${c}"><rect x="3.6" y="7.6" width="2" height="1.7"/><rect x="7" y="7.6" width="2" height="1.7"/><rect x="10.4" y="7.6" width="2" height="1.7"/><rect x="3.6" y="10.8" width="2" height="1.7"/><rect x="7" y="10.8" width="2" height="1.7"/><rect x="10.4" y="10.8" width="2" height="1.7"/></g></svg>`;
}
function iconeRelogio(c) {
  return `<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.8" fill="none" stroke="${c}" stroke-width="1.6"/><path d="M8 4v4.4h3.4" fill="none" stroke="${c}" stroke-width="1.6" stroke-linecap="round"/></svg>`;
}
function preencherCartoes() {
  const agora = new Date();
  cartoesEl.forEach((el, i) => {
    const j = lista[i], f = info(j, agora);
    el.querySelector('.cpremio').textContent = reais(f.premio);
    el.querySelector('.cmilhoes').textContent = '(' + porExtenso(f.premio) + ')';
    el.querySelector('.cconc').textContent = 'Prêmio estimado do concurso ' + f.conc;
    el.querySelector('.csort').innerHTML = (j.encerramento ? 'Encerramento' : 'Sorteio') + '<b>' + textoData(f.sorteio) + '<br>' + textoHora(f.sorteio) + '</b>';
    el.querySelector('.cfecha b').textContent = textoFalta(f.fecha, agora);
  });
}
function desenharCarrossel() {
  const n = lista.length;
  cartoesEl.forEach((el, i) => {
    let o = ((i - pos) % n + n) % n;
    if (o > n / 2) o -= n;
    if (Math.abs(o) > 2.2) { el.style.display = 'none'; return; }
    el.style.display = '';
    const s = 1 - .13 * Math.min(Math.abs(o), 1);
    el.style.transform = `translateX(${o * 314.5}px) scale(${s})`;
    el.style.zIndex = String(10 - Math.round(Math.abs(o) * 2));
    el.classList.toggle('lado', Math.abs(o) > .5);
  });
}
function irCartoes() {
  mostrar('cartoes');
  preencherCartoes();
  desenharCarrossel();
}

/* arrastar os cartões */
(function () {
  const c = $('#carrossel');
  let x0 = null, y0 = 0, p0 = 0, t0 = 0, mexeu = false, anim = null;
  function animar(alvo) {
    cancelAnimationFrame(anim);
    const ini = pos, ti = performance.now(), dur = 300;
    const passo = t => {
      const k = Math.min(1, (t - ti) / dur), e = 1 - Math.pow(1 - k, 3);
      pos = ini + (alvo - ini) * e;
      desenharCarrossel();
      if (k < 1) anim = requestAnimationFrame(passo);
      else { const n = lista.length; pos = ((Math.round(pos) % n) + n) % n; desenharCarrossel(); }
    };
    anim = requestAnimationFrame(passo);
  }
  c.addEventListener('pointerdown', e => {
    if (!e.isPrimary) return;
    cancelAnimationFrame(anim);
    x0 = e.clientX; y0 = e.clientY; p0 = pos; t0 = performance.now(); mexeu = false;
  });
  window.addEventListener('pointermove', e => {
    if (x0 == null || !e.isPrimary) return;
    const dx = (e.clientX - x0) / Z;
    if (Math.abs(dx) > 6) mexeu = true;
    if (mexeu) { pos = p0 - dx / 314.5; desenharCarrossel(); }
  });
  window.addEventListener('pointerup', e => {
    if (x0 == null || !e.isPrimary) return;
    const dx = (e.clientX - x0) / Z, dt = performance.now() - t0;
    x0 = null;
    if (!mexeu) {
      if (gestoUsado) return;
      // toque: "Aposte" do cartão do meio abre o volante
      const alvo = document.elementFromPoint(e.clientX, e.clientY);
      const ap = alvo && alvo.closest('.caposte');
      if (ap) {
        const el = ap.closest('.cartao');
        if (!el.classList.contains('lado')) { const j = JOGO[el.dataset.id]; if (j.total) abrirVolante(j); }
        else animar(Math.round(pos) + (cartoesEl.indexOf(el) - Math.round(pos) > 0 ? 1 : -1));
      }
      return;
    }
    let alvo = Math.round(pos);
    const rapido = Math.abs(dx) / dt > .35;
    if (rapido || Math.abs(dx) > 60) alvo = Math.round(p0) + (dx < 0 ? 1 : -1);
    animar(alvo);
  });
})();
setInterval(() => { if (telaAtual === 'cartoes') preencherCartoes(); }, 30000);

/* ======================================================================
   VOLANTE
   ====================================================================== */
let volJogo = null, sel = new Set(), avisoMostrado = false, sorte = null, volInfo = null;
const grade = $('#vGrade');

function abrirVolante(j) {
  volJogo = j; sel = new Set(); avisoMostrado = false; sorte = null; magia.fila = null;
  volInfo = info(j);
  const cab = $('#vCab');
  cab.style.background = j.virada ? j.cor2 : j.cor;
  cab.querySelectorAll('.vpad').forEach(e => e.remove());
  if (j.virada) { const d = document.createElement('div'); d.className = 'vpad'; d.innerHTML = padraoVirada(402, 130, false); cab.prepend(d); }
  const corTxt = j.texto || '#fff';
  cab.style.color = corTxt;
  $('#vVoltar path').setAttribute('stroke', corTxt);
  $('.vajuda').style.borderColor = corTxt;
  $('#vSort').textContent = p2(volInfo.sorteio.getDate()) + '/' + p2(volInfo.sorteio.getMonth() + 1);
  $('#vQtd').style.background = j.cor;
  $('#vQtd').style.color = j.texto || '#fff';
  // números
  let h = '';
  for (let i = 0; i < j.total; i++) {
    const n = j.zero ? i : i + 1;
    h += `<div class="vn" data-n="${n}">${p2(n)}</div>`;
  }
  grade.innerHTML = h;
  grade.scrollTop = 0;
  mostrar('volante');
  tituloCabe(j.nome);
  atualizarVolante();
}
/* título do volante: se não couber, corta na palavra e põe "..." (como "mega da...") */
function tituloCabe(nome) {
  const t = $('#vTitulo'), max = 157;
  t.style.maxWidth = 'none';
  t.textContent = nome;
  if (t.scrollWidth <= max) { t.style.maxWidth = ''; return; }
  const p = nome.split(' ');
  for (let k = p.length - 1; k >= 1; k--) {
    t.textContent = p.slice(0, k).join(' ') + '...';
    if (t.scrollWidth <= max) break;
  }
  t.style.maxWidth = '';
}
function textoConcurso() {
  const c = String(volInfo.conc);
  if (sorte == null) return c;
  return c.slice(0, -2) + p2(sorte % 100);
}
function atualizarVolante() {
  const j = volJogo, n = sel.size, q = Math.max(j.base, n);
  $('#vConc').textContent = textoConcurso();
  grade.querySelectorAll('.vn').forEach(e => {
    const on = sel.has(+e.dataset.n);
    e.classList.toggle('sel', on);
    e.style.background = on ? j.cor : '';
    e.style.borderColor = on ? j.cor : '';
    e.style.color = on ? (j.texto || '#fff') : '';
  });
  $('#vQtd').innerHTML = q + ' números <s></s>';
  $('#vCont').textContent = n ? 'Selecionados: ' + n + '/' + q : 'Selecione os números:';
  const b1 = $('#vBtn1'), b2 = $('#vBtn2'), add = $('#vAdd');
  b1.classList.remove('off');
  if (n === 0) b1.textContent = 'Aposta aleatória';
  else if (n < j.base) b1.textContent = 'Completar jogo';
  else b1.innerHTML = '<svg class="estrela" viewBox="0 0 24 24"><path d="M12 2.8l2.8 6 6.5.7-4.9 4.4 1.4 6.4L12 17l-5.8 3.3 1.4-6.4-4.9-4.4 6.5-.7z" fill="none" stroke="#222" stroke-width="1.6" stroke-linejoin="round"/></svg>Favoritar aposta';
  b2.classList.toggle('off', n === 0);
  const pronto = n >= j.base;
  add.classList.toggle('on', pronto);
  add.classList.toggle('off', !pronto);
  add.style.background = pronto ? j.cor : '';
  add.style.borderColor = pronto ? j.cor : '';
  add.style.color = pronto ? (j.texto || '#fff') : '';
  $('#vValor').textContent = reais(combinacoes(q, j.base) * j.preco);
}
function sortearAte(qtd) {
  const j = volJogo, livres = [];
  for (let i = 0; i < j.total; i++) { const n = j.zero ? i : i + 1; if (!sel.has(n)) livres.push(n); }
  while (sel.size < qtd && livres.length) sel.add(livres.splice(Math.floor(Math.random() * livres.length), 1)[0]);
}
grade.addEventListener('click', e => {
  if (gestoUsado || magia.virado) return;
  const el = e.target.closest('.vn');
  if (!el) return;
  const n = +el.dataset.n, j = volJogo;
  if (sel.has(n)) sel.delete(n);
  else {
    if (sel.size >= j.max) return;
    sel.add(n);
    if (sorte == null) sorte = n;               // número da sorte: o primeiro tocado
    if (sel.size === j.base + 1 && !avisoMostrado) { avisoMostrado = true; mostrarAviso(); }
  }
  atualizarVolante();
});
$('#vBtn1').addEventListener('click', () => {
  if (gestoUsado || magia.virado) return;
  const j = volJogo, n = sel.size;
  if (n < j.base) { sortearAte(j.base); atualizarVolante(); }
});
$('#vBtn2').addEventListener('click', () => {
  if (gestoUsado || magia.virado || !sel.size) return;
  sel.clear(); avisoMostrado = false; magia.fila = null;
  atualizarVolante();
});
$('#vVoltar').addEventListener('click', () => { if (!gestoUsado) irCartoes(); });

/* aviso "Atenção" */
function posicionarAviso() { $('.avcaixa').style.top = Math.max(ST + 80, (H - 309) / 2 + 14) + 'px'; }
function mostrarAviso() { posicionarAviso(); $('#aviso').classList.add('on'); }
$('#avOk').addEventListener('click', () => $('#aviso').classList.remove('on'));

/* ======================================================================
   MODO MÁGICA — celular virado para baixo
   ====================================================================== */
const magia = {virado: false, fila: null, beta: 0};
function bilhete() { const b = guarda.ler('bilhete', [5, 12, 23, 34, 41, 58]); return b.filter(n => n >= 1 && n <= 60).slice(0, 6); }
function magiaPode() {
  return guarda.ler('magica', true) && telaAtual === 'volante' && volJogo && volJogo.total === 60 && !$('#ajustes').classList.contains('on');
}
function mudouVirado(v) {
  if (v === magia.virado) return;
  magia.virado = v;
  if (v && magiaPode()) {
    $('#aviso').classList.remove('on');
    // começa (ou continua) a marcar os números do bilhete que ainda faltam, em ordem sorteada
    const b = bilhete();
    const soBilhete = [...sel].every(n => b.includes(n));
    if (!soBilhete) { magia.limpar = true; magia.fila = embaralhar(b.slice()); }
    else { magia.limpar = false; magia.fila = embaralhar(b.filter(n => !sel.has(n))); }
  }
}
function embaralhar(a) { for (let i = a.length - 1; i > 0; i--) { const k = Math.floor(Math.random() * (i + 1)); [a[i], a[k]] = [a[k], a[i]]; } return a; }
function toqueMagico() {
  if (!magia.fila) return;
  if (magia.limpar) { sel.clear(); magia.limpar = false; }
  const n = magia.fila.shift();
  if (n != null) { sel.add(n); avisoMostrado = true; atualizarVolante(); }
}
document.addEventListener('touchstart', e => {
  if (magia.virado && magiaPode()) { e.preventDefault(); e.stopPropagation(); toqueMagico(); }
}, {capture: true, passive: false});
document.addEventListener('click', e => {
  if (magia.virado && magiaPode()) { e.preventDefault(); e.stopPropagation(); }
}, true);

window.addEventListener('deviceorientation', e => {
  if (e.beta == null) return;
  const b = Math.abs(e.beta);
  if (!magia.virado && b > 140) mudouVirado(true);
  else if (magia.virado && b < 115) mudouVirado(false);
});
let sensorPedido = false;
function pedirSensor() {
  if (sensorPedido) return;
  sensorPedido = true;
  try { if (window.DeviceOrientationEvent && DeviceOrientationEvent.requestPermission) DeviceOrientationEvent.requestPermission().catch(() => {}); } catch (e) {}
  try { if (window.DeviceMotionEvent && DeviceMotionEvent.requestPermission) DeviceMotionEvent.requestPermission().catch(() => {}); } catch (e) {}
}
document.addEventListener('touchend', pedirSensor, {once: true, capture: true});
// teste no computador: tecla V vira/desvira, clique conta como toque
window.addEventListener('keydown', e => { if (e.key === 'v' || e.key === 'V') mudouVirado(!magia.virado); });
document.addEventListener('mousedown', e => { if (!('ontouchstart' in window) && magia.virado && magiaPode()) { e.preventDefault(); toqueMagico(); } }, true);

/* ======================================================================
   GESTOS SECRETOS: segurar 1,5 s ou deslizar dois dedos -> ajustes
   ====================================================================== */
let gestoUsado = false, segurar = null, ini = null, dois = null;
function abrirAjustesPorGesto() {
  clearTimeout(segurar); segurar = null;
  gestoUsado = true;
  setTimeout(() => { gestoUsado = false; }, 600);
  abrirAjustes();
}
document.addEventListener('touchstart', e => {
  if ($('#ajustes').classList.contains('on') || magia.virado) return;
  if (e.touches.length === 1) {
    const t = e.touches[0];
    ini = [t.clientX, t.clientY];
    clearTimeout(segurar);
    segurar = setTimeout(abrirAjustesPorGesto, 1500);
  } else if (e.touches.length === 2) {
    clearTimeout(segurar); segurar = null;
    dois = [(e.touches[0].clientX + e.touches[1].clientX) / 2, (e.touches[0].clientY + e.touches[1].clientY) / 2];
  }
}, {capture: true, passive: true});
document.addEventListener('touchmove', e => {
  if (segurar && ini && e.touches.length === 1) {
    const t = e.touches[0];
    if (Math.hypot(t.clientX - ini[0], t.clientY - ini[1]) > 10) { clearTimeout(segurar); segurar = null; }
  }
  if (dois && e.touches.length === 2) {
    const m = [(e.touches[0].clientX + e.touches[1].clientX) / 2, (e.touches[0].clientY + e.touches[1].clientY) / 2];
    if (Math.hypot(m[0] - dois[0], m[1] - dois[1]) > 45) { dois = null; abrirAjustesPorGesto(); }
  }
}, {capture: true, passive: true});
document.addEventListener('touchend', e => {
  if (!e.touches.length) { clearTimeout(segurar); segurar = null; dois = null; }
}, {capture: true, passive: true});
// no computador: segurar o botão do mouse 1,5 s
document.addEventListener('mousedown', e => {
  if ('ontouchstart' in window || $('#ajustes').classList.contains('on')) return;
  ini = [e.clientX, e.clientY]; clearTimeout(segurar); segurar = setTimeout(abrirAjustesPorGesto, 1500);
});
document.addEventListener('mousemove', e => { if (segurar && ini && Math.hypot(e.clientX - ini[0], e.clientY - ini[1]) > 10) { clearTimeout(segurar); segurar = null; } });
document.addEventListener('mouseup', () => { clearTimeout(segurar); segurar = null; });
document.addEventListener('contextmenu', e => e.preventDefault());

/* ======================================================================
   AJUSTES
   ====================================================================== */
const ajGrade = $('#ajGrade');
ajGrade.innerHTML = Array.from({length: 60}, (_, i) => `<div data-n="${i + 1}">${p2(i + 1)}</div>`).join('');
function desenharAjustes() {
  const b = guarda.ler('bilhete', [5, 12, 23, 34, 41, 58]);
  ajGrade.querySelectorAll('div').forEach(d => d.classList.toggle('sel', b.includes(+d.dataset.n)));
  $('#ajNumsTxt').textContent = b.slice().sort((a, c) => a - c).map(p2).join(' · ') + (b.length !== 6 ? '  (' + b.length + '/6)' : '');
  $('#ajMagica').checked = guarda.ler('magica', true);
  const v = guarda.ler('virada', 'auto');
  $('#ajVirada').querySelectorAll('span').forEach(s => s.classList.toggle('sel', s.dataset.v === v));
  document.querySelectorAll('.aj-img').forEach(el => {
    const k = el.dataset.k;
    const tem = k === 'video' ? guarda.ler('temVideo', false) : !!imgInfo(k);
    el.querySelector('b').textContent = tem ? (k === 'video' ? 'Usando o seu vídeo' : 'Usando a sua imagem') : 'Padrão';
    el.querySelector('[data-a=tirar]').style.display = tem ? '' : 'none';
  });
  const q = guarda.ler('net_quando', null);
  $('#ajPremios').textContent = q ? 'Última busca: ' + new Date(q.quando).toLocaleString('pt-BR') + ' — ' + q.ok + ' de ' + q.total + ' jogos vieram da internet. Os outros usam valores com cara de verdade.' : 'Ainda não buscou na internet.';
}
function abrirAjustes() { desenharAjustes(); $('#ajustes').classList.add('on'); barra('escuro'); }
function fecharAjustes() {
  $('#ajustes').classList.remove('on');
  montarCartoes();
  if (telaAtual === 'volante' && volJogo && volJogo.virada && !viradaVisivel()) irCartoes();
  else mostrar(telaAtual);
}
$('#ajFechar').addEventListener('click', fecharAjustes);
ajGrade.addEventListener('click', e => {
  const d = e.target.closest('[data-n]'); if (!d) return;
  let b = guarda.ler('bilhete', [5, 12, 23, 34, 41, 58]);
  const n = +d.dataset.n;
  if (b.includes(n)) b = b.filter(x => x !== n);
  else if (b.length < 6) b.push(n);
  guarda.pôr('bilhete', b);
  desenharAjustes();
});
$('#ajMagica').addEventListener('change', e => guarda.pôr('magica', e.target.checked));
$('#ajVirada').addEventListener('click', e => { const s = e.target.closest('[data-v]'); if (!s) return; guarda.pôr('virada', s.dataset.v); desenharAjustes(); });
$('#ajAtualizar').addEventListener('click', async () => {
  const b = $('#ajAtualizar'); b.textContent = 'Buscando...';
  await atualizarTudo();
  b.textContent = 'Atualizar agora';
  desenharAjustes();
});
$('#ajReiniciar').addEventListener('click', () => { $('#ajustes').classList.remove('on'); abertura(); });

/* escolher imagens */
let escolhendo = null;
document.querySelectorAll('.aj-img').forEach(el => el.addEventListener('click', async e => {
  const bt = e.target.closest('button'); if (!bt) return;
  const k = el.dataset.k;
  if (k === 'video') {
    if (bt.dataset.a === 'trocar') {
      if (!NATIVO) { alert('O vídeo só funciona no app do iPhone.'); return; }
      bt.textContent = 'Abrindo...';
      const ok = await nativo('escolherVideo').catch(() => false);
      bt.textContent = 'Incluir vídeo';
      if (ok) guarda.pôr('temVideo', true);
    } else { await nativo('apagar', {nome: 'abertura.mov'}).catch(() => {}); guarda.pôr('temVideo', false); }
    desenharAjustes();
    return;
  }
  if (bt.dataset.a === 'tirar') {
    const i = imgInfo(k);
    if (i && NATIVO) await nativo('apagar', {nome: i.nome}).catch(() => {});
    try { localStorage.removeItem('lt_dados_' + k); } catch (e2) {}
    guarda.pôr('img_' + k, null);
    if (k === 'icone') await prepararIcone();
    aplicarImagens();
    desenharAjustes();
    return;
  }
  escolhendo = k;
  const inp = $('#ajArquivo'); inp.value = ''; inp.click();
}));
$('#ajArquivo').addEventListener('change', async e => {
  const f = e.target.files && e.target.files[0], k = escolhendo;
  if (!f || !k) return;
  const url = await new Promise(ok => { const r = new FileReader(); r.onload = () => ok(r.result); r.readAsDataURL(f); });
  const im = await carregarImagem(url);
  let dados, ext;
  if (k === 'printAzul' || k === 'printAbertura') { dados = cobrirBarra(im); ext = 'jpg'; }
  else { dados = reduzir(im, 600); ext = 'png'; }
  const nome = k + '.' + ext;
  let ok = false;
  if (NATIVO) ok = await nativo('salvar', {nome, dados: dados.split(',')[1]}).catch(() => false);
  else { try { localStorage.setItem('lt_dados_' + k, dados); ok = true; } catch (e2) { alert('Imagem grande demais para guardar aqui.'); } }
  if (ok) {
    guarda.pôr('img_' + k, {nome, v: Date.now()});
    if (k === 'icone') await prepararIcone();
    aplicarImagens();
  }
  desenharAjustes();
});
function reduzir(im, max) {
  const r = Math.min(1, max / Math.max(im.width, im.height));
  const c = document.createElement('canvas'); c.width = Math.round(im.width * r); c.height = Math.round(im.height * r);
  c.getContext('2d').drawImage(im, 0, 0, c.width, c.height);
  return c.toDataURL('image/png');
}
/* print: a faixa de cima (hora, Wi-Fi, bateria) é coberta com a linha logo abaixo dela, esticada */
function cobrirBarra(im) {
  const r = Math.min(1, 1290 / im.width);
  const w = Math.round(im.width * r), h = Math.round(im.height * r);
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const x = c.getContext('2d');
  x.drawImage(im, 0, 0, w, h);
  const faixa = Math.round(h * 58 / 874), linha = faixa + Math.max(2, Math.round(h * 3 / 874));
  x.drawImage(c, 0, linha, w, 2, 0, 0, w, faixa + 1);
  return c.toDataURL('image/jpeg', .9);
}
function aplicarImagens() {
  const u = imgURL('icone'), t = $('#topoIcone');
  t.innerHTML = u ? `<img src="${u}" alt="">` : trevoSVG('#ffffff', '#9fd0f0', '#9fd0f0', '#ffffff');
  prepararAzul();
  montarCartoes();
}

/* ======================================================================
   INÍCIO
   ====================================================================== */
(async function iniciar() {
  if (NATIVO) { try { guarda.pôr('temVideo', !!(await nativo('temVideo'))); } catch (e) {} }
  await prepararIcone();
  aplicarImagens();
  abertura();
  atualizarTudo().then(() => { preencherCartoes(); });
})();
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    const q = guarda.ler('net_quando', null);
    if (!q || Date.now() - q.quando > 20 * 60e3) atualizarTudo().then(() => preencherCartoes());
    if (telaAtual === 'cartoes') preencherCartoes();
  }
});
