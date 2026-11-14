// ===== Conexão Bluetooth com a lousa (Inversion Board) =====
// Serviço FEF0 (ou FDF0/FCF0/FBF0): FxF1 = comandos (escreve e avisa), FxF2 = dados da imagem.
(function (root) {
  const SERVICES = [0xfef0, 0xfdf0, 0xfcf0, 0xfbf0];
  // códigos na forma longa (o Bluefy não aceita a forma curta)
  const U = (n) => '0000' + n.toString(16).padStart(4, '0') + '-0000-1000-8000-00805f9b34fb';
  const SVC_U = SERVICES.map(U);
  function errStr(e) {
    if (e == null) return 'erro sem descrição';
    if (typeof e === 'string') return e;
    let t = (e.name ? e.name + ': ' : '') + (e.message || '');
    if (!t.trim() || t === 'Error: ') { try { t = JSON.stringify(e) || String(e); } catch (x) { t = String(e); } }
    return t;
  }
  function isCancel(e) { return /cancel/i.test(errStr(e)); }

  function Board(log) {
    this.log = log || function () {};
    this.device = null; this.ctrl = null; this.data = null;
    this.waiters = []; this.onBlockRequest = null; this.onDisconnect = null;
    this.swBit80 = true;   // a lousa NEMR anuncia versão 0x81 (bit 0x80 ligado)
    this.busy = false;
    this.dataMode = 'resp';  // modo seguro (com resposta): no iPhone o modo rápido perde dados
  }
  Board.prototype.connected = function () { return !!(this.device && this.device.gatt && this.device.gatt.connected && this.ctrl && this.data); };

  Board.prototype.pick = async function () {
    const tries = [
      ['pelo serviço', { filters: SVC_U.map(u => ({ services: [u] })), optionalServices: SVC_U }],
      ['pelo nome NEMR', { filters: [{ namePrefix: 'NEMR' }], optionalServices: SVC_U }],
      ['todos os aparelhos', { acceptAllDevices: true, optionalServices: SVC_U }],
    ];
    let lastErr = null;
    for (const [nome, opts] of tries) {
      try {
        this.log('Procurando ' + nome + '…');
        this.device = await navigator.bluetooth.requestDevice(opts);
        lastErr = null; break;
      } catch (e) {
        lastErr = e;
        this.log('Busca ' + nome + ' falhou: ' + errStr(e));
        if (isCancel(e)) break;      // você fechou a lista: não insiste
      }
    }
    if (lastErr) throw new Error(errStr(lastErr));
    this.log('Escolhida: ' + (this.device.name || '(sem nome)'));
    try { localStorage.setItem('lousa.devId', this.device.id || ''); } catch (e) {}
    this.setDevice(this.device);
    await this.attach();
  };

  Board.prototype.setDevice = function (dev) {
    this.device = dev;
    if (dev.__lousaHooked) return;
    dev.__lousaHooked = true;
    dev.addEventListener('gattserverdisconnected', () => {
      this.log('Lousa desconectou'); this.ctrl = null; this.data = null;
      if (this.onDisconnect) this.onDisconnect();
    });
  };

  // "escuta" o sinal da lousa antes de conectar — renova a lousa lembrada depois que o app foi fechado
  // (mesmo método do app do relógio, que reconecta sozinho no Bluefy)
  Board.prototype.listen = function (ms) {
    const d = this.device;
    if (!d || typeof d.watchAdvertisements !== 'function') return Promise.resolve(false);
    return new Promise(resolve => {
      let done = false;
      const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
      const finish = (ok) => {
        if (done) return; done = true;
        try { d.removeEventListener('advertisementreceived', onAdv); } catch (e) {}
        try { if (ctrl) ctrl.abort(); } catch (e) {}
        try { if (typeof d.unwatchAdvertisements === 'function') d.unwatchAdvertisements(); } catch (e) {}
        resolve(ok);
      };
      const onAdv = () => finish(true);
      try { d.addEventListener('advertisementreceived', onAdv); } catch (e) {}
      try {
        const p = ctrl ? d.watchAdvertisements({ signal: ctrl.signal }) : d.watchAdvertisements();
        if (p && p.catch) p.catch(() => finish(false));
      } catch (e) { finish(false); return; }
      setTimeout(() => finish(false), ms);
    });
  };
  // entre os aparelhos lembrados, qual é a lousa (nunca o Post-It)
  Board.prototype.findBoard = function (devs) {
    let id = ''; try { id = localStorage.getItem('lousa.devId') || ''; } catch (e) {}
    return devs.find(d => id && d.id === id) || devs.find(d => /NEMR|PICK/i.test(d.name || '')) || devs.find(d => !/^PAD/i.test(d.name || '') && !/IARVEL/i.test(d.name || '')) || null;
  };
  // pega de novo a lousa lembrada (objeto novo)
  Board.prototype.refresh = async function () {
    if (!navigator.bluetooth || !navigator.bluetooth.getDevices) return false;
    try {
      const devs = await this.withTimeout(navigator.bluetooth.getDevices(), 2500);
      const dev = this.findBoard(devs);
      if (dev && dev !== this.device) { this.setDevice(dev); return true; }
    } catch (e) {}
    return false;
  };

  // ao abrir o app: tenta voltar à lousa já autorizada, sem abrir a lista
  Board.prototype.restore = async function () {
    if (!navigator.bluetooth || !navigator.bluetooth.getDevices) { this.log('Reconexão automática ao abrir: não suportada neste navegador'); return false; }
    let devs = [];
    try { devs = await navigator.bluetooth.getDevices(); } catch (e) { this.log('getDevices falhou: ' + errStr(e)); return false; }
    const dev = this.findBoard(devs);
    if (!dev) { this.log('Nenhuma lousa lembrada'); return false; }
    this.log('Lousa lembrada: ' + (dev.name || '(sem nome)'));
    this.setDevice(dev);
    const t = Date.now();
    const heard = await this.listen(8000);
    this.log(heard ? 'Ouvi a lousa em ' + ((Date.now() - t) / 1000).toFixed(1) + ' s' : (typeof dev.watchAdvertisements === 'function' ? 'Não ouvi a lousa em 8 s' : 'Bluefy sem "escutar sinal"'));
    await this.withTimeout(this.attach(), 15000);
    return true;
  };

  Board.prototype.withTimeout = function (p, ms) {
    return Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('tempo esgotado')), ms))]);
  };

  Board.prototype.attach = async function () {
    const server = await this.device.gatt.connect();
    let svc = null, base = 0;
    for (const n of SERVICES) {
      try { svc = await server.getPrimaryService(U(n)); base = n; break; } catch (e) { /* tenta o próximo */ }
    }
    if (!svc) throw new Error('Este aparelho não é a lousa (serviço FEF0 não encontrado)');
    this.ctrl = await svc.getCharacteristic(U(base + 1));
    this.data = await svc.getCharacteristic(U(base + 2));
    await this.ctrl.startNotifications();
    // mesma função sempre: se conectar duas vezes, o aviso não fica duplicado
    this._nh = this._nh || ((ev) => this.onNotify(new Uint8Array(ev.target.value.buffer.slice(ev.target.value.byteOffset, ev.target.value.byteOffset + ev.target.value.byteLength))));
    this.ctrl.addEventListener('characteristicvaluechanged', this._nh);
    this.justConnected = Date.now();
    this.log('Conectada (serviço ' + base.toString(16).toUpperCase() + ')');
  };

  // ms = quanto esperar a lousa responder (dormindo ela demora: esperamos bastante, como o app nativo)
  Board.prototype.reconnect = async function (ms) {
    if (!this.device) throw new Error('Nenhuma lousa escolhida');
    await this.withTimeout(this.attach(), ms || 8000);
    this.justConnected = Date.now();
  };

  Board.prototype.onNotify = function (v) {
    const hex = Array.from(v).map(b => b.toString(16).padStart(2, '0')).join(' ');
    if ((v[0] !== 5 || v[1] !== 0) && !(v[0] === 5 && !this.onBlockRequest)) this.log('← ' + hex);
    if (v[0] === 5 && this.onBlockRequest) { this.onBlockRequest(v); return; }
    const i = this.waiters.findIndex(w => w.first === v[0]);
    if (i >= 0) { const w = this.waiters.splice(i, 1)[0]; clearTimeout(w.t); w.resolve(v); }
  };

  Board.prototype.writeCtrl = async function (bytes) {
    if (!this.ctrl || !this.data) throw new Error('A lousa desconectou no meio');
    const buf = new Uint8Array(bytes);
    this.log('→ ' + Array.from(buf).map(b => b.toString(16).padStart(2, '0')).join(' '));
    const p = this.ctrl.properties || {};
    if ((p.write || !this.ctrl.properties) && this.ctrl.writeValueWithResponse) return this.ctrl.writeValueWithResponse(buf);
    if (this.ctrl.writeValueWithoutResponse) return this.ctrl.writeValueWithoutResponse(buf);
    return this.ctrl.writeValue(buf);
  };

  Board.prototype.writeData = async function (buf) {
    if (!this.ctrl || !this.data) throw new Error('A lousa desconectou no meio');
    const p = this.data.properties || {};
    if (this.dataMode !== 'resp' && (p.writeWithoutResponse || !this.data.properties) && this.data.writeValueWithoutResponse) {
      try { return await this.data.writeValueWithoutResponse(buf); }
      catch (e) { this.log('Envio sem resposta falhou (' + e.message + '), tentando com resposta'); this.dataMode = 'resp'; }
    }
    if (this.data.writeValueWithResponse && p.write !== false) return this.data.writeValueWithResponse(buf);
    if (this.data.writeValue) return this.data.writeValue(buf);
    return this.data.writeValueWithoutResponse(buf);
  };

  Board.prototype.request = function (bytes, first, ms) {
    return new Promise((resolve, reject) => {
      const w = { first, resolve, t: setTimeout(() => { this.waiters = this.waiters.filter(x => x !== w); reject(new Error('A lousa não respondeu ao comando ' + first)); }, ms || 5000) };
      this.waiters.push(w);
      this.writeCtrl(bytes).catch(e => { clearTimeout(w.t); this.waiters = this.waiters.filter(x => x !== w); reject(e); });
    });
  };

  // envia a imagem já comprimida (formato da lousa). progress(0..1)
  Board.prototype.sendCompressed = async function (comp, progress) {
    if (!this.connected()) {
      if (this.device) { this.log('Reconectando…'); await this.reconnect(); }
      else throw new Error('Lousa não conectada');
    }
    // logo depois de (re)conectar a lousa precisa de um instante antes do 1º comando
    const since = Date.now() - (this.justConnected || 0);
    if (since < 1500) await new Promise(r => setTimeout(r, 1500 - since));
    this.busy = true;
    try {
      const r1 = await this.request([0x01], 0x01, 3000);
      const blockSize = r1[1] | (r1[2] << 8);
      this.log('Tamanho do bloco: ' + blockSize);
      if (!(blockSize > 4)) throw new Error('Tamanho de bloco inválido: ' + blockSize);
      const per = blockSize - 4, total = comp.length, blocks = Math.ceil(total / per);
      const mode = this.swBit80 ? 1 : 0;
      const r2 = await this.request([2, total & 255, (total >> 8) & 255, (total >> 16) & 255, (total >>> 24) & 255, mode, 0, 0], 0x02);
      if (r2[1] !== 0) throw new Error('A lousa recusou a imagem (código ' + r2[1] + ')');
      await new Promise((resolve, reject) => {
        let timer = null, done = false, next = 0, streaming = false, seq = 0, firstReq = true, sent = 0, rewinds = 0;
        const fail = (e) => { if (done) return; done = true; clearTimeout(timer); this.onBlockRequest = null; reject(e); };
        const ok = () => { if (done) return; done = true; clearTimeout(timer); this.onBlockRequest = null; resolve(); };
        const arm = () => { clearTimeout(timer); timer = setTimeout(() => fail(new Error('A lousa parou de pedir dados (enviados ' + sent + ' de ' + blocks + ' blocos)')), 8000); };
        const sendBlock = async (n) => {
          const start = n * per, end = Math.min(start + per, total);
          if (start >= total) return;
          const buf = new Uint8Array(4 + end - start);
          buf[0] = n & 255; buf[1] = (n >> 8) & 255; buf[2] = (n >> 16) & 255; buf[3] = (n >>> 24) & 255;
          buf.set(comp.subarray(start, end), 4);
          const p = (this._wq || Promise.resolve()).then(() => done ? null : this.writeData(buf));
          this._wq = p.catch(() => {});
          await p;
          sent = Math.max(sent, n + 1);
          if (progress) progress(Math.min(1, (n + 1) / blocks));
        };
        // lousas com versão 0x80: depois do 1º pedido, o app manda os blocos em sequência,
        // um logo após o outro (igual ao app oficial). Se a lousa pedir de novo um bloco, volta para ele.
        const stream = async () => {
          if (streaming) return; streaming = true;
          try {
            while (!done && next < blocks) {
              const n = next++;
              await sendBlock(n);
              arm();
            }
            if (!done) this.log('Todos os ' + blocks + ' blocos enviados, aguardando confirmação');
          } catch (e) { fail(e); }
          streaming = false;
        };
        this.onBlockRequest = (v) => {
          if (done) return;
          if (v[1] === 0) {
            arm();
            const n = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
            if (this.swBit80) {
              if (firstReq) { this.log('Lousa pediu o bloco ' + n + ' — enviando em sequência'); firstReq = false; }
              else if (n < next - 1) { rewinds++; if (rewinds <= 5) this.log('Lousa pediu de novo o bloco ' + n); }
              if (n >= next) { next = n; stream(); }      // ainda não enviado: segue a sequência a partir dele
              else sendBlock(n).catch(fail);              // já enviado: manda só esse de novo (como o app oficial)
            } else {
              const k = firstReq ? n : seq + 1; firstReq = false; seq = k;
              sendBlock(k).catch(fail);
            }
          } else if (v[1] === 8) {
            ok();
          } else {
            fail(new Error('A lousa recusou os dados (código ' + v[1] + ')'));
          }
        };
        arm();
        this.writeCtrl([0x03]).catch(fail);
      });
      this.log('Imagem enviada (' + total + ' bytes, ' + blocks + ' blocos)');
    } finally {
      this.busy = false; this.onBlockRequest = null;
    }
  };

  const api = { Board, SERVICES, errStr };
  if (typeof module !== 'undefined') module.exports = api; else root.LousaBLE = api;
})(typeof window !== 'undefined' ? window : globalThis);
