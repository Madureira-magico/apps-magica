'use strict';
/* =====================================================================
   MOSAICO 1.1 — Fototeca falsa em que as fotos formam o rosto do famoso
   ===================================================================== */
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const DPR = Math.min(3, window.devicePixelRatio || 1);
let W = innerWidth, H = innerHeight;

/* ---------- ponte com o iPhone ---------- */
const nat = {
  tem: !!(window.webkit && webkit.messageHandlers && webkit.messageHandlers.mz),
  call(cmd, args) {
    if (!this.tem) return Promise.reject(new Error('fora do app'));
    return webkit.messageHandlers.mz.postMessage(Object.assign({ cmd }, args || {}));
  },
  msg(nome, valor) { try { webkit.messageHandlers[nome].postMessage(valor); } catch (_) {} }
};
const URLS = {
  mini: id => 'mzfoto://mini?id=' + encodeURIComponent(id),
  foto: (id, s, fit) => 'mzfoto://foto?id=' + encodeURIComponent(id) + '&s=' + s + (fit ? '&m=fit' : ''),
  arq: (n, v) => 'mzfoto://arq?n=' + encodeURIComponent(n) + (v ? '&v=' + v : '')
};
const vibrar = f => nat.call('vibrar', { forca: f || 'leve' }).catch(() => {});
function toast(t, ms) { const e = $('#toast'); e.textContent = t; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', ms || 2200); }
const esc = s => String(s).replace(/[<&>"]/g, c => ({ '<': '&lt;', '&': '&amp;', '>': '&gt;', '"': '&quot;' })[c]);

/* ---------- configurações guardadas ---------- */
const guarda = {
  get(k, p) { try { const v = localStorage.getItem('mz_' + k); return v == null ? p : JSON.parse(v); } catch (_) { return p; } },
  set(k, v) { try { localStorage.setItem('mz_' + k, JSON.stringify(v)); } catch (_) {} }
};
const cfg = Object.assign({
  abrir: 'fototeca', tema: 'auto', n0: 3, colsM: 60, cor: 'cor', reforco: 0.4, enq: 'perto', filtro: true, aviso: true,
  fotoReal: false, vibrar: true, origem: '', limite: 8000, inj: false, injId: '', wk: '', temPrint: false, zonas: {},
  piada: 'bebes', bebe: 0, bebes: [false, false, false, false], fixas: [], fixa: 0, tirados: [], abert: [], ver: 1, v: 2
}, guarda.get('cfg', {}));
if (!Array.isArray(cfg.abert)) cfg.abert = [];
const MAX_ABERT = 63;
const tokAbert = a => 'arq:abert/' + a.id + '.jpg';
const abertDe = it => (typeof it === 'string' && it.startsWith('arq:abert/')) ? cfg.abert.find(a => tokAbert(a) === it) : null;
function srcMini(it) { return it === '#piada' ? URLS.arq(arqPiada(), cfg.ver) : String(it).startsWith('arq:') ? URLS.arq(it.slice(4), cfg.ver) : URLS.mini(it); }
if ((cfg.v || 1) < 2) {   // vindo da versão 1.0
  Object.assign(cfg, { colsM: 60, cor: 'cor', reforco: 0.4, limite: 8000, tema: 'auto', enq: 'perto', filtro: true, aviso: true,
    piada: 'bebes', fixas: cfg.fixas || [], fixa: 0, tirados: cfg.tirados || [], v: 2 });
}
const salvar = () => guarda.set('cfg', cfg);
salvar();
let tirados = new Set(cfg.tirados || []);

/* ---------- lista de famosos ---------- */
const semAcento = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
const maiusculas = s => String(s).toLowerCase().split(' ').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
const slug = s => semAcento(s).replace(/ /g, '-').slice(0, 60) || 'x';
function listaPadrao() {
  return $('#dadosFamosos').textContent.split('\n').map(l => l.trim()).filter(Boolean).map(l => {
    const [n, w, a] = l.split('|');
    return { n: n.trim(), w: (w || '').trim(), a: (a || '').split(';').map(x => x.trim()).filter(Boolean), b: -1, f: '', r: null };
  });
}
let famosos = guarda.get('famosos', null);
if (!Array.isArray(famosos) || !famosos.length) famosos = listaPadrao();
const salvarFam = () => guarda.set('famosos', famosos);
function nomesDe(f) { return [f.n, (f.w || '').replace(/\s*\(.*\)$/, ''), ...(f.a || [])].map(semAcento).filter(x => x.length >= 2); }
function distancia(a, b) {
  if (Math.abs(a.length - b.length) > 2) return 9;
  const m = a.length, n = b.length, d = Array.from({ length: m + 1 }, (_, i) => [i]);
  for (let j = 1; j <= n; j++) d[0][j] = j;
  for (let i = 1; i <= m; i++) for (let j = 1; j <= n; j++)
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[m][n];
}
const limiteErro = q => q.length >= 10 ? 2 : q.length >= 5 ? 1 : 0;
/* o texto inteiro é o nome (digitado, Notas, Inject) */
function acharFamoso(txt) {
  const q = semAcento(txt); if (!q) return null;
  let melhor = null, nota = 9;
  for (const f of famosos) for (const nm of nomesDe(f)) {
    if (nm === q) return f;
    const d = distancia(nm, q);
    if (d <= limiteErro(q) && d < nota) { nota = d; melhor = f; }
  }
  return melhor;
}
/* o nome está no meio de uma frase (microfone, câmera) */
function acharFamosoEm(txt) {
  const q = semAcento(txt); if (!q) return null;
  const pal = q.split(' '), cheio = ' ' + q + ' ';
  let melhor = null, tam = 0;
  for (const f of famosos) for (const nm of nomesDe(f)) {
    if (nm.length < 3) continue;
    let ok = cheio.includes(' ' + nm + ' ');
    if (!ok && nm.length >= 5) {
      const k = nm.split(' ').length;
      for (let i = 0; i + k <= pal.length && !ok; i++) ok = distancia(pal.slice(i, i + k).join(' '), nm) <= limiteErro(nm);
    }
    if (ok && nm.length > tam) { tam = nm.length; melhor = f; }
  }
  return melhor;
}

/* =====================================================================
   FOTOS: lista da galeria, cores médias, sequência mostrada
   ===================================================================== */
let base = [];          // ids da galeria (antiga -> recente)
let cores = new Map();  // id -> {c:[r,g,b], ok:1|0}
let seq = [], seqNormal = [];
let analisando = false;
const lum = c => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

async function carregarFotos() {
  let st;
  try { st = await nat.call('permissao'); } catch (_) { st = 'fora'; }
  if (st === 'negado') toast('Libere o acesso às fotos em Ajustes do iPhone › Mosaico › Fotos', 6000);
  try { base = await nat.call('fotos', { album: cfg.origem || '' }); } catch (_) { base = base || []; }
  montarSeq();
  analisarFotos();
}
async function analisarFotos() {
  if (analisando) return;
  analisando = true;
  const lim = Math.max(500, +cfg.limite || 8000);
  const alvo = base.slice(-lim).reverse();   // das mais recentes para as mais antigas
  for (let i = 0; i < alvo.length; i += 120) {
    const lote = alvo.slice(i, i + 120);
    try {
      const res = await nat.call('analisar', { ids: lote });
      lote.forEach((id, k) => { const c = res[k]; if (c) cores.set(id, { c: [c[0], c[1], c[2]], ok: c.length > 3 ? c[3] : 1 }); });
    } catch (_) { break; }
    mostrarAnalise(Math.min(alvo.length, i + 120), alvo.length);
    if (i % 1200 === 0) pedirDesenho();
  }
  analisando = false;
  mostrarAnalise(alvo.length, alvo.length);
  if (atual && atual.pronto) prepararMosaico();
}
function mostrarAnalise(f, t) {
  const e = $('#aAnalise'); if (!e) return;
  let boas = 0; for (const v of cores.values()) if (v.ok) boas++;
  e.textContent = f < t ? 'Preparando ' + f + ' de ' + t + '…' : cores.size + ' fotos prontas (' + boas + ' de pessoas e paisagens)';
}

/* foto da piada (bebê ou foto fixa) */
function arqPiada() {
  if (cfg.piada === 'fixa') { const f = cfg.fixas[cfg.fixa]; return f ? 'piada/' + f.id + '.jpg' : ''; }
  return cfg.bebes[cfg.bebe] ? 'bebes/' + cfg.bebe + '.jpg' : '';
}
function fixosNoFim() { const n = +cfg.n0 || 3, t = W / n; return n * (Math.ceil(H / t) + 1); }
function indiceBebe(total) {
  const n = +cfg.n0 || 3, t = W / n, pb = sbPx() + 70;
  const k = Math.max(0, Math.round((H / 2 - pb) / t - 0.5));
  const ultima = Math.floor((total - 1) / n), linha = Math.max(0, ultima - k);
  return Math.min(total - 1, linha * n + Math.floor(n / 2));
}
function montarSeq() {
  const s = tirados.size ? base.filter(id => !tirados.has(id)) : base.slice();
  for (const a of cfg.abert) s.push(tokAbert(a));   // fotos do começo: sempre as mesmas, guardadas no app
  if (arqPiada()) s.splice(indiceBebe(s.length + 1), 0, '#piada');
  seqNormal = s;
  seq = (mos && mos.seq) ? mos.seq : seqNormal;
  $('#contagem').textContent = s.length + ' Itens';
  pedirDesenho(); enviarGaleria();
}

/* =====================================================================
   ALVO: rosto do famoso (ou o nome escrito) e montagem do mosaico
   ===================================================================== */
let atual = guarda.get('atual', null);   // {nome, tipo:'rosto'|'texto', arq, pronto}
let mos = null;
let preparo = 0;
if (atual) atual.pronto = false;

function estado(t, cls) { const e = $('#aEstado'); if (e) { e.textContent = t; e.className = 'r ' + (cls || ''); } }
function mostrarAtual() {
  const e = $('#aAtual'); if (e) e.textContent = atual ? atual.nome + (atual.tipo === 'texto' ? ' (nome escrito)' : '') : '—';
  $('#ponto').classList.toggle('on', !!(cfg.aviso && atual && atual.pronto && mos));
}

async function definirNome(txt, origem) {
  txt = String(txt || '').replace(/\s+/g, ' ').trim();
  if (txt.length < 2 || txt.length > 60) return;
  const meu = ++preparo;
  const f = acharFamoso(txt);
  const nome = f ? f.n : maiusculas(txt);
  if (cfg.piada === 'bebes' && f && f.b >= 0 && cfg.bebes[f.b] && cfg.bebe !== f.b) { cfg.bebe = f.b; salvar(); montarSeq(); }
  atual = { nome, tipo: 'texto', pronto: false, origem };
  pontos(1, false);
  mostrarAtual(); estado('preparando…');
  await prepararMosaico();             // 1) já fica pronto com o nome escrito
  if (meu !== preparo) return;
  let fam = f;
  if (fam && fam.f) {
    let existe = false;
    try { existe = await nat.call('existe', { nome: fam.f }); } catch (_) {}
    if (!existe) fam.f = '';
  }
  if (!fam || !fam.f) {
    estado('procurando foto…');
    fam = await baixarFamoso(fam || { n: nome, w: '', a: [], b: -1, f: '', r: null }, !fam);
    if (meu !== preparo) return;
  }
  if (fam && fam.f) {                   // 2) troca pelo rosto
    pontos(2, true);
    atual = { nome: fam.n, tipo: 'rosto', arq: fam.f, pronto: false, origem };
    await prepararMosaico();
  }
  if (meu !== preparo) return;
  guarda.set('atual', atual);
  pontos(3, atual.tipo === 'rosto');
  mostrarAtual();
  estado(atual.tipo === 'rosto' ? 'pronto ✓' : 'pronto (sem foto: nome escrito)', 'ok');
  if (cfg.vibrar) vibrar('leve');
}

async function infoWiki(lang, titulo, busca) {
  const u = 'https://' + lang + '.wikipedia.org/w/api.php?action=query&format=json&origin=*&redirects=1&prop=pageimages&piprop=thumbnail&pithumbsize=1400&pilicense=any&'
    + (titulo ? 'titles=' + encodeURIComponent(titulo) : 'generator=search&gsrlimit=1&gsrsearch=' + encodeURIComponent(busca));
  const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 9000);
  try {
    const r = await fetch(u, { signal: ac.signal, cache: 'no-store' }); const d = await r.json();
    const pags = d && d.query && d.query.pages ? Object.values(d.query.pages) : [];
    const p = pags.find(x => x.thumbnail && x.thumbnail.source);
    return p ? p.thumbnail.source : '';
  } catch (_) { return ''; } finally { clearTimeout(t); }
}
async function baixarFamoso(f, novo) {
  const tentativas = [];
  if (f.w) tentativas.push(['pt', f.w, '']);
  tentativas.push(['pt', '', f.n], ['en', f.w && !/\(/.test(f.w) ? f.w : '', f.n]);
  let feito = null;
  for (const [lang, tit, busca] of tentativas) {
    const url = await infoWiki(lang, tit, busca);
    if (!url) continue;
    const nome = 'famosos/' + slug(f.n) + '.jpg';
    try {
      const r = await nat.call('baixarRosto', { url, nome });
      feito = { arq: nome, rosto: !!(r && r.rosto) };
      if (feito.rosto) break;
    } catch (_) {}
  }
  if (!feito) { f.r = false; salvarFam(); return null; }
  f.f = feito.arq; f.r = feito.rosto;
  if (novo && !famosos.includes(f)) famosos.push(f);
  salvarFam(); desenharListaFam();
  return f;
}

/* desenha o nome em letras e devolve a grade de cores */
function gradeTexto(nome, cols, rows) {
  const k = 8, c = document.createElement('canvas'); c.width = cols * k; c.height = rows * k;
  const g = c.getContext('2d'); g.fillStyle = '#000'; g.fillRect(0, 0, c.width, c.height);
  const linhas = []; let lin = '';
  for (const p of nome.toUpperCase().split(' ')) { const t = lin ? lin + ' ' + p : p; if (lin && t.length > 7) { linhas.push(lin); lin = p; } else lin = t; }
  if (lin) linhas.push(lin);
  const largura = c.width * 0.88, alturaMax = c.height * 0.5 / linhas.length;
  let fs = alturaMax;
  g.font = '900 ' + fs + 'px -apple-system, Helvetica, Arial, sans-serif';
  for (const l of linhas) { const w = g.measureText(l).width; if (w > largura) fs = Math.min(fs, alturaMax * largura / w); }
  g.font = '900 ' + fs + 'px -apple-system, Helvetica, Arial, sans-serif';
  g.fillStyle = '#fff'; g.textAlign = 'center'; g.textBaseline = 'middle';
  const total = linhas.length * fs * 1.12, y0 = c.height * 0.47 - total / 2 + fs * 0.56;
  linhas.forEach((l, i) => g.fillText(l, c.width / 2, y0 + i * fs * 1.12));
  const px = g.getImageData(0, 0, c.width, c.height).data, out = [];
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    let s = 0;
    for (let dy = 0; dy < k; dy++) for (let dx = 0; dx < k; dx++) s += px[((y * k + dy) * c.width + x * k + dx) * 4];
    const v = Math.round(s / (k * k)); out.push(v, v, v);
  }
  return out;
}

/* fotos disponíveis para o mosaico */
function pool() {
  const todas = [], boas = [];
  for (const [id, v] of cores) { if (tirados.has(id)) continue; const p = { id, c: v.c, l: lum(v.c) }; todas.push(p); if (v.ok) boas.push(p); }
  return cfg.filtro && boas.length >= 300 ? boas : todas;
}
/* para cada cor (8x8x8 caixinhas), as fotos de cor mais parecida */
function indiceCores(P) {
  const tab = new Array(512);
  return (r, g, b) => {
    const k = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
    if (!tab[k]) {
      const cr = (r >> 5) * 32 + 16, cg = (g >> 5) * 32 + 16, cb = (b >> 5) * 32 + 16;
      const m = [];
      for (const p of P) {
        const d = 2 * (p.c[0] - cr) ** 2 + 4 * (p.c[1] - cg) ** 2 + 3 * (p.c[2] - cb) ** 2;
        if (m.length < 14) { m.push([d, p.id]); m.sort((a, z) => a[0] - z[0]); }
        else if (d < m[13][0]) { m[13] = [d, p.id]; m.sort((a, z) => a[0] - z[0]); }
      }
      tab[k] = m.map(x => x[1]);
    }
    return tab[k];
  };
}

async function prepararMosaico() {
  if (!atual) return;
  const meu = ++prepararMosaico.vez;
  const n = +cfg.colsM || 60, t = W / n;
  const rowsVis = Math.ceil(H / t) + 1;
  let sN = seqNormal.slice();
  if (sN.length < rowsVis * n) sN = new Array(rowsVis * n - sN.length).fill('').concat(sN);   // galeria pequena: repete fotos
  if (sN.length % n) sN = new Array(n - sN.length % n).fill('').concat(sN);   // última linha sempre cheia
  const N = sN.length;
  if (!N) return;
  const ultima = Math.floor((N - 1) / n), primeira = Math.max(0, ultima - rowsVis + 1), linhas = ultima - primeira + 1;
  const rg = Math.ceil(H / t);
  let alvo = [];
  if (atual.tipo === 'rosto' && atual.arq) { try { alvo = await nat.call('grade', { nome: atual.arq, cols: n, rows: rg, enq: cfg.enq, real: 'real.jpg' }); } catch (_) { alvo = []; } }
  if (!alvo || alvo.length < n * rg * 3) { if (atual.tipo === 'rosto') atual.tipo = 'texto'; alvo = gradeTexto(atual.nome, n, rg); }
  if (meu !== prepararMosaico.vez) return;
  const texto = atual.tipo === 'texto';
  const L = []; for (let i = 0; i < n * rg; i++) L.push(lum([alvo[i * 3], alvo[i * 3 + 1], alvo[i * 3 + 2]]));
  const ord = L.slice().sort((a, b) => a - b), p2 = ord[Math.floor(ord.length * 0.02)], p98 = ord[Math.floor(ord.length * 0.98)] || 255;
  const V = L.map(l => { let v = (l - p2) / Math.max(1, p98 - p2); v = Math.min(1, Math.max(0, v)); return texto ? v : v * v * (3 - 2 * v); });
  const P = pool(); const NP = P.length;
  const porLuz = P.slice().sort((a, b) => a.l - b.l);
  const porCor = (!texto && cfg.cor === 'cor' && NP) ? indiceCores(P) : null;
  // faixa da esquerda (3 colunas): as MESMAS fotos, no mesmo lugar, da Fototeca normal que o público já viu
  const k0 = +cfg.n0 || 3, M = seqNormal.length, uN = Math.floor((M - 1) / k0);
  const cS = Math.floor((n - k0) / 2);   // no meio, para sumir dentro do rosto
  const fL = Math.ceil(H / (W / k0)) * 3;   // só as últimas ~3 telas (o que o público viu); acima disso, fotos do mosaico
  const faixa = (r, c) => { const j = (uN - (ultima - r)) * k0 + (c - cS); return j >= 0 && j < M ? seqNormal[j] : ''; };
  const nova = sN.slice(), ids = [], tinta = [];
  const cima = stPx() + 96, topo = Math.max(0, cima + (ultima + 1) * t - H);
  const janela = texto ? Math.max(2, Math.round(NP * 0.3)) : Math.max(2, Math.round(NP * 0.015));
  for (let r = primeira; r <= ultima; r++) {
    const yc = cima + r * t - topo + t / 2, gy = Math.min(rg - 1, Math.max(0, Math.floor(yc / H * rg)));
    for (let c = 0; c < n; c++) {
      const idx = r * n + c, cel = gy * n + c, v = V[cel] == null ? 0 : V[cel];
      const l0 = Math.max(1, L[cel] || 1), kk = (v * 255) / l0;   // cor do rosto com a claridade esticada
      const cr = Math.min(255, Math.round((alvo[cel * 3] || 0) * kk)), cgc = Math.min(255, Math.round((alvo[cel * 3 + 1] || 0) * kk)), cb = Math.min(255, Math.round((alvo[cel * 3 + 2] || 0) * kk));
      let id = '';
      if (idx < N) {
        if (c >= cS && c < cS + k0 && r > ultima - fL) { id = faixa(r, c); nova[idx] = id; }
        else if (!NP) id = sN[idx];
        else {
          const esq = c > 0 ? nova[idx - 1] : '', cimaId = idx - n >= 0 ? nova[idx - n] : '';
          if (porCor) {
            const cand = porCor(cr, cgc, cb);
            for (let k = 0; k < 8; k++) { id = cand[Math.floor(Math.random() * Math.min(6, cand.length))]; if (id !== esq && id !== cimaId) break; }
          } else {
            const alvoI = Math.round(v * (NP - 1));
            for (let k = 0; k < 8; k++) {
              const j = Math.min(NP - 1, Math.max(0, alvoI + Math.round((Math.random() * 2 - 1) * janela)));
              id = porLuz[j].id; if (id !== esq && id !== cimaId) break;
            }
          }
          nova[idx] = id;
        }
      }
      ids.push(id === '#piada' ? (arqPiada() ? 'arq:' + arqPiada() : '') : id);
      if (porCor) tinta.push(cr, cgc, cb); else { const g = Math.round(v * 255); tinta.push(g, g, g); }
    }
  }
  const px = Math.max(8, Math.min(64, Math.round(t * DPR)));
  const versao = Date.now();
  try {
    const ok = await nat.call('compor', { ids, cols: n, rows: linhas, px, modo: 'cor', alvo: tinta, alfa: +cfg.reforco, saida: 'mosaico.jpg' });
    if (!ok) throw new Error('não montou');
  } catch (e) { if (meu === prepararMosaico.vez) estado('erro ao montar: ' + (e.message || e), 'erro'); return; }
  if (meu !== prepararMosaico.vez) return;
  const img = new Image();
  await new Promise(ok => { img.onload = ok; img.onerror = ok; img.src = URLS.arq('mosaico.jpg', versao); });
  if (meu !== prepararMosaico.vez) return;
  mos = { seq: nova, img, primeira, linhas, cols: n, versao, N, ids, tinta, px, ultima, ini: primeira * n, tintaIdx: tinta, cS, k0, uN, fL, normal: seqNormal.slice() };
  seq = nova;
  atual.pronto = true;
  $('#real').style.backgroundImage = atual.tipo === 'rosto' ? 'url("' + URLS.arq('real.jpg', versao) + '")' : '';
  mostrarAtual();
  pedirDesenho(); enviarGaleria();
}
prepararMosaico.vez = 0;

function limparNome() {
  preparo++; prepararMosaico.vez++;
  atual = null; mos = null; guarda.set('atual', null); pontos(0); seq = seqNormal; $('#real').classList.remove('on');
  if (zoom > 5) irAoNivel(5);
  mostrarAtual(); estado(''); pedirDesenho(); enviarGaleria();
}

/* =====================================================================
   FOTOTECA: grade no canvas, rolar, pinça, toque — como o app Fotos
   Níveis fixos (3, 5, 13 colunas). Durante a pinça a grade cresce/encolhe com os dedos
   e, entre um nível e outro, as duas grades se dissolvem, sempre presas na foto embaixo dos dedos.
   Com o mosaico pronto, depois de 13 colunas entra o rosto ampliado (até o rosto inteiro).
   ===================================================================== */
const cv = $('#cv'), ctx = cv.getContext('2d');
let zoom = +cfg.n0 || 3;        // colunas "contínuas"
let doFim = 0;                  // rolagem da grade parada, a partir do fim (px)
let anc = null;                 // durante a pinça: {i, fx, fy, mx, my} = foto presa embaixo dos dedos
let ox = 0, oy = 0;             // posição do mosaico ampliado
let corFundo = '#000';
let animZoom = 0;
const ZM0 = 13, ZM1 = 16.5;     // galeria 13 -> rosto ampliado
const niveis = () => mos && mos.img ? [3, 5, 13] : [3, 5, 13, 30];
function sbPx() { return +document.documentElement.dataset.sb || 34; }
function stPx() { return +document.documentElement.dataset.st || 47; }
const cimaPx = () => stPx() + 96;
const padNivel = n => n <= 5 ? sbPx() + 70 : 0;
function zMax() { return mos ? mos.cols : (+cfg.colsM || 60); }
const temMag = () => !!(mos && mos.img);
const suave = (a, b, x) => { const u = Math.min(1, Math.max(0, (x - a) / (b - a))); return u * u * (3 - 2 * u); };
const mistura = () => temMag() ? suave(ZM0, ZM1, zoom) : 0;   // 0 = galeria, 1 = rosto ampliado
const emMag = () => mistura() >= 1;
const kAtual = () => mos ? mos.cols / zoom : 1;
/* nível de repouso (o mais perto do zoom) */
function nivelPerto(z) { const L = niveis(); let m = L[0]; for (const v of L) if (Math.abs(Math.log(v / z)) < Math.abs(Math.log(m / z))) m = v; return m; }
function nivelBase() { const L = niveis(); if (zoom <= L[0]) return L[0]; if (zoom >= L[L.length - 1]) return L[L.length - 1]; return nivelPerto(zoom); }

/* posição da grade de n colunas no zoom atual */
function layoutNivel(n) {
  const t = W / zoom, cima = cimaPx(), alt = cima + Math.ceil(seq.length / n) * t + padNivel(n);
  let x0 = 0, topo;
  if (anc && anc.i >= 0) {
    const r = Math.floor(anc.i / n), c = anc.i % n;
    x0 = anc.mx - (c + anc.fx) * t;
    if (n * t >= W) x0 = Math.min(0, Math.max(W - n * t, x0)); else x0 = Math.max(0, Math.min(W - n * t, x0));
    topo = cima + (r + anc.fy) * t - anc.my;
  } else topo = alt - H - doFim;
  topo = Math.max(0, Math.min(Math.max(0, alt - H), topo));
  return { n, t, x0, topo, alt };
}
function pontoNaGrade(L, x, y) {
  const cc = (x - L.x0) / L.t, rr = (y + L.topo - cimaPx()) / L.t, r = Math.floor(rr), c = Math.floor(cc);
  return { i: r < 0 || c < 0 || c >= L.n ? -1 : r * L.n + c, fx: cc - c, fy: rr - r };
}
function geoMos() { const C = mos.cols, t0 = W / C, cima = cimaPx(); return { C, t0, cima, topo0: Math.max(0, cima + (mos.ultima + 1) * t0 - H) }; }
function pontoMag(x, y) {
  const g = geoMos(), k = kAtual();
  const cc = ((x - ox) / k) / g.t0, rr = (((y - oy) / k) - g.cima + g.topo0) / g.t0, r = Math.floor(rr), c = Math.floor(cc);
  return { i: c < 0 || c >= g.C || r < 0 ? -1 : r * g.C + c, fx: cc - c, fy: rr - r };
}
function prenderMag() {
  const k = kAtual();
  if (k >= 1) { ox = Math.min(0, Math.max(W - W * k, ox)); oy = Math.min(0, Math.max(H - H * k, oy)); }
  else { ox = (W - W * k) / 2; oy = (H - H * k) / 2; }   // menor que a tela: fica no meio (efeito elástico)
}
function magNaFoto(i, fx, fy, x, y) {
  const g = geoMos(), k = kAtual(), r = Math.floor(i / g.C), c = i % g.C;
  if (i < 0 || r < mos.primeira || r > mos.ultima) { ox = (W - W * k) / 2; oy = H - H * k; prenderMag(); return; }
  ox = x - (c + fx) * g.t0 * k; oy = y - (g.cima + (r + fy) * g.t0 - g.topo0) * k; prenderMag();
}
/* a foto que está num ponto da tela agora */
function pontoAgora(x, y) { return mistura() >= 0.5 ? pontoMag(x, y) : pontoNaGrade(layoutNivel(nivelBase()), x, y); }
/* retângulo de uma foto na tela (para a animação de abrir/fechar) */
function rectDoItem(i) {
  let x, y, s;
  if (mistura() >= 0.5) {
    const g = geoMos(), k = kAtual(), r = Math.floor(i / g.C), c = i % g.C;
    if (r < mos.primeira || r > mos.ultima) return null;
    s = g.t0 * k; x = c * s + ox; y = (g.cima + r * g.t0 - g.topo0) * k + oy;
  } else {
    const L = layoutNivel(nivelBase()), r = Math.floor(i / L.n), c = i % L.n;
    s = L.t; x = L.x0 + c * s; y = cimaPx() + r * s - L.topo;
  }
  if (y + s < 0 || y > H || x + s < 0 || x > W) return null;
  return { x, y, w: s, h: s };
}
function garantirVisivel(i) {   // grade parada: rola até a foto aparecer
  if (mistura() >= 0.5 || anc) return;
  const n = nivelBase(), L = layoutNivel(n), y = cimaPx() + Math.floor(i / n) * L.t - L.topo;
  if (y >= cimaPx() - 20 && y + L.t <= H - padNivel(n)) return;
  const topo = cimaPx() + Math.floor(i / n) * L.t - H / 2 + L.t / 2;
  doFim = Math.max(0, Math.min(Math.max(0, L.alt - H), L.alt - H - topo));
}
function irAoNivel(n) { cancelAnimationFrame(animZoom); anc = null; zoom = n; doFim = 0; pedirDesenho(); if (nativo) nat.call('galeriaNivel', { n }).catch(() => {}); }

function ajustarTamanho() {
  W = innerWidth; H = innerHeight;
  cv.width = Math.round(W * DPR); cv.height = Math.round(H * DPR);
  const d = document.createElement('div'); d.style.cssText = 'position:fixed;top:0;height:var(--st);width:1px;visibility:hidden'; document.body.appendChild(d);
  const st = d.getBoundingClientRect().height; d.style.height = 'var(--sb)'; const sb = d.getBoundingClientRect().height; d.remove();
  document.documentElement.dataset.st = st || 47; document.documentElement.dataset.sb = sb || 34;
  pedirDesenho();
}

/* cache de imagens (sem vai-e-vem) */
const IMG = new Map(); const fila = []; let ativos = 0, relogio = 0;
function pegar(chave, url) {
  let e = IMG.get(chave);
  if (!e) { e = { img: null, ok: false, t: 0, url, chave, naFila: false, carregando: false, erro: false }; IMG.set(chave, e); }
  e.t = ++relogio;
  if (e.ok) return e.img;
  if (!e.naFila && !e.carregando && !e.erro) { e.naFila = true; fila.push(e); agendarBomba(); }
  return null;
}
let bombaPedida = false;
function agendarBomba() { if (!bombaPedida) { bombaPedida = true; setTimeout(() => { bombaPedida = false; bomba(); }, 0); } }
function bomba() {
  if (fila.length > 1500) { const fora = fila.splice(0, fila.length - 1500); fora.forEach(e => { e.naFila = false; }); }
  while (ativos < 16 && fila.length) {
    const e = fila.pop(); e.naFila = false;
    if (e.t < relogio - 30000) continue;
    e.carregando = true; ativos++;
    const im = new Image();
    im.onload = () => { e.img = im; e.ok = true; e.carregando = false; ativos--; pedirDesenho(); bomba(); };
    im.onerror = () => { e.erro = true; e.carregando = false; ativos--; bomba(); };
    im.src = e.url;
  }
  if (IMG.size > 14000) {
    const v = [...IMG.values()].filter(e => !e.carregando && !e.naFila).sort((a, b) => a.t - b.t).slice(0, 3000);
    v.forEach(e => IMG.delete(e.chave));
  }
}
function imagemDoItem(it, pxTela) {
  if (!it) return null;
  if (it === '#piada') { const a = arqPiada(); return a ? pegar(a + '|' + cfg.ver, URLS.arq(a, cfg.ver)) : null; }
  if (it.startsWith('arq:')) return pegar(it + '|' + cfg.ver, URLS.arq(it.slice(4), cfg.ver));
  if (pxTela > 90) {
    const s = pxTela > 260 ? Math.round(pxTela * 1.05 / 40) * 40 : 256;
    const g = pegar(it + '|' + s, URLS.foto(it, s));
    if (g) return g;
  }
  return pegar(it + '|m', URLS.mini(it));
}
function corMedia(it) { const v = cores.get(it); return v ? 'rgb(' + v.c[0] + ',' + v.c[1] + ',' + v.c[2] + ')' : 'rgba(128,128,128,.16)'; }
function espaco(z) { return z <= 3.2 ? 2 : z <= 5.5 ? 1.5 : z <= 15 ? 1 : 0.6; }
/* quanto o retoque de cor já entrou na galeria (0 = fotos normais, 1 = cor do rosto) */
function rampa() { if (!mos) return 0; return Math.min(1, Math.max(0, (zoom - 5) / (ZM0 - 5))); }

let desenhoPedido = false;
function pedirDesenho() { if (!desenhoPedido) { desenhoPedido = true; requestAnimationFrame(desenhar); } }
function desenhar() {
  desenhoPedido = false;
  if (nativo || !$('#fototeca').classList.contains('on')) return;
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  ctx.globalAlpha = 1; ctx.fillStyle = corFundo; ctx.fillRect(0, 0, W, H);
  const b = mistura();
  if (b < 1) {
    const L = niveis(), z = Math.min(zoom, ZM0);
    if (z <= L[0] || z >= L[L.length - 1]) desenharNivel(z <= L[0] ? L[0] : L[L.length - 1], 1);
    else {
      let a = L[0], c = L[1];
      for (let k = 0; k < L.length - 1; k++) if (z >= L[k] && z <= L[k + 1]) { a = L[k]; c = L[k + 1]; }
      const u = Math.log(z / a) / Math.log(c / a), ab = suave(0.2, 0.8, u);
      if (ab < 1) desenharNivel(a, 1);
      if (ab > 0) desenharNivel(c, ab);
    }
  }
  if (b > 0) { ctx.globalAlpha = b; ctx.fillStyle = corFundo; ctx.fillRect(0, 0, W, H); desenharMag(b); }
  ctx.globalAlpha = 1;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  let f = '';   // sépia / preto e branco entrando aos poucos
  if (mos && cfg.cor !== 'cor') { const a = rampa(); if (a > 0.01) f = cfg.cor === 'sepia' ? 'sepia(' + (0.9 * a).toFixed(2) + ')' : 'grayscale(' + a.toFixed(2) + ')'; }
  if (cv.style.filter !== f) cv.style.filter = f;
}

function desenharNivel(n, alfa) {
  const L = layoutNivel(n), t = L.t, g = espaco(zoom), sel = emSelecao, cima = cimaPx();
  const r0 = Math.max(0, Math.floor((L.topo - cima) / t)), r1 = Math.min(Math.ceil(seq.length / n) - 1, Math.floor((H + L.topo - cima) / t));
  const pxTela = t * DPR, lado = t - g;
  const a = mos && mos.seq === seq ? (+cfg.reforco) * Math.pow(rampa(), 1.2) : 0;
  for (let r = r0; r <= r1; r++) {
    const y = cima + r * t - L.topo;
    for (let c = 0; c < n; c++) {
      const i = r * n + c; if (i >= seq.length) break;
      const x = L.x0 + c * t, it = seq[i];
      if (!it || x > W || x + t < 0) continue;
      ctx.globalAlpha = alfa;
      const im = imagemDoItem(it, pxTela);
      if (im && im.naturalWidth) { const w = im.naturalWidth, h = im.naturalHeight, m = Math.min(w, h); ctx.drawImage(im, (w - m) / 2, (h - m) / 2, m, m, x, y, lado, lado); }
      else { ctx.fillStyle = corMedia(it); ctx.fillRect(x, y, lado, lado); }
      if (a > 0.01) {   // cada fotinha leva a cor do pedaço do rosto onde ela fica no mosaico
        const k = (i - mos.ini) * 3;
        if (k >= 0 && k < mos.tintaIdx.length) { ctx.globalAlpha = alfa * a; ctx.fillStyle = 'rgb(' + mos.tintaIdx[k] + ',' + mos.tintaIdx[k + 1] + ',' + mos.tintaIdx[k + 2] + ')'; ctx.fillRect(x, y, lado, lado); }
      }
      if (sel && selecionados.has(i)) { ctx.globalAlpha = 1; desenharMarca(x, y, lado, lado); }
    }
  }
  ctx.globalAlpha = 1;
}
function desenharMag(alfa) {
  const { C, t0, cima, topo0 } = geoMos(), k = kAtual();
  const yR = r => cima + r * t0 - topo0;
  const X = x => x * k + ox, Y = y => y * k + oy;
  const g = espaco(zoom) * Math.min(1, k);
  ctx.globalAlpha = alfa;
  if (k <= 1.5 && mos.img.naturalWidth) {
    ctx.imageSmoothingEnabled = true;
    const y0 = Y(yR(mos.primeira)), alt = mos.linhas * t0 * k;
    ctx.drawImage(mos.img, X(0), y0, W * k, alt);
    if (g > 0.3) {
      ctx.fillStyle = corFundo;
      for (let c = 1; c < C; c++) ctx.fillRect(X(c * t0) - g, y0, g, alt);
      for (let r = 1; r <= mos.linhas; r++) ctx.fillRect(X(0), Y(yR(mos.primeira + r)) - g, W * k, g);
    }
    return;
  }
  const a = +cfg.reforco, lado = t0 * k - g, pxTela = t0 * k * DPR;
  const c0 = Math.max(0, Math.floor((-ox / k) / t0)), c1 = Math.min(C - 1, Math.floor(((W - ox) / k) / t0));
  const r0 = Math.max(mos.primeira, Math.floor(((-oy / k) - cima + topo0) / t0)), r1 = Math.min(mos.ultima, Math.floor((((H - oy) / k) - cima + topo0) / t0));
  for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) {
    const cel = (r - mos.primeira) * C + c, id = mos.ids[cel];
    if (!id) continue;
    const x = X(c * t0), y = Y(yR(r));
    ctx.globalAlpha = alfa;
    const im = imagemDoItem(id, pxTela);
    if (im && im.naturalWidth) { const w = im.naturalWidth, h = im.naturalHeight, m = Math.min(w, h); ctx.drawImage(im, (w - m) / 2, (h - m) / 2, m, m, x, y, lado, lado); }
    else { ctx.fillStyle = corMedia(id); ctx.fillRect(x, y, lado, lado); }
    if (a > 0.01) { ctx.globalAlpha = alfa * a; ctx.fillStyle = 'rgb(' + mos.tinta[cel * 3] + ',' + mos.tinta[cel * 3 + 1] + ',' + mos.tinta[cel * 3 + 2] + ')'; ctx.fillRect(x, y, lado, lado); }
  }
}
function desenharMarca(x, y, w, h) {
  ctx.fillStyle = 'rgba(255,255,255,.25)'; ctx.fillRect(x, y, w, h);
  const r = Math.min(12, w / 5), cx = x + w - r - 5, cy = y + h - r - 5;
  ctx.beginPath(); ctx.arc(cx, cy, r, 0, 7); ctx.fillStyle = '#0a84ff'; ctx.fill(); ctx.lineWidth = 2; ctx.strokeStyle = '#fff'; ctx.stroke();
  ctx.beginPath(); ctx.moveTo(cx - r * .45, cy); ctx.lineTo(cx - r * .1, cy + r * .38); ctx.lineTo(cx + r * .48, cy - r * .35); ctx.stroke();
}

/* zoom preso na foto anc (embaixo dos dedos) */
function aplicarZoom(z) {
  const L = niveis();
  zoom = Math.min(temMag() ? zMax() * 1.35 : L[L.length - 1] * 1.15, Math.max(L[0] * 0.8, z));
  if (temMag() && zoom > ZM0) {
    if (anc) magNaFoto(anc.i, anc.fx, anc.fy, anc.mx, anc.my); else prenderMag();
    if (emSelecao) sairSelecao();
  }
}
function prenderDedos(mx, my) {   // guarda a foto que está embaixo dos dedos agora
  const p = pontoAgora(mx, my);
  anc = { i: p.i, fx: p.fx, fy: p.fy, mx, my };
}
function soltarAncora() {   // grade parada: converte a posição para a rolagem normal
  if (!anc) return;
  if (mistura() < 1) { const n = nivelBase(), z0 = zoom; zoom = n; const L = layoutNivel(n); doFim = Math.max(0, L.alt - H - L.topo); zoom = z0; }
  anc = null;
}
const toques = { modo: '', y0: 0, x0: 0, f0: 0, t0: 0, d0: 0, z0: 0, vel: 0, ultY: 0, ultT: 0, moveu: 0, inercia: 0 };
function dist(a, b) { return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY); }
function pararAnimacao() { if (animZoom) { cancelAnimationFrame(animZoom); animZoom = 0; } if (fimAnim) { const f = fimAnim; fimAnim = null; f(); } }
let fimAnim = null;
cv.addEventListener('touchstart', e => {
  e.preventDefault(); cancelAnimationFrame(toques.inercia); toques.inercia = 0;
  if (e.touches.length >= 2) {
    pararAnimacao();
    const mx = (e.touches[0].clientX + e.touches[1].clientX) / 2, my = (e.touches[0].clientY + e.touches[1].clientY) / 2;
    prenderDedos(mx, my);
    toques.modo = 'pinca'; toques.d0 = dist(e.touches[0], e.touches[1]); toques.z0 = zoom;
  } else if (e.touches.length === 1 && toques.modo !== 'pinca') {
    pararAnimacao();
    const p = e.touches[0];
    toques.modo = 'toque'; toques.x0 = p.clientX; toques.y0 = p.clientY; toques.f0 = doFim; toques.t0 = performance.now(); toques.ox0 = ox; toques.oy0 = oy;
    toques.ultY = p.clientY; toques.ultT = toques.t0; toques.vel = 0; toques.moveu = 0;
  }
}, { passive: false });
cv.addEventListener('touchmove', e => {
  e.preventDefault();
  if (toques.modo === 'pinca' && e.touches.length >= 2) {
    const d = dist(e.touches[0], e.touches[1]); if (!d || !toques.d0) return;
    anc.mx = (e.touches[0].clientX + e.touches[1].clientX) / 2; anc.my = (e.touches[0].clientY + e.touches[1].clientY) / 2;
    aplicarZoom(toques.z0 * toques.d0 / d);
    pedirDesenho();
  } else if ((toques.modo === 'toque' || toques.modo === 'rolar') && e.touches.length === 1) {
    const p = e.touches[0], dy = p.clientY - toques.y0;
    toques.moveu = Math.max(toques.moveu, Math.abs(dy), Math.abs(p.clientX - toques.x0));
    if (toques.moveu > 8) toques.modo = 'rolar';
    if (toques.modo === 'rolar' && emMag()) {   // ampliado: arrasta o rosto com um dedo
      ox = toques.ox0 + (p.clientX - toques.x0); oy = toques.oy0 + dy; prenderMag(); pedirDesenho();
    } else if (toques.modo === 'rolar') {
      const agora = performance.now(), dt = Math.max(1, agora - toques.ultT);
      toques.vel = 0.8 * toques.vel + 0.2 * ((p.clientY - toques.ultY) / dt);
      toques.ultY = p.clientY; toques.ultT = agora;
      const L = layoutNivel(nivelBase());
      doFim = Math.min(Math.max(0, L.alt - H), Math.max(0, toques.f0 + dy));
      pedirDesenho();
    }
  }
}, { passive: false });
cv.addEventListener('touchend', e => {
  e.preventDefault();
  if (toques.modo === 'pinca') { if (e.touches.length === 0) { toques.modo = ''; soltouPinca(); } return; }
  if (toques.modo === 'toque' && performance.now() - toques.t0 < 400 && toques.moveu < 10) tocou(toques.x0, toques.y0);
  else if (toques.modo === 'rolar' && !emMag()) inercia(toques.vel * 16);
  toques.modo = '';
}, { passive: false });
cv.addEventListener('touchcancel', () => { if (toques.modo === 'pinca') soltouPinca(); toques.modo = ''; });
document.addEventListener('gesturestart', e => e.preventDefault());

/* soltou a pinça: encaixa num nível (como o app Fotos); no rosto ampliado fica onde está */
function soltouPinca() {
  if (temMag() && zoom > ZM0) {
    if (zoom < ZM1) animarZoom(Math.log(zoom / ZM0) < Math.log(ZM1 / zoom) ? ZM0 : ZM1);
    else if (kAtual() < 1.25) animarZoom(zMax());
    else soltarAncora();
    return;
  }
  animarZoom(nivelPerto(zoom));
}
function animarZoom(alvo) {
  const z0 = zoom, t0 = performance.now(), dur = 300;
  fimAnim = () => { zoom = alvo; aplicarZoom(alvo); soltarAncora(); pedirDesenho(); };
  (function passo() {
    const k = Math.min(1, (performance.now() - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    aplicarZoom(z0 + (alvo - z0) * e); pedirDesenho();
    if (k < 1) animZoom = requestAnimationFrame(passo); else { animZoom = 0; const f = fimAnim; fimAnim = null; if (f) f(); }
  })();
}
function inercia(v) {
  (function passo() {
    v *= 0.95; if (Math.abs(v) < 0.3) return;
    const L = layoutNivel(nivelBase());
    const novo = Math.min(Math.max(0, L.alt - H), Math.max(0, doFim + v));
    if (novo === doFim) return;
    doFim = novo; pedirDesenho(); toques.inercia = requestAnimationFrame(passo);
  })();
}
let ultimoToque = 0;
function itemNoPonto(x, y) { return pontoAgora(x, y).i; }
function tocou(x, y) {
  const i = itemNoPonto(x, y);
  if (emSelecao) { if (i >= 0 && i < seq.length && seq[i] && seq[i] !== '#piada') { if (selecionados.has(i)) selecionados.delete(i); else selecionados.add(i); contarSelecao(); pedirDesenho(); } return; }
  const agora = performance.now(), noMosaico = emMag() && kAtual() < 1.05;
  if (noMosaico && agora - ultimoToque < 320) { ultimoToque = 0; alternarReal(); return; }
  ultimoToque = agora;
  if (i < 0 || i >= seq.length || !seq[i]) return;
  setTimeout(() => { if (ultimoToque === agora) abrirFoto(i); }, noMosaico && cfg.fotoReal ? 330 : 0);
}
function tocouNativo(i, noMosaico) {
  if (emSelecao) { if (i >= 0 && i < seq.length && seq[i] && seq[i] !== '#piada') { if (selecionados.has(i)) selecionados.delete(i); else selecionados.add(i); contarSelecao(); enviarGaleria(); } return; }
  const agora = performance.now();
  if (noMosaico && agora - ultimoToque < 320) { ultimoToque = 0; alternarReal(); return; }
  ultimoToque = agora;
  if (i < 0 || i >= seq.length || !seq[i]) return;
  setTimeout(() => { if (ultimoToque === agora) abrirFoto(i); }, noMosaico && cfg.fotoReal ? 330 : 0);
}
function alternarReal() { if (!cfg.fotoReal || !atual || atual.tipo !== 'rosto' || !mos) return; $('#real').classList.toggle('on'); }

/* ---------- galeria nativa (Fototeca feita pelo próprio iPhone) ---------- */
let nativo = false, envioPedido = false, zerarGal = true;
function zonasGal() {
  const z = [];
  for (const s of ['#titulo', '#bOrdem', '#bSel', '#aba', '#meio', '#lupa', '#barraSel .redondo', '#barraSel .aba', '.canto']) {
    $$(s).forEach(el => { const r = el.getBoundingClientRect(); if (r.width && r.height) z.push([r.left, r.top, r.width, r.height]); });
  }
  return z;
}
function enviarGaleria(zerar) {
  if (!nativo) return;
  if (zerar) zerarGal = true;
  if (envioPedido) return;
  envioPedido = true;
  setTimeout(() => {
    envioPedido = false;
    const ap = arqPiada();
    const s = seq.map(it => it === '#piada' ? (ap ? 'arq:' + ap : '') : (it || ''));
    const m = mos && mos.img && mos.seq === seq ? { ids: mos.ids, tinta: mos.tinta, cols: mos.cols, primeira: mos.primeira, linhas: mos.linhas, ultima: mos.ultima, ini: mos.ini, faixaL: mos.fL || 0, img: 'mosaico.jpg', v: String(mos.versao) } : null;
    const c = { reforco: +cfg.reforco, cor: cfg.cor, escuro: corFundo === '#000', n0: +cfg.n0 || 3, st: stPx(), sb: sbPx(), zonas: zonasGal(), selecao: emSelecao, sel: [...selecionados], ativa: !$('#busca').classList.contains('on') };
    nat.call('galeriaDados', { seq: s, mos: m, cfg: c, zerar: zerarGal }).catch(() => {});
    zerarGal = false;
  }, 0);
}
async function rectNat(i) {
  try { const r = await nat.call('galeriaRect', { i }); return r ? { x: r[0], y: r[1], w: r[2], h: r[3] } : null; } catch (_) { return null; }
}

/* cantos: trocar o bebê */
[['#cTL', 0], ['#cTR', 1], ['#cBL', 2], ['#cBR', 3]].forEach(([s, k]) => {
  $(s).addEventListener('touchend', e => {
    e.preventDefault(); e.stopPropagation();
    if (cfg.piada !== 'bebes') return;
    if (!cfg.bebes[k]) { vibrar('forte'); return; }
    cfg.bebe = k; salvar(); montarSeq(); vibrar('leve');
    if (atual && atual.pronto) prepararMosaico();
  }, { passive: false });
});

/* título: segurar 1 s ou três toques = ajustes */
(function () {
  let t = 0, x0 = 0, y0 = 0, toquesT = [];
  const el = $('#titulo');
  el.addEventListener('touchstart', e => {
    e.preventDefault(); const p = e.touches[0]; x0 = p.clientX; y0 = p.clientY;
    t = setTimeout(() => { t = 0; vibrar('media'); abrirAjustes(); }, 1000);
    const agora = performance.now(); toquesT = toquesT.filter(v => agora - v < 700); toquesT.push(agora);
    if (toquesT.length >= 3) { toquesT = []; clearTimeout(t); t = 0; vibrar('media'); abrirAjustes(); }
  }, { passive: false });
  el.addEventListener('touchmove', e => { const p = e.touches[0]; if (t && Math.hypot(p.clientX - x0, p.clientY - y0) > 14) { clearTimeout(t); t = 0; } }, { passive: true });
  const fim = () => { if (t) clearTimeout(t); t = 0; };
  el.addEventListener('touchend', fim); el.addEventListener('touchcancel', fim);
})();

/* botão redondo do meio: toque = câmera escondida; segurar = espiar o nome */
(function () {
  const el = $('#meio'); let t = 0, espiando = false;
  el.addEventListener('touchstart', e => { e.preventDefault(); t = setTimeout(() => { t = 0; espiando = true; espiar(true); }, 350); }, { passive: false });
  el.addEventListener('touchend', e => {
    e.preventDefault();
    if (t) { clearTimeout(t); t = 0; ligarCamera(); }
    if (espiando) { espiando = false; espiar(false); }
  }, { passive: false });
  el.addEventListener('touchcancel', () => { if (t) clearTimeout(t); t = 0; if (espiando) { espiando = false; espiar(false); } });
})();
function espiar(on) {
  const r = $('#rotulo');
  if (!on) { r.textContent = 'Fototeca'; r.style.color = ''; return; }
  if (!atual) { r.textContent = '—'; r.style.color = '#8e8e93'; return; }
  r.textContent = atual.nome;
  r.style.color = !atual.pronto ? '#ff9f0a' : atual.tipo === 'rosto' ? '' : '#8e8e93';
}

/* lupa: busca (o nome digitado vira o famoso) */
$('#lupa').addEventListener('click', () => { $('#busca').classList.add('on'); if (nativo) nat.call('galeria', { on: true, ativa: false }).catch(() => {}); $('#bMsg').innerHTML = ''; $('#bInput').value = ''; setTimeout(() => $('#bInput').focus(), 60); });
$('#bInput').addEventListener('keydown', e => {
  if (e.key === 'Enter') {
    const v = $('#bInput').value.trim(); $('#bInput').blur();
    if (v) { definirNome(v, 'busca'); $('#bMsg').innerHTML = '<b>Nenhum Resultado</b>Não há resultados para “' + esc(v) + '”. Tente uma nova pesquisa.'; }
  }
});
$('#bCanc').addEventListener('click', () => {
  const v = $('#bInput').value.trim(); $('#bInput').blur();
  if (v && !$('#bMsg').innerHTML) definirNome(v, 'busca');
  $('#busca').classList.remove('on');
  if (nativo) nat.call('galeria', { on: telaAtual === 'fototeca', ativa: true }).catch(() => {});
});

/* =====================================================================
   SELECIONAR e tirar fotos do app (nunca do iPhone)
   ===================================================================== */
let emSelecao = false; const selecionados = new Set();
$('#bSel').addEventListener('click', () => { if (emSelecao) sairSelecao(); else entrarSelecao(); });
function entrarSelecao() {
  if (zoom > 5) irAoNivel(5);
  emSelecao = true; selecionados.clear(); $('#fototeca').classList.add('selecao');
  $('#bSel').textContent = 'Cancelar'; $('#tituloTxt').textContent = 'Selecionar Itens'; contarSelecao(); pedirDesenho(); setTimeout(() => enviarGaleria(), 30);
}
function sairSelecao() {
  emSelecao = false; selecionados.clear(); $('#fototeca').classList.remove('selecao');
  $('#bSel').textContent = 'Selecionar'; $('#tituloTxt').textContent = 'Fototeca'; pedirDesenho(); setTimeout(() => enviarGaleria(), 30);
}
function contarSelecao() { const n = selecionados.size; $('#selConta').textContent = n ? n + (n === 1 ? ' Item Selecionado' : ' Itens Selecionados') : 'Selecionar Itens'; }
$('#selLixo').addEventListener('click', () => {
  if (!selecionados.size) return;
  tirarDoApp([...selecionados].map(i => seq[i]));
  sairSelecao();
});
function tirarDoApp(ids) {
  const ab = ids.filter(id => abertDe(id));
  if (ab.length) {
    for (const id of ab) { nat.call('apagar', { nome: id.slice(4) }).catch(() => {}); }
    cfg.abert = cfg.abert.filter(a => !ab.includes(tokAbert(a))); salvar();
    if (mos) mos.seq = mos.seq.filter(id => !ab.includes(id));
    montarSeq(); if (atual) prepararMosaico(); desenharAbert();
  }
  ids = ids.filter(id => id && id !== '#piada' && !String(id).startsWith('arq:'));
  if (!ids.length) return;
  ids.forEach(id => tirados.add(id));
  cfg.tirados = [...tirados]; salvar();
  if (mos) mos.seq = mos.seq.filter(id => !tirados.has(id));   // some já da tela
  montarSeq();
  if (atual) prepararMosaico();
}
$('#aDevolver').addEventListener('click', () => {
  if (!tirados.size) return;
  if (!confirm('Devolver ao app as ' + tirados.size + ' fotos tiradas?')) return;
  tirados = new Set(); cfg.tirados = []; salvar(); montarSeq(); if (atual) prepararMosaico(); mostrarTirados();
});
function mostrarTirados() { const e = $('#aTirados'); if (e) e.textContent = 'Fotos tiradas do app: ' + tirados.size; }

/* =====================================================================
   VISUALIZADOR
   ===================================================================== */
let verI = 0, vSeq = [];
/* a foto grande anda na ordem da Fototeca de verdade (a que o público viu), não na ordem do mosaico */
function comMosaico() { return !!(mos && mos.cS != null && seq === mos.seq); }
function listaVer() { vSeq = comMosaico() ? mos.normal : seq; }
function verDeCel(i) {
  if (!comMosaico()) return i;
  const r = Math.floor(i / mos.cols), c = i % mos.cols;
  if (c >= mos.cS && c < mos.cS + mos.k0 && r > mos.ultima - mos.fL) { const j = (mos.uN - (mos.ultima - r)) * mos.k0 + (c - mos.cS); if (j >= 0 && j < vSeq.length) return j; }
  const j = vSeq.indexOf(seq[i]); return j;
}
function celDeVer(j) {
  if (!comMosaico()) return j;
  if (vSeq[j] !== mos.normal[j]) return -1;
  const r = mos.ultima - (mos.uN - Math.floor(j / mos.k0)), c = mos.cS + j % mos.k0;
  return r >= 0 && r > mos.ultima - mos.fL ? r * mos.cols + c : -1;
}
const fmtData = new Intl.DateTimeFormat('pt-BR', { day: 'numeric', month: 'long', year: 'numeric' });
const fmtHora = new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit' });
function srcGrande(it) {
  if (it === '#piada') return URLS.arq(arqPiada(), cfg.ver);
  if (String(it).startsWith('arq:')) return URLS.arq(it.slice(4), cfg.ver);
  return URLS.foto(it, Math.round(Math.max(W, H) * DPR), true);
}
function grandeEmCache(it) {   // a maior versão dessa foto que já está carregada
  if (it === '#piada') return null;
  if (String(it).startsWith('arq:')) return URLS.arq(it.slice(4), cfg.ver);
  let m = null, ms = 0;
  for (const s of [Math.round(Math.max(W, H) * DPR), 1200, 800, 520, 400, 256]) { const e = IMG.get(it + '|' + s); if (e && e.ok && s > ms) { m = e.img.src; ms = s; } }
  if (!m) { const e = IMG.get(it + '|m'); if (e && e.ok) m = e.img.src; }
  return m;
}
const preCarga = new Map();
function preCarregar(i) {   // foto grande das vizinhas, antes de deslizar
  if (i < 0 || i >= vSeq.length || !vSeq[i] || preCarga.has(vSeq[i])) return;
  const g = new Image(); g.src = srcGrande(vSeq[i]); preCarga.set(vSeq[i], g);
  if (preCarga.size > 24) preCarga.delete(preCarga.keys().next().value);
}
function montarPalco() {
  const p = $('#palco'); p.innerHTML = '';
  for (const d of [-1, 0, 1]) {
    const i = verI + d, el = document.createElement('div'); el.className = 'fx'; el.style.left = (d * 100) + '%';
    if (i >= 0 && i < vSeq.length && vSeq[i]) {
      const im = document.createElement('img'); const it = vSeq[i];
      const pc = preCarga.get(it);
      if (pc && pc.complete && pc.naturalWidth) im.src = pc.src;
      else {
        // na hora: a miniatura (já está no aparelho) no tamanho e lugar exatos da foto; a nítida entra por cima
        const c = grandeEmCache(it);
        im.src = c || srcMini(it);
        if (!c && tams.has(it)) { const e = encaixe(...tams.get(it)); Object.assign(im.style, { position: 'absolute', left: e.x + 'px', top: e.y + 'px', width: e.w + 'px', height: e.h + 'px', objectFit: 'cover' }); }
        else if (!c) {
          im.style.visibility = 'hidden';
          tamanhoFoto(it).then(([fw, fh]) => {
            const e = encaixe(fw, fh);
            Object.assign(im.style, { position: 'absolute', left: e.x + 'px', top: e.y + 'px', width: e.w + 'px', height: e.h + 'px', objectFit: 'cover', visibility: '' });
          });
        }
        const g = pc || new Image();
        g.addEventListener('load', () => { im.src = g.src; im.style.objectFit = 'contain'; });
        if (!pc) { g.src = srcGrande(it); preCarga.set(it, g); }
      }
      if (d === 0) im.id = 'imgAtual';
      el.appendChild(im);
    }
    p.appendChild(el);
  }
  p.style.transform = 'translateX(0)';
  for (const d of [1, -1, 2, -2, 3, -3]) preCarregar(verI + d);
  montarTira();
  mostrarData();
}
/* faixa de miniaturas embaixo */
function montarTira() {
  const t = $('#tira'); if (!t) return;
  let h = '';
  for (let i = Math.max(0, verI - 14); i <= Math.min(vSeq.length - 1, verI + 14); i++) {
    const it = vSeq[i]; if (!it) continue;
    const src = srcMini(it);
    h += '<img data-i="' + i + '"' + (i === verI ? ' class="atual"' : '') + ' src="' + src + '">';
  }
  t.innerHTML = h;
  const at = t.querySelector('.atual');
  if (at) t.style.transform = 'translateX(' + (W / 2 - at.offsetLeft - at.offsetWidth / 2) + 'px)';
}
$('#tira').addEventListener('click', e => { const im = e.target.closest('[data-i]'); if (im) { verI = +im.dataset.i; montarPalco(); } });
async function mostrarData() {
  const it = vSeq[verI], el = $('#vData');
  const ab = abertDe(it);
  if (ab) { if (ab.data) { const dt = new Date(ab.data); el.innerHTML = fmtData.format(dt) + '<small>' + fmtHora.format(dt) + '</small>'; } else el.innerHTML = ''; return; }
  if (it === '#piada') { el.innerHTML = 'Hoje<small>' + fmtHora.format(new Date(Date.now() - 35 * 60000)) + '</small>'; return; }
  el.innerHTML = '';
  try { const d = await nat.call('info', { id: it }); if (d && d.data && vSeq[verI] === it) { const dt = new Date(d.data); el.innerHTML = fmtData.format(dt) + '<small>' + fmtHora.format(dt) + '</small>'; } } catch (_) {}
}
/* abrir e fechar como o app Fotos: a foto cresce a partir da miniatura e volta para ela */
const tams = new Map();
async function tamanhoFoto(it) {
  if (tams.has(it)) return tams.get(it);
  const t = await tamanhoFoto0(it); if (t[0] && !(t[0] === 3 && t[1] === 4)) tams.set(it, t); return t;
}
async function tamanhoFoto0(it) {
  const ab = abertDe(it); if (ab && ab.w) return [ab.w, ab.h];
  if (it === '#piada') { const im = IMG.get(arqPiada() + '|' + cfg.ver); return im && im.ok ? [im.img.naturalWidth, im.img.naturalHeight] : [3, 4]; }
  try { const d = await Promise.race([nat.call('info', { id: it }), new Promise(r => setTimeout(() => r(null), 120))]); if (d && d.w) return [d.w, d.h]; } catch (_) {}
  return [3, 4];
}
function encaixe(w, h) { const k = Math.min(W / w, H / h); return { w: w * k, h: h * k, x: (W - w * k) / 2, y: (H - h * k) / 2 }; }
function voar(de, para, src, fundoDe, fundoPara, fim) {
  const v = $('#voo'), cx = $('#vooCx'), f = $('#vooFundo');
  $('#vooImg').src = src || '';
  v.style.display = 'block';
  f.style.transition = 'none'; f.style.opacity = fundoDe;
  cx.style.transition = 'none';
  Object.assign(cx.style, { left: de.x + 'px', top: de.y + 'px', width: de.w + 'px', height: de.h + 'px', borderRadius: (de.r || 0) + 'px' });
  cx.getBoundingClientRect();
  requestAnimationFrame(() => {
    f.style.transition = 'opacity .32s ease'; f.style.opacity = fundoPara;
    cx.style.transition = 'left .34s cubic-bezier(.2,.85,.25,1), top .34s cubic-bezier(.2,.85,.25,1), width .34s cubic-bezier(.2,.85,.25,1), height .34s cubic-bezier(.2,.85,.25,1)';
    Object.assign(cx.style, { left: para.x + 'px', top: para.y + 'px', width: para.w + 'px', height: para.h + 'px' });
  });
  setTimeout(() => { if (fim) fim(); setTimeout(() => { v.style.display = 'none'; }, 30); }, 360);
}
let abrindo = false;
async function abrirFoto(i) {
  if (abrindo) return; abrindo = true;
  listaVer();
  const cel = i; i = verDeCel(cel); if (i < 0) { abrindo = false; return; }
  verI = i; const it = vSeq[i];
  const de = nativo ? await rectNat(cel) : rectDoItem(cel), [fw, fh] = await tamanhoFoto(it), para = encaixe(fw, fh);
  let src = grandeEmCache(it) || srcMini(it);
  if (!grandeEmCache(it) && !String(it).startsWith('arq:') && it !== '#piada') {   // espera a foto nítida (no máx. 1/4 s): já chega nítida
    let g = preCarga.get(it); if (!g) { g = new Image(); g.src = srcGrande(it); preCarga.set(it, g); }
    if (!(g.complete && g.naturalWidth)) await Promise.race([new Promise(r => { g.addEventListener('load', r); g.addEventListener('error', r); }), new Promise(r => setTimeout(r, 260))]);
    if (g.complete && g.naturalWidth) src = g.src;
  }
  $('#ver').classList.remove('limpo');
  if (!de) { mostrar('ver', true); montarPalco(); abrindo = false; return; }
  preCarregar(i);
  voar(de, para, src, 0, 1, () => { mostrar('ver', true); montarPalco(); abrindo = false; });
}
async function fecharFoto() {
  const it = vSeq[verI], im = $('#imgAtual');
  const src = im && im.src ? im.src : '';
  const [fw, fh] = await tamanhoFoto(it), de = encaixe(fw, fh);
  mostrar('fototeca');
  let para;
  const cel = celDeVer(verI);
  if (cel < 0) return;
  if (nativo) { await nat.call('galeriaVer', { i: cel }).catch(() => {}); para = await rectNat(cel); }
  else { garantirVisivel(cel); desenhar(); para = rectDoItem(cel); }
  if (!para || !src) return;
  voar(de, para, src, 1, 0, null);
}
$('#vVolta').addEventListener('click', fecharFoto);
$('#vLixo').addEventListener('click', () => {
  const it = vSeq[verI];
  if (it === '#piada') { ligarVoz(); return; }   // camuflado: nada muda na tela
  const im = $('#imgAtual'); if (im) im.classList.add('indo');
  setTimeout(() => {
    tirarDoApp([it]); listaVer();
    if (!vSeq.length) { fecharFoto(); return; }
    verI = Math.min(verI, vSeq.length - 1); montarPalco();
  }, 360);
});
(function () {
  const p = $('#palco'); let x0 = 0, y0 = 0, dx = 0, dy = 0, modo = '', t0 = 0;
  p.addEventListener('touchstart', e => { if (e.touches.length !== 1) return; x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; dx = dy = 0; modo = ''; t0 = performance.now(); p.style.transition = 'none'; }, { passive: true });
  p.addEventListener('touchmove', e => {
    if (e.touches.length !== 1) return; e.preventDefault();
    dx = e.touches[0].clientX - x0; dy = e.touches[0].clientY - y0;
    if (!modo && Math.hypot(dx, dy) > 8) modo = Math.abs(dx) > Math.abs(dy) ? 'lado' : 'baixo';
    if (modo === 'lado') p.style.transform = 'translateX(' + dx + 'px)';
    else if (modo === 'baixo' && dy > 0) { p.style.transform = 'translateY(' + dy + 'px) scale(' + Math.max(0.7, 1 - dy / 1200) + ')'; $('#ver').style.background = 'rgba(0,0,0,' + Math.max(0, 1 - dy / 400) + ')'; }
  }, { passive: false });
  p.addEventListener('touchend', () => {
    p.style.transition = 'transform .25s ease';
    if (!modo && performance.now() - t0 < 300) { $('#ver').classList.toggle('limpo'); return; }
    if (modo === 'lado') {
      const ir = dx < -60 && verI < vSeq.length - 1 ? 1 : dx > 60 && verI > 0 ? -1 : 0;
      p.style.transform = 'translateX(' + (-ir * W) + 'px)';
      if (ir) setTimeout(() => { verI += ir; p.style.transition = 'none'; montarPalco(); }, 250);
    } else if (modo === 'baixo') {
      $('#ver').style.background = '';
      if (dy > 110) fecharFoto(); else p.style.transform = 'none';
    }
  });
})();

/* =====================================================================
   CÂMERA ESCONDIDA e MICROFONE (avisos que vêm do iPhone)
   ===================================================================== */
let camLigada = false, camCand = '', camVezes = 0, vozLigada = false;
async function ligarCamera() {
  if (camLigada) return;
  camLigada = true; camCand = ''; camVezes = 0;
  try { await nat.call('cameraLigar', { segundos: 8 }); }
  catch (e) { camLigada = false; vibrar('forte'); }
}
function camAchou(nome) {
  camLigada = false; nat.call('cameraDesligar').catch(() => {});
  vibrar('media'); definirNome(nome, 'camera');
}
async function ligarVoz() {
  if (vozLigada) return;
  vozLigada = true;
  try { await nat.call('vozLigar', { segundos: 7 }); vibrar('leve'); }
  catch (e) { vozLigada = false; vibrar('forte'); }
}
const PALAVRAS_SOBRA = new Set(('o a os as e é de da do dos das um uma esse essa este esta isso aqui ai aí olha olhe então entao era foi ' +
  'ele ela the bebe bebê desenhado desenhada desenho quando pequeno pequena com meses mes foto ne né tá ta que quem').split(' ').map(semAcento));
window.__mzEvento = ev => {
  if (!ev || !ev.tipo) return;
  if (ev.tipo === 'gTap') { tocouNativo(ev.i, !!ev.noMosaico); return; }
  if (ev.tipo === 'texto' && camLigada) {
    const linhas = (ev.linhas || []).filter(l => l && l.t);
    let f = acharFamosoEm(linhas.map(l => l.t).join(' '));
    if (!f) for (const l of linhas) { f = acharFamoso(l.t); if (f) break; }
    if (f) return camAchou(f.n);
    // nome fora da lista: a maior linha que aparecer igual 3 vezes seguidas
    const boa = linhas.filter(l => /[a-zà-ú]{2,}/i.test(l.t) && l.t.length <= 40).sort((a, b) => b.h - a.h)[0];
    if (boa) { const k = semAcento(boa.t); if (k === camCand) camVezes++; else { camCand = k; camVezes = 1; } if (camVezes >= 3) camAchou(maiusculas(boa.t.trim())); }
  } else if (ev.tipo === 'cameraFim') {
    if (camLigada) { camLigada = false; vibrar('forte'); }
  } else if (ev.tipo === 'voz' && vozLigada) {
    const f = acharFamosoEm(ev.texto || '');
    if (f) { vozLigada = false; nat.call('vozDesligar').catch(() => {}); vibrar('media'); definirNome(f.n, 'voz'); return; }
    if (ev.final) {
      vozLigada = false;
      const resto = semAcento(ev.texto).split(' ').filter(p => p && !PALAVRAS_SOBRA.has(p));
      if (resto.length >= 1 && resto.length <= 4) { vibrar('media'); definirNome(maiusculas(resto.join(' ')), 'voz'); }
      else vibrar('forte');
    }
  } else if (ev.tipo === 'vozFim') {
    if (vozLigada) { vozLigada = false; vibrar('forte'); }
  }
};

/* =====================================================================
   NOTAS FALSO
   ===================================================================== */
let notaEnviada = '';
const fmtNota = new Intl.DateTimeFormat('pt-BR', { day: 'numeric', month: 'long', year: 'numeric' });
function abrirNotas() {
  const t = $('#ntexto'); t.textContent = ''; notaEnviada = '';
  const d = new Date(); $('#nData').textContent = fmtNota.format(d) + ' às ' + fmtHora.format(d);
  mostrar('notas', true);
  setTimeout(() => t.focus(), 250);
}
function linhaDaNota() { return ($('#ntexto').innerText || '').split('\n').map(s => s.trim()).find(Boolean) || ''; }
function enviarNota() {   // ✓ amarelo: esconde o teclado e manda o nome
  const l = linhaDaNota(); $('#ntexto').blur();
  if (l && l !== notaEnviada) { notaEnviada = l; definirNome(l, 'notas'); }
}
function fecharNotas() {
  enviarNota();
  mostrar(telaAnterior || (cfg.abrir === 'inicio' && cfg.temPrint ? 'inicio' : 'fototeca'));
}
$('#nVolta').addEventListener('click', fecharNotas);
$('#nOk').addEventListener('click', enviarNota);
/* barra de ferramentas logo acima do teclado */
function posicionarFerramentas() {
  const b = $('#nferr'), vv = window.visualViewport;
  const aberto = document.activeElement === $('#ntexto') && vv && vv.height < innerHeight - 120;
  b.classList.toggle('on', !!aberto);
  if (aberto) b.style.top = (vv.offsetTop + vv.height - 58) + 'px';
}
if (window.visualViewport) { visualViewport.addEventListener('resize', posicionarFerramentas); visualViewport.addEventListener('scroll', posicionarFerramentas); }
$('#ntexto').addEventListener('focus', () => setTimeout(posicionarFerramentas, 350));
$('#ntexto').addEventListener('blur', () => $('#nferr').classList.remove('on'));

/* três pontinhos = sinal secreto: 1 nome recebido, 2 foto do famoso achada, 3 mosaico pronto */
let etapa = { n: 0, foto: false };
function pontos(n, foto) {
  etapa = { n, foto: !!foto };
  $$('#pts i').forEach((el, i) => el.classList.toggle('on', i === 0 ? n >= 1 : i === 1 ? (n >= 2 && etapa.foto) : n >= 3));
}

/* =====================================================================
   TELA DE INÍCIO (print) e marcação dos ícones
   ===================================================================== */
function aplicarPrint() {
  const c = $('#cvIni');
  $('#inicioVazio').style.display = cfg.temPrint ? 'none' : 'flex';
  $('#marcar').style.backgroundImage = cfg.temPrint ? 'url("' + URLS.arq('inicio/print.jpg', cfg.ver) + '")' : '';
  if (!cfg.temPrint) { c.width = 1; c.height = 1; return; }
  const im = new Image();
  im.onload = () => {
    c.width = Math.round(W * DPR); c.height = Math.round(H * DPR);
    const g = c.getContext('2d'), k = Math.max(c.width / im.naturalWidth, c.height / im.naturalHeight);
    const w = im.naturalWidth * k, h = im.naturalHeight * k, x = (c.width - w) / 2, y = (c.height - h) / 2;
    g.drawImage(im, x, y, w, h);
    const faixa = Math.round((stPx() + 2) * DPR), srcY = (faixa + 3 * DPR - y) / k;
    g.drawImage(im, 0, srcY, im.naturalWidth, 1, x, 0, w, faixa);   // apaga a hora/bateria do print
  };
  im.src = URLS.arq('inicio/print.jpg', cfg.ver);
}
$('#inicio').addEventListener('click', e => {
  const z = cfg.zonas || {}, x = e.clientX / W, y = e.clientY / H;
  const perto = p => p && Math.abs(p.x - x) * W < 38 && Math.abs(p.y - y) * H < 40;
  if (perto(z.fotos)) abrirDoIcone('fototeca', z.fotos);
  else if (perto(z.notas)) abrirDoIcone('notas', z.notas);
  else if (perto(z.ajustes)) abrirAjustes();
  else if (!cfg.temPrint) abrirAjustes();
});
function abrirDoIcone(qual, p) {
  const el = qual === 'notas' ? $('#notas') : $('#fototeca');
  el.style.transformOrigin = (p.x * 100) + '% ' + (p.y * 100) + '%';
  el.style.transition = 'none'; el.style.transform = 'scale(.12)'; el.style.opacity = '0.3';
  if (qual === 'notas') abrirNotas(); else mostrar('fototeca', true);
  requestAnimationFrame(() => requestAnimationFrame(() => { el.style.transition = 'transform .34s cubic-bezier(.2,.9,.25,1), opacity .2s'; el.style.transform = 'none'; el.style.opacity = '1'; }));
}
let passoMarca = 0;
const PASSOS = [['fotos', 'Toque no meio do ícone Fotos'], ['notas', 'Toque no meio do ícone Notas'], ['ajustes', 'Toque no meio do ícone Ajustes (abre estes ajustes escondidos)']];
function iniciarMarcar() {
  if (!cfg.temPrint) { toast('Escolha o print primeiro'); return; }
  passoMarca = 0; cfg.zonas = cfg.zonas || {}; $$('#marcar .alvo').forEach(p => p.remove());
  mostrar('marcar', true); $('#mMsg').textContent = PASSOS[0][1];
}
function proximaMarca() { passoMarca++; if (passoMarca >= PASSOS.length) { salvar(); mostrar('ajustes', true); toast('Ícones marcados'); return; } $('#mMsg').textContent = PASSOS[passoMarca][1]; }
$('#marcar').addEventListener('click', e => {
  if (e.target.closest('.aviso')) return;
  cfg.zonas[PASSOS[passoMarca][0]] = { x: e.clientX / W, y: e.clientY / H };
  const p = document.createElement('div'); p.className = 'alvo'; p.style.left = e.clientX + 'px'; p.style.top = e.clientY + 'px'; $('#marcar').appendChild(p);
  vibrar('leve'); proximaMarca();
});
$('#mPula').addEventListener('click', proximaMarca);
$('#mSai').addEventListener('click', () => { salvar(); mostrar('ajustes', true); });

/* =====================================================================
   TELAS
   ===================================================================== */
let telaAtual = '', telaAnterior = '';
function escuroAgora() { return cfg.tema === 'escuro' || (cfg.tema === 'auto' && (!window.matchMedia || matchMedia('(prefers-color-scheme: dark)').matches)); }
function mostrar(id, guardaAnterior) {
  if (guardaAnterior && telaAtual && telaAtual !== id && telaAtual !== 'ajustes' && telaAtual !== 'marcar') telaAnterior = telaAtual;
  $$('.tela').forEach(t => t.classList.toggle('on', t.id === id));
  telaAtual = id;
  if (nativo) { document.documentElement.classList.toggle('transp', id === 'fototeca'); nat.call('galeria', { on: id === 'fototeca', ativa: !$('#busca').classList.contains('on') }).catch(() => {}); if (id === 'fototeca') enviarGaleria(); }
  const escuro = escuroAgora() || id === 'inicio' || id === 'marcar';
  nat.msg('barra', id === 'marcar');
  nat.msg('estilo', escuro ? 'claro' : 'escuro');
  if (id === 'fototeca') pedirDesenho();
}
function abrirAjustes() { if (emSelecao) sairSelecao(); mostrar('ajustes', true); encherAjustes(); }
$('#aFecha').addEventListener('click', () => {
  salvar();
  const volta = telaAnterior && telaAnterior !== 'ajustes' && telaAnterior !== 'marcar' ? telaAnterior : (cfg.abrir === 'inicio' && cfg.temPrint ? 'inicio' : 'fototeca');
  mostrar(volta);
});
function aplicarTema() {
  const claro = !escuroAgora();
  document.body.classList.toggle('claro', claro); corFundo = claro ? '#fff' : '#000'; enviarGaleria();
  if (telaAtual) mostrar(telaAtual);
  pedirDesenho();
}
if (window.matchMedia) { try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', aplicarTema); } catch (_) {} }

/* =====================================================================
   AJUSTES
   ===================================================================== */
const ROT_BEBE = ['Menino branco', 'Menina branca', 'Menino negro', 'Menina negra'];
const CURTO_BEBE = ['Men. br.', 'Mna. br.', 'Men. ng.', 'Mna. ng.'];
async function encherAjustes() {
  mostrarAtual(); mostrarTirados();
  $('#aInj').checked = !!cfg.inj; $('#aInjId').value = cfg.injId || ''; $('#aWk').value = cfg.wk || '';
  $('#aCols').value = String(cfg.colsM); $('#aCor').value = cfg.cor; $('#aRef').value = cfg.reforco; $('#aRefV').textContent = Math.round(cfg.reforco * 100) + '%';
  $('#aEnq').value = cfg.enq; $('#aFiltro').checked = !!cfg.filtro; $('#aAviso').checked = !!cfg.aviso;
  $('#aReal').checked = !!cfg.fotoReal; $('#aVib').checked = !!cfg.vibrar; $('#aLimite').value = String(cfg.limite);
  $('#aAbrir').value = cfg.abrir; $('#aTema').value = cfg.tema; $('#aN0').value = String(cfg.n0); $('#aPiada').value = cfg.piada;
  if (!analisando) mostrarAnalise(1, 1);
  desenharPiada(); desenharListaFam();
  try {
    const al = await nat.call('albuns'); const s = $('#aOrigem');
    s.innerHTML = '<option value="">Todas as fotos</option>' + al.map(a => '<option value="' + esc(a.id) + '">' + esc(a.nome) + ' (' + a.n + ')</option>').join('');
    s.value = cfg.origem || '';
  } catch (_) {}
}
function desenharPiada() {
  const bebes = cfg.piada === 'bebes';
  $('#aBebes').parentNode.style.display = bebes ? '' : 'none';
  $('#aFixas').style.display = bebes ? 'none' : '';
  $('#aBebes').innerHTML = ROT_BEBE.map((r, k) => '<div class="' + (cfg.bebe === k ? 'atual' : '') + '" data-k="' + k + '"><img ' + (cfg.bebes[k] ? 'src="' + URLS.arq('bebes/' + k + '.jpg', cfg.ver) + '"' : '') + '>' + (k + 1) + '. ' + r + '</div>').join('');
  $('#aFixas').innerHTML = cfg.fixas.map((f, i) => '<div class="lin" data-i="' + i + '"><img class="mini" src="' + URLS.arq('piada/' + f.id + '.jpg', cfg.ver) + '"><span style="flex:1">' + esc(f.nome) + '</span>'
    + (cfg.fixa === i ? '<span class="ok">em uso</span>' : '<button class="bt cinza" data-a="usar">Usar</button>') + '<button class="bt cinza" data-a="tirar" style="padding:8px 9px">✕</button></div>').join('')
    + '<div class="lin"><button class="bt" id="aAddFixa">+ Adicionar foto fixa</button></div>';
}
$('#aPiada').addEventListener('change', e => { cfg.piada = e.target.value; salvar(); desenharPiada(); montarSeq(); if (atual) prepararMosaico(); });
$('#aBebes').addEventListener('click', async e => {
  const d = e.target.closest('[data-k]'); if (!d) return; const k = +d.dataset.k;
  try {
    const r = await nat.call('escolher', { nome: 'bebes/' + k + '.jpg', rosto: false });
    if (r && r.ok) { cfg.bebes[k] = true; cfg.bebe = k; cfg.ver++; salvar(); desenharPiada(); montarSeq(); if (atual) prepararMosaico(); }
  } catch (_) {}
});
$('#aFixas').addEventListener('click', async e => {
  if (e.target.id === 'aAddFixa') {
    const id = 'f' + Date.now();
    try {
      const r = await nat.call('escolher', { nome: 'piada/' + id + '.jpg', rosto: false });
      if (r && r.ok) {
        const nome = prompt('Nome desta foto (ex.: Prancheta)', 'Prancheta') || 'Foto ' + (cfg.fixas.length + 1);
        cfg.fixas.push({ id, nome }); cfg.fixa = cfg.fixas.length - 1; cfg.ver++; salvar(); desenharPiada(); montarSeq(); if (atual) prepararMosaico();
      }
    } catch (_) {}
    return;
  }
  const l = e.target.closest('[data-i]'), a = e.target.dataset.a; if (!l || !a) return; const i = +l.dataset.i;
  if (a === 'usar') cfg.fixa = i;
  else if (a === 'tirar' && confirm('Tirar a foto "' + cfg.fixas[i].nome + '"?')) { nat.call('apagar', { nome: 'piada/' + cfg.fixas[i].id + '.jpg' }).catch(() => {}); cfg.fixas.splice(i, 1); if (cfg.fixa >= cfg.fixas.length) cfg.fixa = 0; }
  salvar(); desenharPiada(); montarSeq(); if (atual) prepararMosaico();
});
function desenharAbert() {
  const e = $('#aAbert'); if (!e) return;
  e.innerHTML = '<div class="lin"><span style="flex:1">' + cfg.abert.length + ' de ' + MAX_ABERT + ' fotos</span>'
    + (cfg.abert.length < MAX_ABERT ? '<button class="bt" data-a="add">Escolher</button>' : '')
    + (cfg.abert.length ? ' <button class="bt" data-a="limpar">Limpar</button>' : '') + '</div>'
    + (cfg.abert.length ? '<div class="miniGrade">' + cfg.abert.map(a => '<img src="' + URLS.arq('abert/' + a.id + '.jpg', cfg.ver) + '">').join('') + '</div>' : '');
}
$('#aAbert').addEventListener('click', async e => {
  const a = e.target.dataset.a; if (!a) return;
  if (a === 'add') {
    try {
      const r = await nat.call('escolherVarias', { pasta: 'abert', max: MAX_ABERT - cfg.abert.length });
      if (Array.isArray(r) && r.length) { cfg.abert = cfg.abert.concat(r).slice(0, MAX_ABERT); cfg.ver++; salvar(); montarSeq(); if (atual) prepararMosaico(); }
    } catch (_) {}
  } else if (a === 'limpar' && confirm('Tirar as ' + cfg.abert.length + ' fotos do começo?')) {
    for (const x of cfg.abert) nat.call('apagar', { nome: 'abert/' + x.id + '.jpg' }).catch(() => {});
    cfg.abert = []; salvar(); montarSeq(); if (atual) prepararMosaico();
  }
  desenharAbert();
});
desenharAbert();
function desenharListaFam() {
  atualizarContaFam();
  if (telaAtual !== 'ajustes') return;
  const el = $('#listaFam'), q = semAcento($('#aBuscaFam').value), filtro = $('#aFamFiltro').value;
  const lista = famosos.map((f, i) => [f, i]).filter(([f]) => (!q || semAcento(f.n).includes(q)) && (filtro !== 'sembebe' || f.b < 0) && (filtro !== 'semfoto' || !f.f))
    .sort((a, b) => a[0].n.localeCompare(b[0].n, 'pt'));
  el.innerHTML = lista.map(([f, i]) => '<div class="lin" data-i="' + i + '"><img class="mini" data-a="foto" ' + (f.f ? 'src="' + URLS.arq(f.f, cfg.ver) + '"' : '') + '><div class="nm"><b>' + esc(f.n) + '</b><small class="' + (f.f ? (f.r === false ? 'erro' : 'ok') : '') + '">' + (f.f ? (f.r === false ? 'sem rosto achado — troque a foto' : 'foto pronta') : (f.r === false ? 'não achou foto' : 'sem foto')) + '</small></div>'
    + '<button class="bt cinza" data-a="usar">Usar</button><button class="bt cinza" data-a="tirar" style="padding:8px 9px">✕</button>'
    + '<div class="bbs">' + CURTO_BEBE.map((r, k) => '<button data-a="bebe" data-k="' + k + '" class="' + (f.b === k ? 'sim' : '') + '">' + (k + 1) + ' ' + r + '</button>').join('') + '</div></div>').join('')
    || '<div class="lin estado">Nada encontrado — toque em + para adicionar</div>';
}
function atualizarContaFam() { const e = $('#aFamEst'); if (e && !baixandoTodos) e.textContent = famosos.length + ' famosos · ' + famosos.filter(f => f.f).length + ' com foto · ' + famosos.filter(f => f.b >= 0).length + ' com bebê'; }
$('#aBuscaFam').addEventListener('input', desenharListaFam);
$('#aFamFiltro').addEventListener('change', desenharListaFam);
$('#aAdd').addEventListener('click', async () => {
  const v = $('#aBuscaFam').value.trim(); if (v.length < 2) return;
  const ja = acharFamoso(v); if (ja && semAcento(ja.n) === semAcento(v)) { toast('Já está na lista'); return; }
  const f = { n: maiusculas(v), w: '', a: [], b: -1, f: '', r: null };
  famosos.push(f); salvarFam(); desenharListaFam(); toast('Procurando foto…');
  const r = await baixarFamoso(f, false); toast(r ? 'Foto guardada' : 'Não achei foto — toque na miniatura para escolher uma');
  desenharListaFam();
});
$('#listaFam').addEventListener('click', async e => {
  const l = e.target.closest('[data-i]'); const a = e.target.dataset.a; if (!l || !a) return;
  const f = famosos[+l.dataset.i];
  if (a === 'bebe') { const k = +e.target.dataset.k; f.b = f.b === k ? -1 : k; salvarFam(); desenharListaFam(); }
  else if (a === 'usar') { definirNome(f.n, 'ajustes'); toast('Preparando ' + f.n); }
  else if (a === 'tirar') { if (confirm('Tirar ' + f.n + ' da lista?')) { if (f.f) nat.call('apagar', { nome: f.f }).catch(() => {}); famosos.splice(+l.dataset.i, 1); salvarFam(); desenharListaFam(); } }
  else if (a === 'foto') {
    const nome = 'famosos/' + slug(f.n) + '.jpg';
    try { const r = await nat.call('escolher', { nome, rosto: true }); if (r && r.ok) { f.f = nome; f.r = !!r.rosto; cfg.ver++; salvar(); salvarFam(); desenharListaFam(); if (atual && atual.nome === f.n) definirNome(f.n, 'ajustes'); } } catch (_) {}
  }
});
let baixandoTodos = false;
$('#aBaixar').addEventListener('click', async () => {
  if (baixandoTodos) { baixandoTodos = false; return; }
  baixandoTodos = true; $('#aBaixar').textContent = 'Parar';
  const faltam = famosos.filter(f => !f.f);
  let feitos = 0;
  for (const f of faltam) {
    if (!baixandoTodos) break;
    $('#aFamEst').textContent = 'Baixando ' + (++feitos) + ' de ' + faltam.length + '…';
    await baixarFamoso(f, false);
  }
  baixandoTodos = false; $('#aBaixar').textContent = 'Baixar fotos'; desenharListaFam();
  toast('Fotos dos famosos atualizadas');
});
$('#aUsar').addEventListener('click', () => { const v = $('#aNome').value.trim(); if (v) { definirNome(v, 'ajustes'); $('#aNome').value = ''; $('#aNome').blur(); } });
$('#aLimpar').addEventListener('click', limparNome);
$('#aInj').addEventListener('change', e => { cfg.inj = e.target.checked; salvar(); iniciarInject(); });
$('#aInjId').addEventListener('input', e => { cfg.injId = e.target.value.trim(); salvar(); iniciarInject(); });
$('#aWk').addEventListener('input', e => { cfg.wk = e.target.value.trim(); salvar(); iniciarInject(); });
$('#aOrigem').addEventListener('change', e => { cfg.origem = e.target.value; salvar(); carregarFotos(); });
$('#aLimite').addEventListener('change', e => { cfg.limite = +e.target.value; salvar(); analisarFotos(); });
$('#aReanalisar').addEventListener('click', () => carregarFotos());
const refazer = () => { salvar(); if (atual) prepararMosaico(); };
$('#aCols').addEventListener('change', e => { cfg.colsM = +e.target.value; refazer(); });
$('#aCor').addEventListener('change', e => { cfg.cor = e.target.value; refazer(); });
$('#aEnq').addEventListener('change', e => { cfg.enq = e.target.value; refazer(); });
$('#aFiltro').addEventListener('change', e => { cfg.filtro = e.target.checked; refazer(); });
$('#aRef').addEventListener('input', e => { cfg.reforco = +e.target.value; $('#aRefV').textContent = Math.round(cfg.reforco * 100) + '%'; });
$('#aRef').addEventListener('change', () => { refazer(); enviarGaleria(); });
$('#aAviso').addEventListener('change', e => { cfg.aviso = e.target.checked; salvar(); mostrarAtual(); });
$('#aReal').addEventListener('change', e => { cfg.fotoReal = e.target.checked; salvar(); });
$('#aVib').addEventListener('change', e => { cfg.vibrar = e.target.checked; salvar(); });
$('#aAbrir').addEventListener('change', e => { cfg.abrir = e.target.value; salvar(); });
$('#aTema').addEventListener('change', e => { cfg.tema = e.target.value; salvar(); aplicarTema(); });
$('#aN0').addEventListener('change', e => { cfg.n0 = +e.target.value; zoom = cfg.n0; doFim = 0; enviarGaleria(true); salvar(); montarSeq(); if (atual) prepararMosaico(); });
$('#aPrint').addEventListener('click', async () => {
  try { const r = await nat.call('escolher', { nome: 'inicio/print.jpg', rosto: false }); if (r && r.ok) { cfg.temPrint = true; cfg.ver++; salvar(); aplicarPrint(); iniciarMarcar(); } } catch (_) {}
});
$('#aMarcar').addEventListener('click', iniciarMarcar);

/* =====================================================================
   INJECT (o mesmo intermediário do app Listas)
   ===================================================================== */
let injTimer = 0, injGen = 0, injUlt = null;
function iniciarInject() {
  clearTimeout(injTimer); const g = ++injGen;
  if (!cfg.inj || !cfg.injId || !cfg.wk) return;
  let w = cfg.wk.trim(); if (!/^https?:\/\//.test(w)) w = 'https://' + w; w = w.replace(/\/+$/, '');
  const chave = 'injUlt_' + cfg.injId; injUlt = guarda.get(chave, null);
  const passo = async () => {
    if (g !== injGen) return;
    if (!document.hidden) {
      try {
        const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 8000);
        const r = await fetch(w + '/inject?id=' + encodeURIComponent(cfg.injId) + '&_=' + Date.now(), { cache: 'no-store', signal: ac.signal });
        clearTimeout(t);
        const d = await r.json();
        if (g !== injGen) return;
        if (d && !d.error) {
          if (injUlt === null) { injUlt = d.count; guarda.set(chave, d.count); }
          else if (d.count !== injUlt) {
            injUlt = d.count; guarda.set(chave, d.count);
            const v = String(d.value || '').trim();
            const e = $('#aInjUlt'); if (e) e.textContent = v + ' (' + fmtHora.format(new Date()) + ')';
            if (v) definirNome(v, 'inject');
          }
        }
      } catch (_) {}
    }
    if (g === injGen) injTimer = setTimeout(passo, 1000);
  };
  passo();
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) { iniciarInject(); if (nat.tem) carregarFotos(); } });

/* =====================================================================
   INÍCIO
   ===================================================================== */
window.addEventListener('resize', () => { ajustarTamanho(); enviarGaleria(); });
async function testarNativo() {
  if (!nat.tem) return;
  try { await nat.call('galeriaEstado'); nativo = true; document.documentElement.classList.add('galNat'); enviarGaleria(true); if (telaAtual) mostrar(telaAtual); } catch (_) { nativo = false; }
}
function iniciar() {
  testarNativo();
  ajustarTamanho(); aplicarTema(); aplicarPrint();
  zoom = +cfg.n0 || 3;
  mostrar(cfg.abrir === 'inicio' && cfg.temPrint ? 'inicio' : 'fototeca');
  mostrarAtual();
  carregarFotos().then(async () => { if (atual) { await prepararMosaico(); if (atual) pontos(3, atual.tipo === 'rosto'); } });
  iniciarInject();
}
iniciar();
