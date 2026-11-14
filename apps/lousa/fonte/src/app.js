// ===== Lousa v1.1 (app nativo) — telas e envio =====
(function () {
  const VER = '1.1.2';
  const NATIVO = !!window.__NATIVE_APP__;
  const nat = (name, v) => { try { window.webkit.messageHandlers[name].postMessage(v); } catch (e) {} };
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  // ---------- registro ----------
  const logLines = [];
  function log(t) {
    const d = new Date();
    const line = d.toTimeString().slice(0, 8) + ' ' + t;
    logLines.push(line); if (logLines.length > 300) logLines.shift();
    const el = $('#log'); if (el) { el.textContent = logLines.join('\n'); el.scrollTop = el.scrollHeight; }
  }
  window.addEventListener('error', (e) => log('ERRO: ' + e.message));

  // ---------- opções (guardadas no iPhone) ----------
  const DEF = { dust: true, numerals: false, rotate180: false, full: false, onConnect: 'keep', cardSize: 100, dateSize: 100, clockSize: 100, wordSize: 100, sqSize: 100, sqLine: 100, menu: 'txt',
    bgOn: true, padOn: false, padMode: 'square', rx: false, dz: true, camStyle: 'desenho', gotSecs: 5 };
  let opt = Object.assign({}, DEF);
  try { Object.assign(opt, JSON.parse(localStorage.getItem('lousa.opt') || '{}')); } catch (e) {}
  function saveOpt() { try { localStorage.setItem('lousa.opt', JSON.stringify(opt)); } catch (e) {} }
  function bindSw(id, key) { const el = $(id); el.checked = !!opt[key]; el.addEventListener('change', () => { opt[key] = el.checked; saveOpt(); }); }
  function drawSeg() { $$('#segConn button').forEach(b => b.classList.toggle('sel', b.dataset.v === opt.onConnect)); }
  $$('#segConn button').forEach(b => b.addEventListener('click', () => { opt.onConnect = b.dataset.v; saveOpt(); drawSeg(); }));
  drawSeg();
  function drawMenu() { $$('#segMenu button').forEach(b => b.classList.toggle('sel', b.dataset.v === opt.menu)); document.body.classList.toggle('soicones', opt.menu === 'ico'); }
  $$('#segMenu button').forEach(b => b.addEventListener('click', () => { opt.menu = b.dataset.v; saveOpt(); drawMenu(); }));
  drawMenu();
  $$('.sec').forEach(b => b.addEventListener('click', () => {          // seções das Opções: abre uma, fecha as outras
    const open = !b.classList.contains('open');
    $$('.sec').forEach(x => { x.classList.remove('open'); $('#sec-' + x.dataset.sec).classList.remove('open'); });
    if (open) { b.classList.add('open'); $('#sec-' + b.dataset.sec).classList.add('open'); }
  }));
  bindSw('#optDust', 'dust'); bindSw('#optNum', 'numerals'); bindSw('#optRot', 'rotate180'); bindSw('#optFull', 'full');
  ['#optDust', '#optNum', '#optFull'].forEach(id => $(id).addEventListener('change', () => presence()));
  // segmentos genéricos (opção com botões)
  function bindSeg(sel, key, after) {
    const draw = () => $$(sel + ' button').forEach(b => b.classList.toggle('sel', String(opt[key]) === b.dataset.v));
    $$(sel + ' button').forEach(b => b.addEventListener('click', () => { opt[key] = typeof DEF[key] === 'number' ? +b.dataset.v : b.dataset.v; saveOpt(); draw(); if (after) after(); }));
    draw();
  }

  // ---------- navegação ----------
  function go(name) {
    $$('.screen').forEach(s => s.classList.toggle('on', s.id === 's-' + name));
    window.scrollTo(0, 0);
    if (!running) bar(null);                       // trocou de tela: barra zerada (só continua se ainda estiver enviando)
    if (name !== 'inicio' && name !== 'opcoes') emptyBoard(name);   // lousa de cima vazia até ter prévia
    if (name === 'relogio') resetClock();
    if (name === 'nascimento') resetDate();
    if (name === 'palavra') { $('#wIn').value = ''; $('#wSend').disabled = true; }
    if (name === 'quadrado') { qs = ''; drawSqUI(); }
    if (name === 'carta' && val) previewCard();
    if (name === 'treino') trainOpen(); else trainClose();
  }
  $$('[data-go]').forEach(b => b.addEventListener('click', () => go(b.dataset.go)));

  // ---------- avisos ----------
  let toastT = null;
  function toast(msg, bad) {
    const t = $('#toast'); t.textContent = msg; t.className = 'on' + (bad ? ' bad' : '');
    clearTimeout(toastT); toastT = setTimeout(() => t.className = '', bad ? 4000 : 2000);
  }
  // barra de envio embaixo da lousa (carta, relógio, data e escrita)
  let barTxt = '', barHide = null;
  function bar(p, state, txt) {
    clearTimeout(barHide);
    if (txt != null) barTxt = txt;
    $$('.sbar').forEach(b => {
      b.classList.toggle('on', p != null);
      if (p == null) { b.classList.remove('ok', 'bad'); b.querySelector('.t i').style.transition = 'none'; b.querySelector('.t i').style.width = '0%'; void b.offsetWidth; b.querySelector('.t i').style.transition = ''; }
      b.classList.toggle('ok', state === 'ok'); b.classList.toggle('bad', state === 'bad');
      if (p == null) return;
      b.querySelector('.t i').style.width = Math.round(p * 100) + '%';
      const sp = b.querySelectorAll('.l span'); sp[0].textContent = barTxt; sp[1].textContent = Math.round(p * 100) + '%';
    });
    if (state === 'ok' || state === 'bad') barHide = setTimeout(() => bar(null), state === 'ok' ? 3000 : 5000);
  }

  // ---------- lousa ----------
  const board = new LousaBLE.Board(log);
  if (NATIVO) board.dataMode = 'fast';   // no app, o próprio iPhone controla o ritmo (sem perder dados)
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  let stKind = '', lastOkAt = 0;
  function setStatus(kind, text) {
    stKind = kind; if (kind === 'ok') lastOkAt = Date.now();
    setTimeout(() => { presence(); updateCam(); }, 0);
    $('#chipBoard').className = 'chip' + (kind ? ' ' + kind : '');
    const d = $('#dotBoard'); d.className = 'dot' + (kind ? ' ' + kind : '');
    $('#txtBoard').textContent = text;
    $('#optState').textContent = text;
    $('#btnConn').textContent = board.connected() ? 'Desconectar' : 'Conectar';
    if (board.device) $('#optName').textContent = board.device.name || 'Lousa';
  }
  let manualOff = false, connP = null, needPick = false, reconnT = null, searchStart = 0;
  // "primeira conexão": vale por apresentação (o Bluefy recarrega a página ao bloquear o iPhone,
  // então só conta como nova se a lousa ficou mais de 15 min sem uso)
  function markUse() { try { localStorage.setItem('lousa.lastUse', String(Date.now())); } catch (e) {} }
  // no app nativo: só a 1ª conexão depois de abrir o app (o app fica aberto durante a apresentação)
  let connectedThisLaunch = false;
  function isFirstConnection() {
    if (NATIVO) return !connectedThisLaunch;
    let last = 0; try { last = +localStorage.getItem('lousa.lastUse') || 0; } catch (e) {}
    return Date.now() - last > 15 * 60 * 1000;
  }
  function afterConnect(first) {
    setStatus('ok', 'Lousa conectada');
    if (first && !connectedThisLaunch && opt.onConnect === 'clear') { log('Primeira conexão desde que o app abriu: limpando a lousa'); clearBoard(); }
    connectedThisLaunch = true;
    markUse();
  }
  // conecta (ou reconecta). interactive = você tocou no botão
  function ensure(interactive) {
    if (board.connected()) return Promise.resolve(true);
    if (connP) return connP;
    connP = (async () => {
      if (!navigator.bluetooth) { toast('Sem Bluetooth neste aparelho', true); return false; }
      const first = isFirstConnection();
      try {
        if (!board.device || (interactive && needPick)) {
          if (!interactive) return false;
          setStatus('busy', 'Conectando…');
          await board.pick(); needPick = false;
          afterConnect(first); return true;
        }
        // lousa dormindo demora a responder: fica esperando e tentando sozinho, sem desistir (como o MysterSmith)
        setStatus('busy', 'Procurando a lousa…');
        const t0 = Date.now(); searchStart = t0; let n = 0; const gen = connGen;
        while (!manualOff && !board.connected()) {
          n++;
          try {
            await board.reconnect(60000);
            log('Conectou em ' + ((Date.now() - t0) / 1000).toFixed(1) + ' s (' + n + (n > 1 ? ' tentativas)' : ' tentativa)'));
            if (gen === connGen) afterConnect(first); return true;
          } catch (e) {
            if (board.connected()) return true;              // conectou pela lista enquanto esperava
            log('Tentativa ' + n + ' sem resposta (' + ((Date.now() - t0) / 1000).toFixed(0) + ' s): ' + LousaBLE.errStr(e));
            if (document.visibilityState !== 'visible') { setStatus('bad', 'Toque para reconectar'); return false; }   // volta a procurar quando o app voltar à tela
            await sleep(500);
            await board.refresh();                         // lembrança nova da lousa
            const heard = await board.listen(n < 5 ? 6000 : 12000);   // espera o sinal dela antes de tentar de novo
            if (heard) log('Ouvi a lousa — conectando');
          }
        }
        if (board.connected()) { if (gen === connGen) afterConnect(first); return true; }
        setStatus('', 'Conectar lousa');
        return false;
      } catch (e) {
        log('Falha ao conectar: ' + LousaBLE.errStr(e));
        setStatus(board.device ? 'bad' : '', board.device ? 'Toque para reconectar' : 'Conectar lousa');
        if (!/cancel/i.test(LousaBLE.errStr(e))) toast('Não conectou: ' + LousaBLE.errStr(e), true);
        return false;
      }
    })().finally(() => { connP = null; });
    return connP;
  }
  function autoReconnect(delay) {
    clearTimeout(reconnT);
    if (manualOff || !board.device || board.connected()) return;
    setStatus('busy', 'Reconectando…');
    reconnT = setTimeout(() => { if (!running) ensure(false); }, delay == null ? 1200 : delay);
  }
  // a lousa se desliga sozinha depois de cada imagem: o app reconecta sozinho
  board.onDisconnect = () => {
    if (manualOff) { setStatus('', 'Conectar lousa'); return; }
    if (!running) autoReconnect();
  };
  // toque em "Conectar": abre a lista NA HORA (mesmo se o app já estiver procurando sozinho)
  let connGen = 0;
  async function connectByTap() {
    if (board.connected()) return;
    if (!navigator.bluetooth) { toast('Sem Bluetooth neste aparelho', true); return; }
    manualOff = false; connGen++;
    const first = isFirstConnection();
    setStatus('busy', 'Conectando…');
    try { await board.pick(); needPick = false; afterConnect(first); }
    catch (e) {
      const m = LousaBLE.errStr(e);
      log('Conectar: ' + m);
      if (/cancel/i.test(m)) { setStatus(board.connected() ? 'ok' : '', board.connected() ? 'Lousa conectada' : 'Conectar lousa'); return; }
      if (board.device) ensure(false);                       // escolheu mas ela está dormindo: fica esperando
      else { setStatus('', 'Conectar lousa'); toast('Não conectou: ' + m, true); }
    }
  }
  $('#chipBoard').addEventListener('click', connectByTap);
  $('#btnConn').addEventListener('click', () => {
    if (board.connected()) { manualOff = true; try { board.device.gatt.disconnect(); } catch (e) {} setStatus('', 'Conectar lousa'); }
    else connectByTap();
  });
  // voltou do segundo plano: reconecta
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && board.device && !board.connected() && !manualOff) { log('App voltou para a tela: reconectando'); autoReconnect(300); }
  });

  // ---------- desenhar e enviar ----------
  const pvs = $$('.pv');
  let hasPreview = false;
  // tela principal: última enviada · outras telas: prévia do que vai ser enviado
  function showPreview(px) {
    const c = $('#s-inicio .pv'); Lousa.drawPreview(c, px);
    const e = $('#s-inicio .board .empty'); if (e) e.remove();
  }
  function drawBoard(canvas, px) {
    Lousa.drawPreview(canvas, px);
    const e = canvas.parentNode.querySelector('.empty'); if (e) e.remove();
  }
  function emptyBoard(name) {
    const sc = $('#s-' + name); if (!sc) return;
    const cv = sc.querySelector('.board canvas'); if (!cv) return;
    cv.getContext('2d').clearRect(0, 0, cv.width, cv.height);
    let d = sc.querySelector('.board .empty');
    if (!d) { d = document.createElement('div'); d.className = 'empty'; cv.parentNode.appendChild(d); }
    d.textContent = 'a prévia aparece aqui';
  }
  let fontsReady = null;
  let waitFonts = function () {
    if (!fontsReady) fontsReady = (document.fonts ? Promise.race([document.fonts.load('500 100px "Caveat"'), new Promise(r => setTimeout(r, 2500))]) : Promise.resolve()).catch(() => {});
    return fontsReady;
  };
  waitFonts();
  // ---------- sua letra e seus naipes (embutidos no app) ----------
  const VARS_N = 3;
  function redoList() { try { return JSON.parse(localStorage.getItem('lousa.redo') || '[]'); } catch (e) { return []; } }
  function applyHand() {
    const base = window.__LOUSA_HAND; if (!base) return;
    const g = Object.assign({}, base);
    let mine = {}; try { mine = (JSON.parse(localStorage.getItem('lousa.myfont') || '{}').g) || {}; } catch (e) {}
    redoList().forEach(c => {                       // caracteres que você refez no app substituem os embutidos
      const vs = (mine[c] || []).filter(Boolean);
      if (vs.length >= VARS_N) g[c] = vs.map(v => v.filter(st => !st.every(p => p[1] < 0.05)));
    });
    Lousa.setHand(g);
  }
  applyHand();
  const suitsReady = Promise.all(Object.entries(window.__LOUSA_SUITS || {}).map(([k, src]) => new Promise(res => {
    if (!src || src.indexOf('data:') !== 0) return res(null);
    const im = new Image(); im.onload = () => res([k, im]); im.onerror = () => res(null); im.src = src;
  }))).then(list => { const o = {}; list.forEach(x => { if (x) o[x[0]] = x[1]; }); if (Object.keys(o).length === 4) Lousa.setSuits(o); else log('Naipes desenhados não carregaram — usando os padrão'); });
  const _wf = waitFonts; waitFonts = () => Promise.all([_wf(), suitsReady]);
  let pending = null, running = false, underPx = null;
  function clearBoard(cb) { send('clear', {}, 'lousa limpa', null, cb, ''); }
  // cb(estado, p): 'start' | 'prog' (0..1) | 'ok' | 'bad' | 'skip'
  async function send(kind, data, label, extra, cb, short) {
    await waitFonts();
    const t0 = performance.now();
    const ro = Object.assign({ dust: opt.dust, numerals: opt.numerals, rotate180: opt.rotate180 }, extra || {});
    if (kind !== 'clear' && underPx && opt.dust) ro.under = underPx;   // 1º envio depois de limpar: mesmas marcas por baixo
    const res = Lousa.render(kind, data, ro);
    underPx = kind === 'clear' && opt.dust ? res.px : null;
    showPreview(res.px);
    const comp = QLZ.boardCompress(res.bytes);
    log('Desenho "' + label + '" pronto em ' + Math.round(performance.now() - t0) + ' ms (' + comp.length + ' bytes)');
    if (pending && pending.cb) pending.cb('skip');
    pending = { comp, label, cb, short: short == null ? label : short };
    incoming(pending.short);
    if (!running) runQueue();
  }
  async function runQueue() {
    running = true;
    clearTimeout(reconnT);
    while (pending) {
      const job = pending; pending = null;
      const t0 = performance.now();
      let okSent = false, lastErr = null, lastP = -1;
      const cb = job.cb || (() => {});
      cb('start');
      for (let a = 1; a <= 3 && !okSent; a++) {
        if (pending) break;                       // chegou um pedido mais novo: manda o novo
        try {
          if (!board.connected()) {
            bar(0, null, 'Esperando a lousa acordar…');
            const ok = await ensure(false);
            if (!ok) throw new Error('Lousa não conectada');
          }
          setStatus('busy', a > 1 ? 'Reenviando… (' + a + '/3)' : 'Enviando…');
          bar(0, null, (a > 1 ? 'Reenviando ' : 'Enviando ') + job.label + '…');
          let live = true;                           // depois do fim, avisos atrasados do Bluetooth não mexem mais na barra
          try { await board.sendCompressed(job.comp, (p) => { if (!live) return; bar(p); const q = Math.floor(p * 5); if (q > lastP && q < 5) { lastP = q; cb('prog', p); } }); } finally { live = false; }
          okSent = true;
        } catch (e) {
          lastErr = e;
          log('Tentativa ' + a + '/3 falhou: ' + LousaBLE.errStr(e));
          if (board.dataMode !== 'resp' && /parou de pedir|recusou/.test(LousaBLE.errStr(e))) { board.dataMode = 'resp'; log('Voltando para o envio seguro (mais lento)'); }
          if (a < 3) { bar(0, 'bad', 'Não enviou — tentando de novo'); await sleep(1000); }
        }
      }
      if (okSent) {
        bar(1, 'ok', 'Enviado ✓');
        $('#lastTxt').textContent = 'Última enviada: ' + job.label;
        log('Enviado em ' + ((performance.now() - t0) / 1000).toFixed(1) + ' s');
        markUse();
        cb('ok'); arrived(job.short);
      } else if (lastErr && !pending) {
        bar(1, 'bad', 'Não enviou');
        toast('Não enviou "' + job.label + '": ' + LousaBLE.errStr(lastErr), true);
        cb('bad', LousaBLE.errStr(lastErr)); camFlash('fail');
      } else cb('skip');
    }
    running = false;
    if (board.connected()) setStatus('ok', 'Lousa conectada');
    else if (board.device && !manualOff) autoReconnect(800);
    else setStatus(board.device ? 'bad' : '', board.device ? 'Toque para reconectar' : 'Conectar lousa');
  }

  // ---------- carta: naipe, valor, tamanho e Enviar ----------
  let suit = 'C', val = null, cardSeed = 1;
  const newSeed = () => { cardSeed = (Math.random() * 1e9) >>> 0; };
  function drawCardUI() {
    $('#cSend').disabled = !val;
    $('#lastCard').textContent = val ? 'Pronto: ' + Lousa.cardName(val, suit) : 'Escolha o naipe e o valor';
    $('#cSizeV').textContent = opt.cardSize + '%';
    $('#cSize').value = opt.cardSize;
  }
  // prévia ao vivo na lousa de cima (é exatamente o que vai para a lousa)
  let pvBusy = false, pvAgain = false;
  async function previewCard() {
    if (!val) return;
    if (pvBusy) { pvAgain = true; return; }
    pvBusy = true;
    await waitFonts();
    do {
      pvAgain = false;
      const ro = { dust: opt.dust, rotate180: false, seed: cardSeed, size: opt.cardSize / 100 };
      if (underPx && opt.dust) ro.under = underPx;
      const res = Lousa.render('card', { v: val, s: suit, full: opt.full }, ro);
      drawBoard($('#pvCard'), res.px);
      await new Promise(r => requestAnimationFrame(r));
    } while (pvAgain);
    pvBusy = false;
  }
  $$('.suit').forEach(b => b.addEventListener('click', () => {
    suit = b.dataset.s; $$('.suit').forEach(x => x.classList.toggle('sel', x === b)); newSeed(); drawCardUI(); previewCard();
  }));
  ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'].forEach(v => {
    const b = document.createElement('button'); b.textContent = v;
    b.addEventListener('click', () => { val = v; $$('#vals button').forEach(x => x.classList.toggle('sel', x === b)); newSeed(); drawCardUI(); previewCard(); });
    $('#vals').appendChild(b);
  });
  $('#cSize').addEventListener('input', () => { opt.cardSize = +$('#cSize').value; $('#cSizeV').textContent = opt.cardSize + '%'; previewCard(); });
  $('#cSize').addEventListener('change', () => { saveOpt(); presence(); });
  $('#optFull').addEventListener('change', () => previewCard());
  $('#cSend').addEventListener('click', () => {
    if (!val) return;
    const name = Lousa.cardName(val, suit);
    send('card', { v: val, s: suit, full: opt.full }, name, { seed: cardSeed, size: opt.cardSize / 100 }, null, cardShort(val, suit));
    newSeed();
  });
  $('#btnClear').addEventListener('click', () => clearBoard());

  // ---------- teclados numéricos ----------
  function makePad(el, onKey, okLabel) {
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', okLabel || ''].forEach(k => {
      const b = document.createElement('button'); b.textContent = k;
      if (!k) b.style.visibility = 'hidden';
      b.addEventListener('click', () => onKey(k));
      el.appendChild(b);
    });
  }
  function shake(el) { el.classList.remove('err'); void el.offsetWidth; el.classList.add('err'); setTimeout(() => el.classList.remove('err'), 600); }

  // prévia ao vivo genérica: get() devolve [tipo, dados, opções] ou null
  function makePreview(get, canvasSel) {
    let busy = false, again = false;
    return async function run() {
      if (busy) { again = true; return; }
      busy = true; await waitFonts();
      do {
        again = false;
        const job = get();
        if (job) {
          const ro = Object.assign({ dust: opt.dust }, job[2]);
          if (underPx && opt.dust) ro.under = underPx;
          drawBoard($(canvasSel), Lousa.render(job[0], job[1], ro).px);
        }
        await new Promise(r => requestAnimationFrame(r));
      } while (again);
      busy = false;
    };
  }
  function bindSize(sel, key, onChange) {
    const el = $(sel), lab = $(sel + 'V');
    el.value = opt[key]; if (lab) lab.textContent = opt[key] + '%';
    el.addEventListener('input', () => { opt[key] = +el.value; if (lab) lab.textContent = opt[key] + '%'; onChange(); });
    el.addEventListener('change', () => { saveOpt(); presence(); });
  }

  // ---------- relógio: hora primeiro, depois minutos ----------
  let hs = '', ms = '', stage = 'h';
  function resetClock() { hs = ''; ms = ''; stage = 'h'; drawClockUI(); }
  function drawClockUI() {
    $('#hh').textContent = (hs + '--').slice(0, 2);
    $('#mm').textContent = (ms + '--').slice(0, 2);
    $('#hh').className = stage === 'h' ? 'act' : '';
    $('#mm').className = stage === 'm' ? 'act' : '';
    $('#hHint').textContent = stage === 'h' ? 'Digite a hora (1 h ou 2 h: digite e toque →)' : (ms.length < 2 ? 'Digite os minutos' : 'Confira e toque em Enviar');
    $('#hSend').disabled = !(stage === 'm' && ms.length === 2);
  }
  function commitHour() {
    const h = parseInt(hs, 10);
    if (isNaN(h) || h > 23) { shake($('#hDisp')); hs = ''; drawClockUI(); return; }
    hs = String(h).padStart(2, '0'); stage = 'm'; drawClockUI();
  }
  makePad($('#hPad'), (k) => {
    if (k === '⌫') {
      if (stage === 'm' && ms.length) ms = ms.slice(0, -1);
      else if (stage === 'm') { stage = 'h'; hs = hs.slice(0, 1) === '0' ? '' : hs; hs = ''; }
      else hs = hs.slice(0, -1);
      drawClockUI(); return;
    }
    if (k === '→') { if (stage === 'h' && hs.length) commitHour(); return; }
    if (stage === 'h') {
      hs += k;
      if (hs.length === 2 || (hs.length === 1 && k > '2')) commitHour(); else drawClockUI();
    } else if (ms.length < 2) {
      if (ms.length === 0 && k > '5') { shake($('#hDisp')); return; }
      ms += k; drawClockUI();
      if (ms.length === 2) { clockSeed = (Math.random() * 1e9) >>> 0; previewClock(); }
    }
  }, '→');
  let clockSeed = 1;
  const previewClock = makePreview(() => {
    if (!(stage === 'm' && ms.length === 2)) return null;
    return ['clock', { h: parseInt(hs, 10), m: parseInt(ms, 10) }, { numerals: opt.numerals, seed: clockSeed, size: opt.clockSize / 100 }];
  }, '#pvClock');
  bindSize('#kSize', 'clockSize', previewClock);
  $('#hSend').addEventListener('click', () => {
    const h = parseInt(hs, 10), m = parseInt(ms, 10);
    if (isNaN(h) || isNaN(m) || h > 23 || m > 59) { shake($('#hDisp')); return; }
    send('clock', { h, m }, hs + ':' + ms, { seed: clockSeed, size: opt.clockSize / 100 }, null, h + ':' + ms);
    clockSeed = (Math.random() * 1e9) >>> 0;
  });

  // ---------- data de nascimento ----------
  let ds = '';
  function resetDate() { ds = ''; drawDateUI(); }
  function dateResult() {
    if (ds.length < 6) return undefined;
    return Lousa.daysLived(+ds.slice(0, 2), +ds.slice(2, 4), +ds.slice(4, 6));
  }
  function drawDateUI() {
    const p = (ds + '______').slice(0, 6);
    $('#dDisp').textContent = p.slice(0, 2) + '/' + p.slice(2, 4) + '/' + p.slice(4, 6);
    const r = dateResult();
    $('#dDisp').style.color = r === null ? 'var(--bad)' : '';
    $('#dHint').textContent = r === undefined ? 'Digite dia, mês e ano (2 dígitos)' : (r === null ? 'Data inválida' : r + ' dias vividos até hoje');
    $('#dSend').disabled = !(typeof r === 'number');
  }
  makePad($('#dPad'), (k) => {
    if (k === '⌫') ds = ds.slice(0, -1);
    else if (k) { if (ds.length >= 6) ds = ''; ds += k; if (ds.length === 6 && dateResult() === null) shake($('#dDisp')); }
    drawDateUI();
    if (typeof dateResult() === 'number') { dateSeed = (Math.random() * 1e9) >>> 0; previewDate(); }
  });
  let dateSeed = 1, dBusy = false, dAgain = false;
  async function previewDate() {
    const r = dateResult(); if (typeof r !== 'number') return;
    if (dBusy) { dAgain = true; return; }
    dBusy = true; await waitFonts();
    do {
      dAgain = false;
      const ro = { dust: opt.dust, seed: dateSeed, size: opt.dateSize / 100 };
      if (underPx && opt.dust) ro.under = underPx;
      const res = Lousa.render('text', { text: String(dateResult()) }, ro);
      drawBoard($('#pvDate'), res.px);
      await new Promise(rr => requestAnimationFrame(rr));
    } while (dAgain);
    dBusy = false;
  }
  $('#dSize').value = opt.dateSize; $('#dSizeV').textContent = opt.dateSize + '%';
  $('#dSize').addEventListener('input', () => { opt.dateSize = +$('#dSize').value; $('#dSizeV').textContent = opt.dateSize + '%'; previewDate(); });
  $('#dSize').addEventListener('change', () => { saveOpt(); presence(); });
  $('#dSend').addEventListener('click', () => {
    const r = dateResult(); if (typeof r !== 'number') return;
    send('text', { text: String(r) }, r + ' dias', { seed: dateSeed, size: opt.dateSize / 100 }, null, String(r));
    dateSeed = (Math.random() * 1e9) >>> 0;
  });

  // ---------- palavra (teclado do iPhone, sua letra) ----------
  let wordSeed = 1;
  const wordTxt = () => $('#wIn').value.trim().replace(/\s+/g, ' ');
  const previewWord = makePreview(() => wordTxt() ? ['text', { text: wordTxt() }, { seed: wordSeed, size: opt.wordSize / 100 }] : null, '#pvWord');
  bindSize('#wSize', 'wordSize', previewWord);
  $('#wIn').addEventListener('input', () => { $('#wSend').disabled = !wordTxt(); if (wordTxt()) previewWord(); else emptyBoard('palavra'); });
  function sendWord() {
    const t = wordTxt(); if (!t) return;
    send('text', { text: t }, t, { seed: wordSeed, size: opt.wordSize / 100 });
    wordSeed = (Math.random() * 1e9) >>> 0;
  }
  $('#wSend').addEventListener('click', sendWord);
  $('#wForm').addEventListener('submit', (e) => { e.preventDefault(); $('#wIn').blur(); sendWord(); });   // "Enviar" do teclado do iPhone

  // ---------- quadrado mágico ----------
  let qs = '', sqSeed = 1;
  function drawSqUI() {
    const n = parseInt(qs, 10);
    $('#qDisp').textContent = qs || '—';
    const ok = n >= 34;
    $('#qDisp').style.color = qs && !ok ? 'var(--bad)' : '';
    $('#qSend').disabled = !ok;
    if (ok) previewSq(); else emptyBoard('quadrado');
  }
  const previewSq = makePreview(() => {
    const n = parseInt(qs, 10); if (!(n >= 34)) return null;
    return ['square', { n }, { seed: sqSeed, size: opt.sqSize / 100, line: opt.sqLine / 100 }];
  }, '#pvSq');
  makePad($('#qPad'), (k) => {
    if (k === '⌫') qs = qs.slice(0, -1);
    else if (k && qs.length < 5) { qs += k; sqSeed = (Math.random() * 1e9) >>> 0; }
    if (qs === '0') qs = '';
    drawSqUI();
  });
  bindSize('#qSize', 'sqSize', previewSq);
  bindSize('#qLine', 'sqLine', previewSq);
  $('#qSend').addEventListener('click', () => {
    const n = parseInt(qs, 10);
    if (!(n >= 34)) { toast('O número precisa ser 34 ou mais', true); return; }
    const q = Lousa.magicSquare(n, Lousa.rng(sqSeed));
    if (!Lousa.checkSquare(q, n)) { toast('Erro na conta do quadrado — não enviado', true); log('Quadrado ' + n + ' não fechou: ' + JSON.stringify(q)); return; }
    log('Quadrado ' + n + ' conferido: todas as somas = ' + n);
    send('square', { n }, 'quadrado ' + n, { seed: sqSeed, size: opt.sqSize / 100, line: opt.sqLine / 100 }, null, String(n));
    sqSeed = (Math.random() * 1e9) >>> 0;
  });

  // ---------- escrita manual ----------
  const pad = $('#pad'); const pctx = pad.getContext('2d');
  let strokes = [], cur = null, dpr = 1, pattern = null;
  function chalkPattern() {
    const c = document.createElement('canvas'); c.width = c.height = 64;
    const x = c.getContext('2d'); const img = x.createImageData(64, 64);
    for (let i = 0; i < 64 * 64; i++) { const on = Math.random() < 0.78; const v = on ? 236 : 20; img.data[i * 4] = v; img.data[i * 4 + 1] = v; img.data[i * 4 + 2] = on ? 228 : 22; img.data[i * 4 + 3] = 255; }
    x.putImageData(img, 0, 0); return pctx.createPattern(c, 'repeat');
  }
  // moldura do tamanho da lousa (3:2): o que fica dentro dela sai igual na lousa
  let fr = { x: 0, y: 0, w: 960, h: 640 }, lineW = 9;
  function sizePad() {
    dpr = window.devicePixelRatio || 1;
    padR = pad.getBoundingClientRect();                       // onde a área de desenho está de verdade na tela
    const vw = padR.width, vh = padR.height;
    pad.width = Math.round(vw * dpr); pad.height = Math.round(vh * dpr);
    const tb = $('#escrita .tools').getBoundingClientRect().bottom - padR.top + 8, m = 10;
    let h = vh - tb - m, w = h * 1.5;
    if (w > vw - 2 * m) { w = vw - 2 * m; h = w / 1.5; }
    fr = { x: (vw - w) / 2, y: tb + (vh - tb - m - h) / 2, w, h };
    const er = $('#escrita').getBoundingClientRect();
    const f = $('#frame'); f.style.left = (fr.x + padR.left - er.left) + 'px'; f.style.top = (fr.y + padR.top - er.top) + 'px'; f.style.width = fr.w + 'px'; f.style.height = fr.h + 'px';
    lineW = 15 * fr.w / 960;                        // mesma grossura que vai sair na lousa
    pattern = chalkPattern(); redrawPad();
    const vv = window.visualViewport;
    log('Escrita: tela ' + window.innerWidth + '×' + window.innerHeight + ' · área ' + Math.round(padR.left) + ',' + Math.round(padR.top) + ' ' + Math.round(vw) + '×' + Math.round(vh) +
      (vv ? ' · visível ' + Math.round(vv.offsetLeft) + ',' + Math.round(vv.offsetTop) + ' ' + Math.round(vv.width) + '×' + Math.round(vv.height) : '') + ' · dpr ' + dpr);
  }
  // posição do dedo DENTRO da área de desenho (antes usava a tela inteira: o traço saía deslocado)
  let padR = { left: 0, top: 0, width: 1, height: 1 }, tapLogged = 0;
  function padPt(e) {
    padR = pad.getBoundingClientRect();
    return { x: e.clientX - padR.left, y: e.clientY - padR.top };
  }
  function redrawPad() {
    pctx.setTransform(1, 0, 0, 1, 0, 0);
    pctx.fillStyle = '#0E0F11'; pctx.fillRect(0, 0, pad.width, pad.height);
    pctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (fontMode) {                                  // linhas-guia (não vão para a lousa)
      pctx.save(); pctx.strokeStyle = 'rgba(242,237,228,.22)'; pctx.lineWidth = 1; pctx.setLineDash([6, 6]);
      [0.2, 0.45, 0.75].forEach(f => { const y = fr.y + fr.h * f; pctx.beginPath(); pctx.moveTo(fr.x + 8, y); pctx.lineTo(fr.x + fr.w - 8, y); pctx.stroke(); });
      pctx.restore();
    }
    pctx.strokeStyle = pattern; pctx.fillStyle = pattern;
    pctx.lineWidth = lineW; pctx.lineCap = 'round'; pctx.lineJoin = 'round';
    strokes.forEach(st => {
      if (st.length === 1) { pctx.beginPath(); pctx.arc(st[0].x, st[0].y, lineW / 2, 0, 7); pctx.fill(); return; }
      pctx.beginPath(); pctx.moveTo(st[0].x, st[0].y);
      for (let i = 1; i < st.length; i++) pctx.lineTo(st[i].x, st[i].y);
      pctx.stroke();
    });
  }
  pad.addEventListener('pointerdown', (e) => {
    if (e.target !== pad || e.clientY < $('#escrita .tools').getBoundingClientRect().bottom + 4) return;
    e.preventDefault(); pad.setPointerCapture(e.pointerId); cur = [padPt(e)];
    if (tapLogged < 2) { tapLogged++; log('Toque: dedo ' + Math.round(e.clientX) + ',' + Math.round(e.clientY) + ' → traço ' + Math.round(cur[0].x) + ',' + Math.round(cur[0].y)); } strokes.push(cur); redrawPad(); });
  pad.addEventListener('pointermove', (e) => { if (!cur) return; e.preventDefault(); const evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e]; evs.forEach(ev => cur.push(padPt(ev))); redrawPad(); });
  const end = () => { cur = null; };
  pad.addEventListener('pointerup', end); pad.addEventListener('pointercancel', end);
  // ---------- criar minha letra (3 de cada, guardado no iPhone) ----------
  const FONT_CHARS = [...'0123456789:', ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ', ...'abcdefghijklmnopqrstuvwxyz', ...'ÁÉÍÓÚÂÊÔÃÕÀÇ', ...'áéíóúâêôãõàç', ...'?!-/'];
  const VARS = 3;
  let fontMode = false, myFont = {};
  try { myFont = (JSON.parse(localStorage.getItem('lousa.myfont') || '{}').g) || {}; } catch (e) { myFont = {}; }
  function saveFont() { try { localStorage.setItem('lousa.myfont', JSON.stringify({ v: 1, guias: [0.2, 0.45, 0.75], g: myFont })); } catch (e) { toast('Não consegui guardar no iPhone', true); } }
  const slots = () => { const o = []; FONT_CHARS.forEach(ch => { for (let i = 0; i < VARS; i++) o.push([ch, i]); }); return o; };
  const has = (ch, i) => !!(myFont[ch] && myFont[ch][i]);
  function fontDone() { return slots().filter(([c, i]) => has(c, i)).length; }
  function nextSlot() { return slots().find(([c, i]) => !has(c, i)) || null; }
  function drawFontUI() {
    const done = fontDone(), total = FONT_CHARS.length * VARS;
    $('#fontCount').textContent = done + ' de ' + total + ' feitos';
    if (!fontMode) return;
    const n = nextSlot();
    $('#fontPrompt').innerHTML = n ? 'Escreva: <b>' + n[0] + '</b> <span style="color:var(--muted);font-weight:400">(' + (n[1] + 1) + 'ª de ' + VARS + ') · ' + done + '/' + total + '</span>' : 'Pronto! Todos feitos 🎉';
  }
  function openPad(font) {
    fontMode = font;
    $('#fontPrompt').style.display = font ? 'block' : 'none';
    $('#ePrev').style.display = font ? '' : 'none';
    $('#eSend').textContent = font ? 'Próximo' : 'Enviar à lousa';
    strokes = []; $('#escrita').classList.add('on'); nat('giro', true); sizePad(); drawFontUI();
    setTimeout(sizePad, 400); setTimeout(sizePad, 900);
  }
  $('#goEscrita').addEventListener('click', () => openPad(false));
  $('#btnFont').addEventListener('click', () => openPad(true));
  $('#btnRedo').addEventListener('click', () => {
    const c = (prompt('Qual caractere você quer refazer? (ex.: 8 ou :)') || '').trim();
    if (!c) return;
    const ch = [...c][0];
    if (!FONT_CHARS.includes(ch)) { toast('Esse caractere não está na lista', true); return; }
    myFont[ch] = []; saveFont();
    const rl = redoList(); if (!rl.includes(ch)) rl.push(ch); try { localStorage.setItem('lousa.redo', JSON.stringify(rl)); } catch (e) {}
    toast('Escreva o ' + ch + ' 3 vezes'); openPad(true);
  });
  $('#eBack').addEventListener('click', () => { $('#escrita').classList.remove('on'); fontMode = false; nat('giro', false); });
  // volta um: apaga o último que foi guardado para refazer
  $('#ePrev').addEventListener('click', () => {
    const done = slots().filter(([c, i]) => has(c, i)); if (!done.length) return;
    const [c, i] = done[done.length - 1]; myFont[c][i] = null; saveFont();
    strokes = []; redrawPad(); drawFontUI(); toast('Refaça o ' + c);
  });
  function saveGlyph() {
    const n = nextSlot(); if (!n) { toast('Todos já foram feitos'); return; }
    const r3 = (v) => Math.round(v * 1000) / 1000;
    const g = strokes.map(st => {
      const out = [];
      st.forEach(p => { const x = r3((p.x - fr.x) / fr.w), y = r3((p.y - fr.y) / fr.h); const l = out[out.length - 1]; if (!l || Math.hypot(l[0] - x, l[1] - y) >= 0.003) out.push([x, y]); });
      return out;
    });
    (myFont[n[0]] = myFont[n[0]] || [])[n[1]] = g;
    saveFont(); strokes = []; redrawPad(); drawFontUI(); applyHand();
  }
  $('#btnFontShare').addEventListener('click', async () => {
    const done = fontDone(); if (!done) { toast('Ainda não tem nenhuma letra feita'); return; }
    const txt = JSON.stringify({ v: 1, app: 'Lousa', guias: [0.2, 0.45, 0.75], g: myFont });
    try {
      const file = new File([txt], 'minha-letra.json', { type: 'application/json' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) { await navigator.share({ files: [file], title: 'Minha letra' }); return; }
    } catch (e) { if (/abort/i.test(LousaBLE.errStr(e))) return; log('Compartilhar falhou: ' + LousaBLE.errStr(e)); }
    try { await navigator.clipboard.writeText(txt); toast('Minha letra copiada (' + done + ' feitos) — cole no chat'); }
    catch (e) { const ta = document.createElement('textarea'); ta.value = txt; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); toast('Minha letra copiada — cole no chat'); }
  });
  drawFontUI();
  $('#eUndo').addEventListener('click', () => { strokes.pop(); redrawPad(); });
  $('#eClear').addEventListener('click', () => { strokes = []; redrawPad(); });
  $('#eSend').addEventListener('click', () => {
    if (!strokes.length) { toast('Escreva algo primeiro'); return; }
    if (fontMode) { saveGlyph(); return; }
    const list = strokes.map(st => st.map(p => ({ x: (p.x - fr.x) / fr.w, y: (p.y - fr.y) / fr.h })));
    send('strokes', { strokes: { norm: true, lw: 15, list } }, 'escrita manual', null, null, '✎');
    toast('Enviando para a lousa…');
  });
  const reSize = () => { if ($('#escrita').classList.contains('on')) setTimeout(sizePad, 60); };
  window.addEventListener('resize', reSize);
  window.addEventListener('orientationchange', reSize);
  if (window.visualViewport) window.visualViewport.addEventListener('resize', reSize);

  // ---------- funcionar com a tela apagada (app nativo) ----------
  // além do som mudo da casca, a página toca a sua "música" muda (é o que segura o app com a tela apagada, igual ao Relógio)
  // ----- "música" muda que mantém o app acordado; na tela de bloqueio aparece como uma música de verdade -----
  const MUSICA = { title: "Don't Stop Believin' - Live 1977", artist: 'Journey', secs: 252 };
  function musicaMudaUrl() {
    const rate = 8000, n = rate * MUSICA.secs, buf = new ArrayBuffer(44 + n), v = new DataView(buf);
    const w = (o, t) => { for (let i = 0; i < t.length; i++) v.setUint8(o + i, t.charCodeAt(i)); };
    w(0, 'RIFF'); v.setUint32(4, 36 + n, true); w(8, 'WAVE'); w(12, 'fmt '); v.setUint32(16, 16, true);
    v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate, true);
    v.setUint16(32, 1, true); v.setUint16(34, 8, true); w(36, 'data'); v.setUint32(40, n, true);
    for (let i = 0; i < n; i++) v.setUint8(44 + i, i % 2 ? 129 : 127);   // inaudível
    return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
  }
  function musicaInfo(audio) {
    try { document.title = MUSICA.title; } catch (e) {}
    if (!('mediaSession' in navigator)) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({ title: MUSICA.title, artist: MUSICA.artist, album: '', artwork: [] });
      const keep = () => { const p = audio.play(); if (p && p.catch) p.catch(() => {}); };   // "pausar" no bloqueio não para o app
      ['pause', 'stop'].forEach(a => { try { navigator.mediaSession.setActionHandler(a, keep); } catch (e) {} });
      ['previoustrack', 'nexttrack'].forEach(a => { try { navigator.mediaSession.setActionHandler(a, () => {}); } catch (e) {} });
      ['seekbackward', 'seekforward', 'seekto'].forEach(a => { try { navigator.mediaSession.setActionHandler(a, null); } catch (e) {} });
    } catch (e) {}
  }

  let bgAudio = null;
  function bgAplicar() {
    if (!NATIVO) return;
    nat('segundoPlano', !!opt.bgOn);
    if (opt.bgOn) {
      if (!bgAudio) { bgAudio = new Audio(musicaMudaUrl()); bgAudio.loop = true; bgAudio.setAttribute('playsinline', ''); musicaInfo(bgAudio); }
      const p = bgAudio.play(); if (p && p.catch) p.catch(() => {});
    } else if (bgAudio) bgAudio.pause();
  }
  document.addEventListener('touchend', () => { if (opt.bgOn && bgAudio && bgAudio.paused) bgAplicar(); }, { passive: true });
  bindSw('#optBg', 'bgOn'); $('#optBg').addEventListener('change', bgAplicar);
  if (!NATIVO) $('#bgRow').classList.add('hide');
  const rnd = () => (Math.random() * 1e9) >>> 0;
  const two = (n) => String(n).padStart(2, '0');

  // ---------- rótulo curto (aparece no disfarce) ----------
  const SUITSYM = { S: '♠', H: '♥', D: '♦', C: '♣' };
  function cardShort(v, s) { return v + ' ' + SUITSYM[s]; }

  // ---------- Post-It ----------
  const PADMODES = { square: 'Quadrado', clock: 'Hora', card: 'Carta' };
  const postit = LousaPad.Pad({ log, onState: drawPad, onRead: onPadRead, onTrain: drawTrain, onTrainInk: drawTrainInk });
  function drawPad(state, bat) {
    state = state || postit.state();
    $('#chipPad').classList.toggle('hide', !opt.padOn);
    const k = { on: 'ok', wait: 'busy', off: 'bad', idle: '' }[state];
    $('#chipPad').className = 'chip sm' + (opt.padOn ? '' : ' hide') + (k ? ' ' + k : '');
    $('#dotPad').className = 'dot' + (k ? ' ' + k : '');
    $('#txtPad').textContent = 'Post-It · ' + PADMODES[opt.padMode];
    $('#padState').textContent = { on: 'conectado' + (bat != null ? ' · bateria ' + bat + '%' : ''), wait: 'procurando o Post-It…', off: 'não encontrado — toque em Conectar', idle: 'desligado' }[state];
    $('#btnPad').textContent = state === 'on' ? 'Trocar' : 'Conectar';
    updateCam();
  }
  bindSw('#optPad', 'padOn');
  $('#optPad').addEventListener('change', () => { postit.setOn(opt.padOn); drawPad(); });
  const drawPadSeg = () => $$('#segPad button').forEach(b => b.classList.toggle('sel', b.dataset.v === opt.padMode));
  $$('#segPad button').forEach(b => b.addEventListener('click', () => { opt.padMode = b.dataset.v; saveOpt(); drawPadSeg(); postit.setMode(opt.padMode); drawPad(); }));
  drawPadSeg();
  // toque no chip do Post-It: troca o modo (Quadrado → Hora → Carta)
  $('#chipPad').addEventListener('click', () => {
    const order = ['square', 'clock', 'card'];
    opt.padMode = order[(order.indexOf(opt.padMode) + 1) % 3]; saveOpt(); drawPadSeg(); postit.setMode(opt.padMode); drawPad();
    toast('Post-It: ' + PADMODES[opt.padMode]);
  });
  $('#btnPad').addEventListener('click', async () => {
    if (!opt.padOn) { opt.padOn = true; $('#optPad').checked = true; saveOpt(); postit.setOn(true); }
    try { await postit.pick(); } catch (e) { const m = LousaBLE.errStr(e); if (!/cancel/i.test(m)) toast('Post-It não conectou: ' + m, true); }
    drawPad();
  });
  function onPadRead(r) {
    if (!r.ok) {
      camFlash('fail');
      if (r.kind === 'card' && !postit.hasCardTraining()) toast('Treine as letras de carta (Opções › Post-It)', true);
      else toast('Post-It: não entendi' + (r.text ? ' (li "' + r.text + '")' : ''), true);
      return;
    }
    if (r.kind === 'card') {
      const { v, s } = r.data;
      send('card', { v, s, full: opt.full }, Lousa.cardName(v, s), { seed: rnd(), size: opt.cardSize / 100 }, null, cardShort(v, s));
    } else if (r.kind === 'clock') {
      const { h, m } = r.data;
      send('clock', { h, m }, h + ':' + two(m), { seed: rnd(), size: opt.clockSize / 100 }, null, h + ':' + two(m));
    } else {
      const n = r.data.n, seed = rnd();
      if (!Lousa.checkSquare(Lousa.magicSquare(n, Lousa.rng(seed)), n)) { camFlash('fail'); log('Quadrado ' + n + ' não fechou'); return; }
      send('square', { n }, 'quadrado ' + n, { seed, size: opt.sqSize / 100, line: opt.sqLine / 100 }, null, String(n));
    }
  }
  // treino das letras de carta (A J Q K e C E O P), 3 de cada
  function drawTrainCount() { const i = postit.trainInfo(); $('#trCount').textContent = i.done + ' de ' + i.total + (i.done >= i.total ? ' ✓' : ''); }
  function drawTrain(next, done) {
    const i = postit.trainInfo();
    $('#trChar').textContent = next || '✓';
    const n = next ? (LousaPad.TRAIN_N - (i.done - LousaPad.TRAIN_CHARS.indexOf(next) * LousaPad.TRAIN_N)) : 0;
    $('#trOf').textContent = next ? (LousaPad.TRAIN_N - n + 1) + 'ª de ' + LousaPad.TRAIN_N : 'Pronto! Todas treinadas';
    $('#trProg').textContent = i.done + ' de ' + i.total;
    drawTrainCount();
  }
  function drawTrainInk(list) {
    const cv = $('#trCanvas'), g = cv.getContext('2d');
    g.fillStyle = '#0E0F11'; g.fillRect(0, 0, cv.width, cv.height);
    const pts = list.flat(); if (!pts.length) return;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    pts.forEach(p => { x0 = Math.min(x0, p.x); x1 = Math.max(x1, p.x); y0 = Math.min(y0, p.y); y1 = Math.max(y1, p.y); });
    const mg = 40, sc = Math.min((cv.width - 2 * mg) / Math.max(x1 - x0, 1), (cv.height - 2 * mg) / Math.max(y1 - y0, 1), 0.04);
    const ox = (cv.width - (x1 - x0) * sc) / 2, oy = (cv.height - (y1 - y0) * sc) / 2;
    g.strokeStyle = '#F2EDE4'; g.lineWidth = 8; g.lineCap = 'round'; g.lineJoin = 'round';
    list.forEach(st => { g.beginPath(); st.forEach((p, i) => { const X = ox + (p.x - x0) * sc, Y = oy + (p.y - y0) * sc; i ? g.lineTo(X, Y) : g.moveTo(X, Y); }); if (st.length === 1) g.lineTo(ox + (st[0].x - x0) * sc + 0.1, oy + (st[0].y - y0) * sc); g.stroke(); });
  }
  let training = false;
  function trainOpen() {
    training = true;
    const t = postit.trainStart(); drawTrain(t.next, t.done); drawTrainInk([]);
    $('#trHint').textContent = postit.connected() ? 'Escreva no Post-It a letra abaixo. Depois de 1,5 s parado, ela é guardada e vem a próxima.' : 'Ligue "Usar o Post-It" e conecte o Post-It para treinar.';
  }
  function trainClose() { if (training) { training = false; postit.trainStop(); drawTrainCount(); } }
  $('#btnTrain').addEventListener('click', () => go('treino'));
  $('#trUndo').addEventListener('click', () => { const c = postit.trainUndo(); const i = postit.trainInfo(); drawTrain(i.next, i.done); drawTrainInk([]); if (c) toast('Escreva o ' + c + ' de novo'); });
  $('#trReset').addEventListener('click', () => { if (!confirm('Apagar todas as letras treinadas?')) return; postit.trainReset(); const i = postit.trainInfo(); drawTrain(i.next, i.done); });

  // ---------- Assistente (Ably, canal secreto só da lousa) ----------
  // canal: lousa:<código>
  //   assistente publica 'cmd' {id, k, d, seed}  (k = card | clock | date | word | square | clear)
  //   este app publica 'st' {id, s}  (s = got | start | prog (p) | ok | bad (e) | skip)
  //   este app fica "presente" no canal com {b, t, sz, dust, num, full}: b = ok | send | off (a lousa), sz = tamanhos
  const ABLY_KEY = '-WkBxA.FUModg:DGe6U1wyeEuOu4_3iuubjnS144Ol3ojOlTb9mmqgmv0';
  let canal = ''; try { canal = localStorage.getItem('lousa.canal') || ''; } catch (e) {}
  if (!canal) {
    const r = new Uint8Array(18); (window.crypto || self.crypto).getRandomValues(r);
    canal = 'lsa' + Array.from(r).map(x => (x % 36).toString(36)).join('');
    try { localStorage.setItem('lousa.canal', canal); } catch (e) {}
  }
  let ably = null, ch = null, presT = null, rxIn = false;
  const live = () => !!(ably && ch && ably.connection.state === 'connected');
  function rxShow(kind, text) {
    $('#chipRx').className = 'chip sm' + (opt.rx ? '' : ' hide') + (kind ? ' ' + kind : '');
    $('#txtRx').textContent = 'Assistente';
    $('#rxState').textContent = text;
  }
  function boardReady() { return board.connected() || running || stKind === 'ok' || (stKind === 'busy' && Date.now() - lastOkAt < 90000); }
  function info() {
    return { b: running ? 'send' : (boardReady() ? 'ok' : 'off'), t: Date.now(), v: VER,
      sz: { card: opt.cardSize, clock: opt.clockSize, date: opt.dateSize, word: opt.wordSize, sq: opt.sqSize, sqLine: opt.sqLine },
      dust: !!opt.dust, num: !!opt.numerals, full: !!opt.full };
  }
  let lastB = '';
  function presence(force) {
    if (!live()) return;
    const b = info().b;
    if (!force && b === lastB) { clearTimeout(presT); presT = setTimeout(() => presence(true), 800); return; }
    lastB = b;
    try { ch.presence.update(info()).catch(() => {}); } catch (e) {}
  }
  setInterval(() => presence(true), 15000);     // "estou aqui" a cada 15 s
  function rxOpen() {
    if (!opt.rx) { rxShow('', 'desligado'); return; }
    if (ably) return;
    if (!window.AblyPubSub) { rxShow('bad', 'não carregou (sem internet?)'); setTimeout(() => { if (opt.rx && !ably) rxOpen(); }, 8000); return; }
    rxShow('busy', 'conectando…');
    try {
      ably = AblyPubSub.createClient({ key: ABLY_KEY, clientId: 'magico', echoMessages: false });
      ch = ably.channels.get('relogio:lousa-' + canal);   // a chave do Ably só aceita canais "relogio:…"
      ably.connection.on(stc => {
        if (!opt.rx) return;
        if (stc.current === 'connected') {
          rxShow('busy', 'entrando no canal…');
          log('Assistente: conectado à internet');
          try {
            ch.presence.enter(info()).then(() => { rxIn = true; rxShow('ok', 'pronto para receber'); log('Assistente: no canal, pronto para receber'); },
              e => { rxIn = false; rxShow('bad', 'canal recusado'); log('Assistente: presença ' + LousaBLE.errStr(e)); });
          } catch (e) { rxShow('bad', 'canal recusado'); }
        } else if (stc.current === 'connecting') rxShow('busy', 'conectando…');
        else rxShow('bad', stc.current === 'disconnected' ? 'sem internet — tentando' : stc.current);
      });
      ch.on(cs => { if (!opt.rx) return; if (cs.current === 'failed' || cs.current === 'suspended' || cs.current === 'detached') { rxIn = false; rxShow('bad', 'fora do canal — tentando'); log('Assistente: canal ' + cs.current + (cs.reason ? ' — ' + LousaBLE.errStr(cs.reason) : '')); } else if (cs.current === 'attached' && rxIn) rxShow('ok', 'pronto para receber'); });
      ch.subscribe('cmd', msg => {
        if (msg.timestamp && Date.now() - msg.timestamp > 30000) return;     // pedido velho: ignora
        onCmd(msg.data || {});
      });
    } catch (e) { log('Assistente: erro ' + LousaBLE.errStr(e)); rxClose(); setTimeout(() => { if (opt.rx && !ably) rxOpen(); }, 8000); }
  }
  function rxClose() {
    if (ch) { try { ch.presence.leave().catch(() => {}); } catch (e) {} }
    if (ably) { try { ably.close(); } catch (e) {} }
    ably = null; ch = null; rxIn = false;
  }
  function stPub(id, s, extra) { try { if (ch) ch.publish('st', Object.assign({ id, s }, extra || {})).catch(() => {}); } catch (e) {} }
  function onCmd(d) {
    const id = d.id || null, k = d.k, x = d.d || {}, seed = (d.seed >>> 0) || rnd();
    stPub(id, 'got');
    log('Assistente mandou: ' + k + ' ' + JSON.stringify(x));
    const cb = (s, v) => { if (s === 'prog') stPub(id, 'prog', { p: Math.round(v * 100) / 100 }); else if (s === 'bad') stPub(id, 'bad', { e: v }); else stPub(id, s); };
    const bad = (e) => stPub(id, 'bad', { e });
    if (k === 'card') {
      if (!SUITSYM[x.s] || !['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'].includes(x.v)) return bad('carta inválida');
      send('card', { v: x.v, s: x.s, full: opt.full }, Lousa.cardName(x.v, x.s), { seed, size: opt.cardSize / 100 }, cb, cardShort(x.v, x.s));
    } else if (k === 'clock') {
      const h = +x.h, m = +x.m; if (!(h >= 0 && h <= 23 && m >= 0 && m <= 59)) return bad('hora inválida');
      send('clock', { h, m }, h + ':' + two(m), { seed, size: opt.clockSize / 100 }, cb, h + ':' + two(m));
    } else if (k === 'date') {
      const r = Lousa.daysLived(+x.d, +x.m, +x.y); if (typeof r !== 'number') return bad('data inválida');
      send('text', { text: String(r) }, r + ' dias', { seed, size: opt.dateSize / 100 }, cb, String(r));
    } else if (k === 'word') {
      const t = String(x.t || '').trim().replace(/\s+/g, ' ').slice(0, 40); if (!t) return bad('palavra vazia');
      send('text', { text: t }, t, { seed, size: opt.wordSize / 100 }, cb, t);
    } else if (k === 'square') {
      const n = +x.n; if (!(n >= 34 && n <= 99999)) return bad('número precisa ser 34 ou mais');
      if (!Lousa.checkSquare(Lousa.magicSquare(n, Lousa.rng(seed)), n)) return bad('conta não fechou');
      send('square', { n }, 'quadrado ' + n, { seed, size: opt.sqSize / 100, line: opt.sqLine / 100 }, cb, String(n));
    } else if (k === 'clear') clearBoard(cb);
    else bad('pedido desconhecido');
  }
  bindSw('#optRx', 'rx');
  $('#optRx').addEventListener('change', () => { if (opt.rx) rxOpen(); else { rxClose(); rxShow('', 'desligado'); } });
  $('#chipRx').addEventListener('click', () => go('opcoes'));
  function assistLink() { return 'https://madureira-magico.github.io/apps-magica/lousa/assistente.html#' + canal; }
  $('#btnLink').addEventListener('click', async () => {
    const link = assistLink();
    try { await navigator.clipboard.writeText(link); toast('Link copiado — mande para o assistente'); return; } catch (e) {}
    try { if (navigator.share) { await navigator.share({ title: 'Lousa — assistente', url: link }); return; } } catch (e) { return; }
    $('#rxNote').textContent = link; $('#rxNote').style.userSelect = 'text';
  });
  window.addEventListener('online', () => { if (opt.rx) { if (!ably) rxOpen(); else try { ably.connect(); } catch (e) {} } });
  document.addEventListener('visibilitychange', () => {
    if (!opt.rx) return;
    if (document.visibilityState === 'hidden') { if (NATIVO && opt.bgOn) return; rxClose(); rxShow('bad', 'app em segundo plano'); }
    else if (!ably) rxOpen();
  });

  // ---------- Disfarce: tela de bloqueio falsa ----------
  const DIAS = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
  let fakeItem = '', fakeT = null, itemT = null, camTemp = null, camT = null, camBlink = null;
  function fakeShown() { return $('#fake').classList.contains('show'); }
  function tickFake() {
    const d = new Date();
    const fd = $('#fDate'); fd.textContent = DIAS[d.getDay()] + ', ' + d.getDate();
    if (fakeItem) { const sp = document.createElement('span'); sp.className = 'it'; sp.textContent = ' · ' + fakeItem; fd.appendChild(sp); }
    $('#fClk').textContent = two(d.getHours()) + ':' + two(d.getMinutes());
  }
  function showFake() { fakeItem = ''; tickFake(); clearInterval(fakeT); fakeT = setInterval(tickFake, 1000); $('#fake').classList.add('show'); updateCam(); }
  function hideFake() { $('#fake').classList.remove('show'); clearInterval(fakeT); }
  // chegou na lousa: mostra ao lado da data e a câmera fica laranja (some depois do tempo escolhido)
  // chegou no iPhone (assistente, Post-It ou daqui): já aparece ao lado da data
  function incoming(short) {
    clearTimeout(itemT);
    if (short) { fakeItem = short; tickFake(); }
  }
  // a lousa recebeu: câmera laranja; os dois somem juntos depois do tempo escolhido
  function arrived(short) {
    if (short) fakeItem = short;
    tickFake(); clearTimeout(itemT);
    camFlash('got');
    if (opt.gotSecs) itemT = setTimeout(() => { fakeItem = ''; tickFake(); }, opt.gotSecs * 1000);
  }
  function paintCam(color, op) {
    const el = $('#camBtn');
    if (opt.camStyle === 'circulo') { el.style.background = color; el.style.color = '#fff'; }
    else { el.style.background = '#fff'; el.style.color = color; }
    el.style.opacity = op;
  }
  function updateCam() {
    clearInterval(camBlink);
    const ready = boardReady() && (!opt.padOn || postit.connected());
    if (camTemp === 'fail') { let v = 1; paintCam('#E24B4A', 1); camBlink = setInterval(() => { v = v === 1 ? 0.3 : 1; paintCam('#E24B4A', v); }, 350); }
    else if (!ready) paintCam('#E24B4A', 1);
    else if (camTemp === 'got') paintCam('#EF9F27', 1);
    else paintCam('#1D9E75', 1);
  }
  function camFlash(kind) {
    camTemp = kind; clearTimeout(camT); updateCam();
    if (kind === 'fail') camT = setTimeout(() => { camTemp = null; updateCam(); }, 3000);
    else if (opt.gotSecs) camT = setTimeout(() => { if (camTemp === 'got') { camTemp = null; updateCam(); } }, opt.gotSecs * 1000);
  }
  setInterval(updateCam, 5000);
  bindSw('#optDz', 'dz');
  const drawDz = () => $('#lockBtn').classList.toggle('hide', !opt.dz);
  $('#optDz').addEventListener('change', drawDz);
  $('#lockBtn').addEventListener('click', showFake);
  bindSeg('#segCam', 'camStyle', updateCam);
  bindSeg('#segGot', 'gotSecs');
  // sair: dois toques rápidos (igual ao Relógio)
  let lastTap = 0;
  $('#fake').addEventListener('touchend', e => { e.preventDefault(); const t = Date.now(); if (t - lastTap < 400) { lastTap = 0; hideFake(); } else lastTap = t; }, { passive: false });
  $('#fake').addEventListener('dblclick', hideFake);
  // foto do fundo
  let fakeFoto = null; try { fakeFoto = localStorage.getItem('lousa.fakeFoto'); } catch (e) {}
  function applyFoto() { const f = $('#fake'); f.classList.toggle('foto', !!fakeFoto); f.style.backgroundImage = fakeFoto ? 'url(' + fakeFoto + ')' : ''; $('#btnFoto').textContent = fakeFoto ? 'Trocar' : 'Escolher'; }
  $('#btnFoto').addEventListener('click', () => $('#fotoIn').click());
  $('#fotoIn').addEventListener('change', e => {
    const file = e.target.files && e.target.files[0]; e.target.value = ''; if (!file) return;
    const u = URL.createObjectURL(file), im = new Image();
    im.onload = () => {
      const r = Math.max(screen.width, screen.height) / Math.min(screen.width, screen.height) || 2.17;
      const W = 1000, H = Math.round(W * r), c = document.createElement('canvas');
      let sw = im.naturalWidth, sh = im.naturalHeight, sx = 0, sy = 0;
      if (sh / sw > r) { sh = sw * r; sy = (im.naturalHeight - sh) / 2; } else { sw = sh / r; sx = (im.naturalWidth - sw) / 2; }
      c.width = W; c.height = H; c.getContext('2d').drawImage(im, sx, sy, sw, sh, 0, 0, W, H);
      URL.revokeObjectURL(u);
      let data = c.toDataURL('image/jpeg', .85); if (data.length > 1500000) data = c.toDataURL('image/jpeg', .6);
      try { localStorage.setItem('lousa.fakeFoto', data); fakeFoto = data; toast('Foto do bloqueio trocada'); } catch (err) { toast('Sem espaço para guardar a foto', true); }
      applyFoto();
    };
    im.onerror = () => { URL.revokeObjectURL(u); toast('Não consegui abrir essa foto', true); };
    im.src = u;
  });

  function startExtras() {
    drawDz(); applyFoto();
    bgAplicar();
    postit.setMode(opt.padMode);
    if (opt.padOn) postit.setOn(true);
    drawPad(); drawTrainCount();
    rxShow('', 'desligado'); if (opt.rx) rxOpen();
    updateCam();
  }

  // ---------- opções: teste e registro ----------
  $('#btnTest').addEventListener('click', () => send('clock', { h: 10, m: 10 }, 'teste 10:10'));
  $('#btnCopy').addEventListener('click', async () => {
    const txt = logLines.join('\n') || '(vazio)';
    try { await navigator.clipboard.writeText(txt); toast('Registro copiado'); }
    catch (e) { const ta = document.createElement('textarea'); ta.value = txt; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); toast('Registro copiado'); }
  });

  setStatus('', navigator.bluetooth ? 'Conectar lousa' : 'Sem Bluetooth');
  $('#verTxt').textContent = 'v' + VER + (NATIVO ? '' : ' · navegador');
  log('Lousa v' + VER + (NATIVO ? ' (app)' : ' (navegador)') + ' iniciada · letra ' + (Lousa.hasHand() ? 'sua' : 'padrão') + ' · Bluetooth: ' + (navigator.bluetooth ? 'sim' : 'não'));
  startExtras();
  drawClockUI(); drawDateUI(); drawCardUI();
  // ao abrir: volta sozinho para a lousa já usada (se o Bluefy permitir)
  if (navigator.bluetooth) {
    const first = isFirstConnection();
    setStatus('busy', 'Procurando a lousa…');
    board.restore().then(ok => {
      if (ok && board.connected()) afterConnect(first);
      else setStatus('', 'Conectar lousa');
    }).catch(e => {
      log('Lousa não respondeu ao abrir: ' + LousaBLE.errStr(e));
      if (board.device) ensure(false); else setStatus('', 'Conectar lousa');
    });
  }
})();
