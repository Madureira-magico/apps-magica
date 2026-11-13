/* Ponte Bluetooth: dentro do app, o próprio iPhone faz o Bluetooth.
   Imita a parte do "Web Bluetooth" (Bluefy) que os apps usam, então a página não precisa mudar. */
(function () {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.ble) return;
  if (navigator.bluetooth && !navigator.bluetooth.__ponte) return;

  var seq = 0, pend = {}, devs = {}, chars = {};
  function call(cmd, args) {
    return new Promise(function (ok, fail) {
      var id = ++seq; pend[id] = { ok: ok, fail: fail };
      var msg = args || {}; msg.cmd = cmd; msg.req = id;
      try { window.webkit.messageHandlers.ble.postMessage(msg); }
      catch (e) { delete pend[id]; fail(e); }
    });
  }
  function low(u) { u = String(u || '').toLowerCase(); return u.length === 4 ? '0000' + u + '-0000-1000-8000-00805f9b34fb' : u; }
  function b64ToView(s) { var bin = atob(s || ''), a = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i); return new DataView(a.buffer); }
  function toB64(v) {
    var a = v instanceof Uint8Array ? v : (v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength));
    var s = ''; for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]); return btoa(s);
  }
  function Ev() { this._l = {}; }
  Ev.prototype.addEventListener = function (t, f) { (this._l[t] = this._l[t] || []).indexOf(f) < 0 && this._l[t].push(f); };
  Ev.prototype.removeEventListener = function (t, f) { var l = this._l[t]; if (l) { var i = l.indexOf(f); if (i >= 0) l.splice(i, 1); } };
  Ev.prototype._fire = function (t, ev) { ev = ev || {}; ev.type = t; ev.target = this; ev.currentTarget = this; (this._l[t] || []).slice().forEach(function (f) { try { f.call(this, ev); } catch (e) { setTimeout(function () { throw e; }); } }, this); };

  function Chr(dev, svc, uuid) { Ev.call(this); this._dev = dev; this._svc = svc; this.uuid = uuid; this.value = null; }
  Chr.prototype = Object.create(Ev.prototype);
  Chr.prototype.writeValueWithoutResponse = function (v) { return call('write', { id: this._dev.id, svc: this._svc, chr: this.uuid, b64: toB64(v), resp: false }).then(function () {}); };
  Chr.prototype.writeValueWithResponse = function (v) { return call('write', { id: this._dev.id, svc: this._svc, chr: this.uuid, b64: toB64(v), resp: true }).then(function () {}); };
  Chr.prototype.writeValue = Chr.prototype.writeValueWithResponse;
  Chr.prototype.startNotifications = function () { var c = this; return call('notify', { id: this._dev.id, svc: this._svc, chr: this.uuid, on: true }).then(function () { return c; }); };
  Chr.prototype.stopNotifications = function () { var c = this; return call('notify', { id: this._dev.id, svc: this._svc, chr: this.uuid, on: false }).then(function () { return c; }); };

  function Svc(dev, uuid) { this._dev = dev; this.uuid = uuid; this.device = dev; }
  Svc.prototype.getCharacteristic = function (u) {
    var dev = this._dev, svc = this.uuid; u = low(u);
    return call('chr', { id: dev.id, svc: svc, chr: u }).then(function () {
      var k = dev.id + '|' + u; if (!chars[k]) chars[k] = new Chr(dev, svc, u); return chars[k];
    });
  };

  function Gatt(dev) { this.device = dev; this.connected = false; }
  Gatt.prototype.connect = function () { var g = this; return call('connect', { id: g.device.id }).then(function () { g.connected = true; return g; }); };
  Gatt.prototype.disconnect = function () { call('disconnect', { id: this.device.id }).catch(function () {}); };
  Gatt.prototype.getPrimaryService = function (u) { var dev = this.device; u = low(u); return call('svc', { id: dev.id, svc: u }).then(function () { return new Svc(dev, u); }); };

  function Dev(id, name) { Ev.call(this); this.id = id; this.name = name || ''; this.gatt = new Gatt(this); }
  Dev.prototype = Object.create(Ev.prototype);
  function dev(o) { if (!devs[o.id]) devs[o.id] = new Dev(o.id, o.name); else if (o.name) devs[o.id].name = o.name; return devs[o.id]; }

  var bt = {
    __ponte: true,
    getAvailability: function () { return Promise.resolve(true); },
    requestDevice: function (opt) {
      opt = opt || {};
      var f = (opt.filters || []).map(function (x) { return { services: (x.services || []).map(low), namePrefix: x.namePrefix || '', name: x.name || '' }; });
      return call('request', { filters: f, all: !!opt.acceptAllDevices }).then(dev);
    },
    getDevices: function () { return call('known', {}).then(function (l) { return (l || []).map(dev); }); },
    setScreenDimEnabled: function () {}
  };
  try { Object.defineProperty(navigator, 'bluetooth', { value: bt, configurable: true }); } catch (e) { navigator.bluetooth = bt; }

  /* respostas e avisos que o iPhone manda de volta */
  window.__ble = {
    r: function (id, err, res) { var p = pend[id]; if (!p) return; delete pend[id]; if (err) p.fail(new Error(err)); else p.ok(res); },
    desconectou: function (id) { var d = devs[id]; if (!d) return; d.gatt.connected = false; d._fire('gattserverdisconnected'); },
    valor: function (id, chr, b64) { var c = chars[id + '|' + chr]; if (!c) return; c.value = b64ToView(b64); c._fire('characteristicvaluechanged'); }
  };
})();
