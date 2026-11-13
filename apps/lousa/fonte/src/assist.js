// ===== Lousa — app do assistente (manda para o iPhone do mágico pela internet) =====
(function () {
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));
  const rnd = () => (Math.random() * 1e9) >>> 0;
  const two = (n) => String(n).padStart(2, '0');
  const ABLY_KEY = '-WkBxA.FUModg:DGe6U1wyeEuOu4_3iuubjnS144Ol3ojOlTb9mmqgmv0';
  const canal = (location.hash || '').replace('#', '').trim();

  // ---------- quem eu sou (nome fixo neste celular: conta 1 só no Ably) ----------
  let me = ''; try { me = localStorage.getItem('lousa.assistId') || ''; } catch (e) {}
  if (!me) { me = 'assist-' + Math.random().toString(36).slice(2, 10); try { localStorage.setItem('lousa.assistId', me); } catch (e) {} }

  // ---------- avisos ----------
  let toastT = null;
  function toast(msg, bad) { const t = $('#toast'); t.textContent = msg; t.className = 'on' + (bad ? ' bad' : ''); clearTimeout(toastT); toastT = setTimeout(() => t.className = '', bad ? 4000 : 2200); }

  // ---------- o que o app do mágico informa (tamanhos, aparência, lousa) ----------
  let main = null;      // { b, t, sz, dust, num, full }
  const sz = (k) => ((main && main.sz && main.sz[k]) || 100) / 100;
  function boardState() {
    if (!live()) return ['bad', 'Sem internet'];
    if (!main || Date.now() - (main.seen || 0) > 45000) return ['bad', 'Lousa desconectada'];
    if (main.b === 'send' || sending) return ['busy', 'Enviando para a lousa…'];
    if (main.b === 'ok') return ['ok', 'Lousa conectada'];
    return ['bad', 'Lousa desconectada'];
  }
  function drawState() {
    const [k, txt] = boardState();
    $('#chipBoard').className = 'chip ' + k; $('#dotBoard').className = 'dot ' + k; $('#txtBoard').textContent = txt;
    $$('[data-dot]').forEach(d => d.className = 'dot ' + k);
  }
  setInterval(drawState, 2000);

  // ---------- barra de envio (segue o que a lousa está recebendo) ----------
  let barHide = null;
  function bar(p, state, txt) {
    clearTimeout(barHide);
    $$('.sbar').forEach(b => {
      b.classList.toggle('on', p != null);
      const i = b.querySelector('.t i');
      if (p == null) { b.classList.remove('ok', 'bad'); i.style.transition = 'none'; i.style.width = '0%'; void b.offsetWidth; i.style.transition = ''; return; }
      b.classList.toggle('ok', state === 'ok'); b.classList.toggle('bad', state === 'bad');
      i.style.width = Math.round(p * 100) + '%';
      const sp = b.querySelectorAll('.l span'); if (txt != null) sp[0].textContent = txt; sp[1].textContent = state === 'bad' ? '' : Math.round(p * 100) + '%';
    });
    if (state === 'ok' || state === 'bad') barHide = setTimeout(() => bar(null), state === 'ok' ? 3500 : 6000);
  }

  // ---------- Ably ----------
  let ably = null, ch = null, sending = null, sendT = null;
  const live = () => !!(ably && ably.connection.state === 'connected');
  function readPresence() {
    if (!ch) return;
    ch.presence.get().then(list => {
      const m = (list || []).find(x => x.clientId === 'magico');
      if (m) { main = Object.assign({}, m.data || {}, { seen: Date.now() }); refreshPreview(); } else main = null;
      drawState();
    }).catch(() => {});
  }
  function open() {
    if (!canal) { $('#txtBoard').textContent = 'Abra pelo link que o mágico mandou'; return; }
    if (!window.AblyPubSub) { setTimeout(open, 3000); return; }
    ably = AblyPubSub.createClient({ key: ABLY_KEY, clientId: me, echoMessages: false });
    ch = ably.channels.get('lousa:' + canal);
    ably.connection.on(() => { drawState(); if (live()) readPresence(); });
    ch.presence.subscribe(m => {
      if (m.clientId !== 'magico') return;
      if (m.action === 'leave' || m.action === 'absent') main = null;
      else { main = Object.assign({}, m.data || {}, { seen: Date.now() }); refreshPreview(); }
      drawState();
    });
    ch.subscribe('st', msg => onSt(msg.data || {}));
    setInterval(() => { if (live()) readPresence(); }, 20000);
  }
  function onSt(d) {
    if (!sending || d.id !== sending.id) return;
    clearTimeout(sendT);
    if (d.s === 'got') { bar(0.15, null, 'Chegou no iPhone'); sendT = setTimeout(() => fail('A lousa não respondeu'), 60000); }
    else if (d.s === 'start') { bar(0.2, null, 'Enviando para a lousa…'); sendT = setTimeout(() => fail('A lousa não respondeu'), 60000); }
    else if (d.s === 'prog') { bar(0.2 + 0.8 * Math.min(1, +d.p || 0), null, 'Enviando para a lousa…'); sendT = setTimeout(() => fail('A lousa não respondeu'), 60000); }
    else if (d.s === 'ok') { bar(1, 'ok', 'Chegou na lousa ✓'); showHome(sending.px); sending = null; drawState(); }
    else if (d.s === 'skip') { fail('Trocado por um pedido mais novo'); }
    else if (d.s === 'bad') { fail('Não chegou na lousa' + (d.e ? ' — ' + d.e : '')); }
  }
  function fail(t) { clearTimeout(sendT); bar(1, 'bad', t); sending = null; drawState(); }
  // manda para o iPhone do mágico
  function send(k, d, seed, px) {
    if (!ch) { toast('Abra pelo link que o mágico mandou', true); return; }
    const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
    sending = { id, px }; drawState();
    bar(0.05, null, 'Enviando para o iPhone…');
    clearTimeout(sendT); sendT = setTimeout(() => fail('O iPhone do mágico não respondeu'), 8000);
    try { ch.publish('cmd', { id, k, d, seed }).catch(() => fail('Sem internet')); } catch (e) { fail('Sem internet'); }
  }

  // ---------- prévias (iguais ao que vai para a lousa, nos tamanhos do mágico) ----------
  let suitsReady = Promise.all(Object.entries(window.__LOUSA_SUITS || {}).map(([k, src]) => new Promise(res => {
    if (!src || src.indexOf('data:') !== 0) return res(null);
    const im = new Image(); im.onload = () => res([k, im]); im.onerror = () => res(null); im.src = src;
  }))).then(list => { const o = {}; list.forEach(x => { if (x) o[x[0]] = x[1]; }); if (Object.keys(o).length === 4) Lousa.setSuits(o); });
  if (window.__LOUSA_HAND) Lousa.setHand(window.__LOUSA_HAND);
  const ro = (extra) => Object.assign({ dust: main ? !!main.dust : true, numerals: main ? !!main.num : false, rotate180: false }, extra);
  function drawBoard(canvas, px) { Lousa.drawPreview(canvas, px); const e = canvas.parentNode.querySelector('.empty'); if (e) e.remove(); }
  function emptyBoard(sel) { const cv = $(sel); cv.getContext('2d').clearRect(0, 0, cv.width, cv.height); let d = cv.parentNode.querySelector('.empty'); if (!d) { d = document.createElement('div'); d.className = 'empty'; cv.parentNode.appendChild(d); } d.textContent = 'a prévia aparece aqui'; }
  function showHome(px) { if (px) drawBoard($('#pvHome'), px); }
  let current = null;   // { sel, job: () => [kind, data, extra] }
  async function preview() {
    if (!current) return null;
    await suitsReady;
    const j = current.job(); if (!j) { emptyBoard(current.sel); return null; }
    const res = Lousa.render(j[0], j[1], ro(j[2]));
    drawBoard($(current.sel), res.px); return res.px;
  }
  function refreshPreview() { if (current) preview(); }

  // ---------- navegação ----------
  function go(name) {
    $$('.screen').forEach(s => s.classList.toggle('on', s.id === 's-' + name));
    window.scrollTo(0, 0);
    if (!sending) bar(null);
    current = null;
    if (name === 'carta') { current = cardJob; if (val) preview(); else emptyBoard('#pvCard'); }
    if (name === 'relogio') { hs = ''; ms = ''; stage = 'h'; drawClock(); current = clockJob; emptyBoard('#pvClock'); }
    if (name === 'nascimento') { ds = ''; drawDate(); current = dateJob; emptyBoard('#pvDate'); }
    if (name === 'palavra') { $('#wIn').value = ''; $('#wSend').disabled = true; current = wordJob; emptyBoard('#pvWord'); }
    if (name === 'quadrado') { qs = ''; drawSq(); current = sqJob; emptyBoard('#pvSq'); }
    drawState();
  }
  $$('[data-go]').forEach(b => b.addEventListener('click', () => go(b.dataset.go)));
  function makePad(el, onKey, okLabel) {
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', okLabel || ''].forEach(k => {
      const b = document.createElement('button'); b.textContent = k; if (!k) b.style.visibility = 'hidden';
      b.addEventListener('click', () => onKey(k)); el.appendChild(b);
    });
  }
  function shake(el) { el.classList.remove('err'); void el.offsetWidth; el.classList.add('err'); setTimeout(() => el.classList.remove('err'), 600); }

  // ---------- carta ----------
  let suit = 'C', val = null, cardSeed = rnd();
  const cardJob = { sel: '#pvCard', job: () => val ? ['card', { v: val, s: suit, full: main ? !!main.full : false }, { seed: cardSeed, size: sz('card') }] : null };
  $$('.suit').forEach(b => b.addEventListener('click', () => { suit = b.dataset.s; $$('.suit').forEach(x => x.classList.toggle('sel', x === b)); cardSeed = rnd(); preview(); }));
  ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'].forEach(v => {
    const b = document.createElement('button'); b.textContent = v;
    b.addEventListener('click', () => { val = v; $$('#vals button').forEach(x => x.classList.toggle('sel', x === b)); $('#cSend').disabled = false; cardSeed = rnd(); preview(); });
    $('#vals').appendChild(b);
  });
  $('#cSend').addEventListener('click', async () => { if (!val) return; const px = await preview(); send('card', { v: val, s: suit }, cardSeed, px); cardSeed = rnd(); });

  // ---------- relógio ----------
  let hs = '', ms = '', stage = 'h', clockSeed = rnd();
  const clockJob = { sel: '#pvClock', job: () => (stage === 'm' && ms.length === 2) ? ['clock', { h: +hs, m: +ms }, { seed: clockSeed, size: sz('clock') }] : null };
  function drawClock() {
    $('#hh').textContent = (hs + '--').slice(0, 2); $('#mm').textContent = (ms + '--').slice(0, 2);
    $('#hh').className = stage === 'h' ? 'act' : ''; $('#mm').className = stage === 'm' ? 'act' : '';
    $('#hSend').disabled = !(stage === 'm' && ms.length === 2);
  }
  function commitHour() { const h = parseInt(hs, 10); if (isNaN(h) || h > 23) { shake($('#hDisp')); hs = ''; drawClock(); return; } hs = two(h); stage = 'm'; drawClock(); }
  makePad($('#hPad'), (k) => {
    if (k === '⌫') { if (stage === 'm' && ms.length) ms = ms.slice(0, -1); else if (stage === 'm') { stage = 'h'; hs = ''; } else hs = hs.slice(0, -1); drawClock(); emptyBoard('#pvClock'); return; }
    if (k === '→') { if (stage === 'h' && hs.length) commitHour(); return; }
    if (stage === 'h') { hs += k; if (hs.length === 2 || (hs.length === 1 && k > '2')) commitHour(); else drawClock(); }
    else if (ms.length < 2) { if (ms.length === 0 && k > '5') { shake($('#hDisp')); return; } ms += k; drawClock(); if (ms.length === 2) { clockSeed = rnd(); preview(); } }
  }, '→');
  $('#hSend').addEventListener('click', async () => { const h = +hs, m = +ms; if (!(h <= 23 && m <= 59)) return; const px = await preview(); send('clock', { h, m }, clockSeed, px); clockSeed = rnd(); });

  // ---------- data de nascimento (o iPhone do mágico calcula os dias) ----------
  let ds = '', dateSeed = rnd();
  const dateVal = () => ds.length < 6 ? undefined : Lousa.daysLived(+ds.slice(0, 2), +ds.slice(2, 4), +ds.slice(4, 6));
  const dateJob = { sel: '#pvDate', job: () => typeof dateVal() === 'number' ? ['text', { text: String(dateVal()) }, { seed: dateSeed, size: sz('date') }] : null };
  function drawDate() {
    const p = (ds + '______').slice(0, 6), r = dateVal();
    $('#dDisp').textContent = p.slice(0, 2) + '/' + p.slice(2, 4) + '/' + p.slice(4, 6);
    $('#dDisp').style.color = r === null ? 'var(--bad)' : '';
    $('#dInfo').textContent = r === undefined ? 'Dia, mês e ano (2 dígitos)' : (r === null ? 'Data inválida' : r + ' dias vividos até hoje');
    $('#dSend').disabled = typeof r !== 'number';
  }
  makePad($('#dPad'), (k) => {
    if (k === '⌫') ds = ds.slice(0, -1); else if (k) { if (ds.length >= 6) ds = ''; ds += k; if (ds.length === 6 && dateVal() === null) shake($('#dDisp')); }
    drawDate(); if (typeof dateVal() === 'number') { dateSeed = rnd(); preview(); } else emptyBoard('#pvDate');
  });
  $('#dSend').addEventListener('click', async () => { if (typeof dateVal() !== 'number') return; const px = await preview(); send('date', { d: +ds.slice(0, 2), m: +ds.slice(2, 4), y: +ds.slice(4, 6) }, dateSeed, px); dateSeed = rnd(); });

  // ---------- palavra ----------
  let wordSeed = rnd();
  const wordTxt = () => $('#wIn').value.trim().replace(/\s+/g, ' ');
  const wordJob = { sel: '#pvWord', job: () => wordTxt() ? ['text', { text: wordTxt() }, { seed: wordSeed, size: sz('word') }] : null };
  $('#wIn').addEventListener('input', () => { $('#wSend').disabled = !wordTxt(); preview(); });
  async function sendWord() { const t = wordTxt(); if (!t) return; const px = await preview(); send('word', { t }, wordSeed, px); wordSeed = rnd(); }
  $('#wSend').addEventListener('click', sendWord);
  $('#wForm').addEventListener('submit', (e) => { e.preventDefault(); $('#wIn').blur(); sendWord(); });

  // ---------- quadrado mágico ----------
  let qs = '', sqSeed = rnd();
  const sqJob = { sel: '#pvSq', job: () => { const n = parseInt(qs, 10); return n >= 34 ? ['square', { n }, { seed: sqSeed, size: sz('sq'), line: sz('sqLine') }] : null; } };
  function drawSq() { const n = parseInt(qs, 10), ok = n >= 34; $('#qDisp').textContent = qs || '—'; $('#qDisp').style.color = qs && !ok ? 'var(--bad)' : ''; $('#qSend').disabled = !ok; if (current === sqJob) preview(); }
  makePad($('#qPad'), (k) => { if (k === '⌫') qs = qs.slice(0, -1); else if (k && qs.length < 5) { qs += k; sqSeed = rnd(); } if (qs === '0') qs = ''; drawSq(); });
  $('#qSend').addEventListener('click', async () => { const n = parseInt(qs, 10); if (!(n >= 34)) { toast('O número precisa ser 34 ou mais', true); return; } const px = await preview(); send('square', { n }, sqSeed, px); sqSeed = rnd(); });

  // ---------- limpar ----------
  $('#btnClear').addEventListener('click', () => { const px = Lousa.render('clear', {}, ro({})).px; send('clear', {}, rnd(), px); });

  drawState(); drawClock(); drawDate();
  open();
})();
