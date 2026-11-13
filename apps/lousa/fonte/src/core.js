// ===== Lousa: desenho em giz + conversão para a tela 960x640 preto e branco =====
(function (root) {
  const W = 960, H = 640, S = 2;
  const FONT = '"Caveat", "Bradley Hand", cursive';
  const WGT = '500 ';

  function rng(seed) {
    let s = seed >>> 0;
    return function () {
      s = (s + 0x6D2B79F5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function gauss(r) { let u = 0; while (!u) u = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r()); }
  function uni(r, a, b) { return a + (b - a) * r(); }
  function makeCanvas(w, h) {
    if (root.__makeCanvas) return root.__makeCanvas(w, h);
    const c = document.createElement('canvas'); c.width = w; c.height = h; return c;
  }
  function newMask() {
    const c = makeCanvas(W * S, H * S);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#000'; ctx.fillRect(0, 0, c.width, c.height);
    ctx.fillStyle = '#fff'; ctx.strokeStyle = '#fff';
    return { c, ctx };
  }
  function dot(ctx, x, y, r) { ctx.beginPath(); ctx.arc(x, y, Math.max(r, 0.5), 0, Math.PI * 2); ctx.fill(); }
  function tapered(ctx, x1, y1, x2, y2, w1, w2, steps) {
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      dot(ctx, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, (w1 + (w2 - w1) * t) / 2);
    }
  }

  // ---------- Relógio (modelo v10 aprovado) ----------
  function drawClock(ctx, h, m, r, numerals) {
    const cx = W / 2 * S, cy = (H / 2 + 8) * S, R = 262 * S;
    const seed = r() * 6;
    function circ(a0, a1, rr, dr, w) {
      const n = Math.floor(Math.abs(a1 - a0) / 1.5) + 2;
      for (let i = 0; i <= n; i++) {
        const t = i / n, a = (a0 + (a1 - a0) * t) * Math.PI / 180;
        const rad = rr + dr * t + R * 0.006 * Math.sin(3 * a + seed);
        dot(ctx, cx + rad * Math.cos(a), cy + rad * Math.sin(a), w);
      }
    }
    const start = uni(r, -150, -130);
    circ(start, start + 360, R, 0, 6.5 * S);
    circ(start - 5, start + uni(r, 38, 55), R + 2 * S, uni(r, 11, 15) * S, 5 * S);
    for (let k = 0; k < 12; k++) {
      const a = (k * 30 - 90 + uni(r, -2, 2)) * Math.PI / 180;
      const L = (k % 3 === 0 ? 62 : 34) * S, w = (k % 3 === 0 ? 15 : 14) * S;
      const out = R + L * 0.45, inn = R - L * 0.55;
      tapered(ctx, cx + out * Math.cos(a), cy + out * Math.sin(a), cx + inn * Math.cos(a), cy + inn * Math.sin(a), w, w, 20);
    }
    if (numerals) {
      ctx.save();
      ctx.font = '700 ' + (78 * S) + 'px ' + FONT;
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.lineWidth = 3 * S; ctx.lineJoin = 'round';
      [[0, '12'], [3, '3'], [6, '6'], [9, '9']].forEach(([k, t]) => {
        const a = (k * 30 - 90) * Math.PI / 180, rr = R - 100 * S;
        const x = cx + rr * Math.cos(a), y = cy + rr * Math.sin(a);
        ctx.save(); ctx.translate(x, y); ctx.rotate(uni(r, -0.05, 0.05));
        ctx.fillText(t, 0, 0); ctx.strokeText(t, 0, 0); ctx.restore();
      });
      ctx.restore();
    }
    function hand(ang, length, w0, w1) {
      const bend = uni(r, -0.03, 0.03);
      for (let pas = 0; pas < 3; pas++) {
        const off = uni(r, -2.5, 2.5) * S, ph = uni(r, 0, 6);
        const endt = pas === 0 ? 1 : uni(r, 0.8, 0.98);
        for (let i = 0; i <= 70; i++) {
          const t = endt * i / 70;
          const a = ang + bend * Math.sin(Math.PI * t);
          const rad = length * t;
          const px = cx + rad * Math.cos(a) + off * Math.cos(ang + Math.PI / 2);
          const py = cy + rad * Math.sin(a) + off * Math.sin(ang + Math.PI / 2);
          let w = (w0 + (w1 - w0) * t) * (1 + 0.08 * Math.sin(6 * t + ph) + 0.05 * Math.sin(15 * t + 2 * ph)) * (pas === 0 ? 1 : 0.75) / 2;
          w *= 1 + 0.10 * Math.exp(-Math.pow((t - 0.85) / 0.07, 2));
          dot(ctx, px, py, w);
        }
      }
    }
    const ah = ((h % 12) * 30 + m * 0.5 - 90) * Math.PI / 180, am = (m * 6 - 90) * Math.PI / 180;
    hand(ah, 141 * S, 25 * S, 22 * S);
    hand(am, 212 * S, 15 * S, 18 * S);
    for (let i = 0; i < 7; i++) {
      const ox = gauss(r) * 2.5 * S, oy = gauss(r) * 2.5 * S, rr = uni(r, 14, 19) * S;
      ctx.beginPath(); ctx.ellipse(cx + ox, cy + oy, rr, rr * uni(r, 0.85, 1), 0, 0, Math.PI * 2); ctx.fill();
    }
    return { x: W / 2, y: H / 2 + 8, rad: 245 };
  }

  // ---------- Texto (números, palavras) com a altura em primeiro lugar ----------
  function measure(ctx, text, F) {
    ctx.font = WGT + F + 'px ' + FONT;
    let w = 0, asc = 0, desc = 0; const ws = [];
    for (const ch of text) {
      const mm = ctx.measureText(ch);
      ws.push(mm.width);
      w += mm.width;
      asc = Math.max(asc, mm.actualBoundingBoxAscent || F * 0.7);
      desc = Math.max(desc, mm.actualBoundingBoxDescent || 0);
    }
    const whole = ctx.measureText(text);
    const inkL = whole.actualBoundingBoxLeft || 0;
    const inkR = whole.actualBoundingBoxRight || whole.width;
    const extra = Math.max(0, inkL + inkR - whole.width);   // parte da letra que passa da largura oficial
    return { w: w + extra, asc, desc, ws, extra, inkL, inkR: inkR - whole.width };
  }
  // devolve linhas posicionadas (em px da lousa) para caber em boxW x boxH
  function layoutText(ctx, text, boxW, boxH) {
    const tryLines = (lines) => {
      const base = 100;
      const ms = lines.map(l => measure(ctx, l, base));
      const lineH = Math.max(...ms.map(m => m.asc + m.desc)) * 1.08;
      const totalH = lineH * lines.length;
      let F = base * boxH / totalH;                        // altura em primeiro lugar
      let spacing = 0;
      const maxW = Math.max(...ms.map(m => m.w)) * F / base;
      if (maxW > boxW) {
        // 1º aproxima as letras (até -6% da altura), 2º só então diminui
        const n = Math.max(...lines.map(l => [...l].length));
        const need = (maxW - boxW) / Math.max(n - 1, 1);
        spacing = -Math.min(need, F * 0.06);
        const wNow = maxW + spacing * (n - 1);
        if (wNow > boxW) F = F * boxW / wNow, spacing = spacing * boxW / wNow;
      }
      return { lines, F, spacing, score: F * lines.length };
    };
    let best = tryLines([text]);
    const words = text.trim().split(/\s+/);
    if (words.length > 1) {
      for (let i = 1; i < words.length; i++) {
        const cand = tryLines([words.slice(0, i).join(' '), words.slice(i).join(' ')]);
        if (cand.F > best.F * 1.25) best = cand;
      }
    }
    return best;
  }
  function drawText(ctx, text, r, box) {
    box = box || { x: W / 2, y: H / 2, w: W * 0.86, h: H * 0.72 };
    const L = layoutText(ctx, text, box.w, box.h);
    const F = L.F;
    ctx.save();
    ctx.font = WGT + (F * S) + 'px ' + FONT;
    ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'left';
    ctx.lineJoin = 'round'; ctx.lineWidth = Math.max(1, F * 0.012) * S;
    const ms = L.lines.map(l => measure(ctx, l, F));
    const lineH = Math.max(...ms.map(m => m.asc + m.desc)) * 1.08;
    const totalH = lineH * L.lines.length;
    let top = box.y - totalH / 2;
    let minX = 1e9, maxX = -1e9;
    ctx.font = WGT + (F * S) + 'px ' + FONT;
    L.lines.forEach((line, li) => {
      const m = ms[li];
      const chars = [...line];
      const width = m.w + L.spacing * (chars.length - 1);
      const adv = m.w - (m.extra || 0);
      let x = box.x - (adv + L.spacing * (chars.length - 1) + (m.inkR || 0) - (m.inkL || 0)) / 2;
      const baseY = top + li * lineH + m.asc + (lineH - (m.asc + m.desc)) / 2;
      minX = Math.min(minX, x); maxX = Math.max(maxX, x + width);
      chars.forEach((ch, i) => {
        const cw = m.ws[i];
        ctx.save();
        ctx.translate((x + cw / 2) * S, (baseY + gauss(r) * F * 0.012) * S);
        ctx.rotate(uni(r, -0.05, 0.05));
        const sc = uni(r, 0.97, 1.03); ctx.scale(sc, sc);
        ctx.fillText(ch, -cw / 2 * S, 0); ctx.strokeText(ch, -cw / 2 * S, 0);
        ctx.restore();
        x += cw + L.spacing;
      });
    });
    ctx.restore();
    return { x: (minX + maxX) / 2, y: box.y, rad: Math.max(maxX - minX, totalH) / 2 + 30, F, lines: L.lines };
  }

  // ---------- Naipes desenhados ----------
  function suitPath(ctx, kind) {
    ctx.beginPath();
    if (kind === 'H') {
      ctx.moveTo(0, 0.92);
      ctx.bezierCurveTo(-1.0, 0.15, -1.05, -0.75, -0.5, -0.8);
      ctx.bezierCurveTo(-0.2, -0.83, 0, -0.6, 0, -0.4);
      ctx.bezierCurveTo(0, -0.6, 0.2, -0.83, 0.5, -0.8);
      ctx.bezierCurveTo(1.05, -0.75, 1.0, 0.15, 0, 0.92);
    } else if (kind === 'D') {
      ctx.moveTo(0, -1);
      ctx.quadraticCurveTo(0.28, -0.4, 0.74, 0);
      ctx.quadraticCurveTo(0.28, 0.4, 0, 1);
      ctx.quadraticCurveTo(-0.28, 0.4, -0.74, 0);
      ctx.quadraticCurveTo(-0.28, -0.4, 0, -1);
    } else if (kind === 'S') {
      ctx.moveTo(0, -0.95);
      ctx.bezierCurveTo(-0.95, -0.25, -1.0, 0.38, -0.5, 0.45);
      ctx.bezierCurveTo(-0.25, 0.48, -0.08, 0.35, 0, 0.2);
      ctx.bezierCurveTo(0.08, 0.35, 0.25, 0.48, 0.5, 0.45);
      ctx.bezierCurveTo(1.0, 0.38, 0.95, -0.25, 0, -0.95);
      ctx.moveTo(0, 0.12);
      ctx.quadraticCurveTo(0.06, 0.72, 0.4, 0.95);
      ctx.lineTo(-0.4, 0.95);
      ctx.quadraticCurveTo(-0.06, 0.72, 0, 0.12);
    } else { // C (paus)
      ctx.moveTo(0.36, -0.5); ctx.arc(0, -0.5, 0.36, 0, Math.PI * 2);
      ctx.moveTo(-0.1, 0.12); ctx.arc(-0.46, 0.12, 0.36, 0, Math.PI * 2);
      ctx.moveTo(0.82, 0.12); ctx.arc(0.46, 0.12, 0.36, 0, Math.PI * 2);
      ctx.moveTo(-0.2, -0.3); ctx.lineTo(0.2, -0.3); ctx.lineTo(0.25, 0.2); ctx.lineTo(-0.25, 0.2); ctx.closePath();
      ctx.moveTo(0, 0.0);
      ctx.quadraticCurveTo(0.06, 0.72, 0.4, 0.95);
      ctx.lineTo(-0.4, 0.95);
      ctx.quadraticCurveTo(-0.06, 0.72, 0, 0.0);
    }
  }
  function drawSuit(ctx, kind, cx, cy, size, r) {
    // size = altura total em px da lousa
    const k = size / 2 * S;
    ctx.save();
    ctx.translate(cx * S, cy * S);
    ctx.rotate(uni(r, -0.06, 0.06));
    ctx.scale(k * uni(r, 0.97, 1.03), k);
    suitPath(ctx, kind);
    ctx.fillStyle = '#fff';
    ctx.fill('nonzero');
    ctx.lineWidth = 0.04; ctx.strokeStyle = '#fff'; ctx.stroke();
    // giz passado de lado: alguns riscos escuros dentro do desenho
    ctx.save();
    suitPath(ctx, kind); ctx.clip();
    ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.lineCap = 'round';
    ctx.setLineDash([0.08, 0.05]);
    const n = 5 + Math.floor(r() * 4);
    for (let i = 0; i < n; i++) {
      const y0 = uni(r, -0.8, 0.8), x0 = uni(r, -0.8, 0.3), len = uni(r, 0.15, 0.45), ang = uni(r, -0.5, 0.2);
      ctx.lineWidth = uni(r, 0.012, 0.028);
      ctx.beginPath(); ctx.moveTo(x0, y0);
      ctx.quadraticCurveTo(x0 + len / 2, y0 + uni(r, -0.05, 0.05), x0 + len * Math.cos(ang), y0 + len * Math.sin(ang));
      ctx.stroke();
    }
    ctx.restore();
    ctx.restore();
  }

  // ---------- Carta ----------
  const VALOR_NOME = { A: 'Ás', '2': 'Dois', '3': 'Três', '4': 'Quatro', '5': 'Cinco', '6': 'Seis', '7': 'Sete', '8': 'Oito', '9': 'Nove', '10': 'Dez', J: 'Valete', Q: 'Dama', K: 'Rei' };
  const NAIPE_NOME = { H: 'Copas', S: 'Espadas', D: 'Ouros', C: 'Paus' };
  function cardName(v, s) { return VALOR_NOME[v] + ' de ' + NAIPE_NOME[s]; }
  function drawCard(ctx, v, s, r) {
    const Ht = H * 0.72;
    const L = layoutText(ctx, v, W, Ht);
    const m = measure(ctx, v, L.F);
    const textW = m.w + L.spacing * ([...v].length - 1);
    const suitH = Ht * 0.86, suitW = suitH * 1.12;
    const gap = W * 0.05;
    let total = textW + gap + suitW, scale = 1;
    if (total > W * 0.88) scale = W * 0.88 / total;
    const x0 = W / 2 - total * scale / 2;
    const box = { x: x0 + textW * scale / 2, y: H / 2, w: textW * scale + 2, h: Ht * scale };
    drawText(ctx, v, r, box);
    drawSuit(ctx, s, x0 + (textW + gap + suitW / 2) * scale, H / 2 + 4, suitH * scale, r);
    return { x: W / 2, y: H / 2, rad: total * scale / 2 + 30 };
  }

  // ---------- Traço livre (escrita manual) ----------
  function drawStrokes(ctx, strokes, r) {
    if (strokes.norm) {                                       // exato como na moldura do celular
      const lw = strokes.lw || 15;
      strokes.list.forEach(st => {
        const P = st.map(p => ({ x: p.x * W, y: p.y * H }));
        if (P.length === 1) { dot(ctx, P[0].x * S, P[0].y * S, lw / 2 * S); return; }
        for (let i = 1; i < P.length; i++) {
          const a = P[i - 1], b = P[i], n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / 2));
          for (let j = 0; j <= n; j++) { const t = j / n; dot(ctx, (a.x + (b.x - a.x) * t) * S, (a.y + (b.y - a.y) * t) * S, lw / 2 * S * (0.92 + 0.16 * r())); }
        }
      });
      return { x: W / 2, y: H / 2, rad: 300 };
    }
    let minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
    strokes.forEach(st => st.forEach(p => { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); }));
    if (!(maxX >= minX)) return null;
    const bw = Math.max(maxX - minX, 1), bh = Math.max(maxY - minY, 1);
    const sc = Math.min(W * 0.88 / bw, H * 0.8 / bh);
    const ox = W / 2 - (minX + bw / 2) * sc, oy = H / 2 - (minY + bh / 2) * sc;
    const lw = 15;
    strokes.forEach(st => {
      if (st.length === 1) { dot(ctx, (st[0].x * sc + ox) * S, (st[0].y * sc + oy) * S, lw / 2 * S); return; }
      for (let i = 1; i < st.length; i++) {
        const a = st[i - 1], b = st[i];
        const x1 = (a.x * sc + ox), y1 = (a.y * sc + oy), x2 = (b.x * sc + ox), y2 = (b.y * sc + oy);
        const n = Math.max(1, Math.ceil(Math.hypot(x2 - x1, y2 - y1) / 2));
        for (let j = 0; j <= n; j++) {
          const t = j / n;
          dot(ctx, (x1 + (x2 - x1) * t) * S, (y1 + (y2 - y1) * t) * S, lw / 2 * S * (0.92 + 0.16 * r()));
        }
      }
    });
    return { x: W / 2, y: H / 2, rad: Math.max(bw * sc, bh * sc) / 2 + 30 };
  }

  // ---------- Giz: grão, pó e conversão para bits ----------
  function chalkify(mask, r, opts, focus) {
    const small = makeCanvas(W, H);
    const sctx = small.getContext('2d');
    sctx.imageSmoothingEnabled = true;
    if ('imageSmoothingQuality' in sctx) sctx.imageSmoothingQuality = 'high';
    sctx.drawImage(mask, 0, 0, W, H);
    const src = sctx.getImageData(0, 0, W, H).data;
    const a = new Float32Array(W * H);
    for (let i = 0; i < W * H; i++) a[i] = src[i * 4] / 255;
    // desfoque leve (bordas do giz)
    const b = new Float32Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      let s = 0, c = 0;
      for (let dy = -1; dy <= 1; dy++) { const yy = y + dy; if (yy < 0 || yy >= H) continue;
        for (let dx = -1; dx <= 1; dx++) { const xx = x + dx; if (xx < 0 || xx >= W) continue;
          const wgt = (dx === 0 ? 2 : 1) * (dy === 0 ? 2 : 1); s += a[yy * W + xx] * wgt; c += wgt; } }
      b[y * W + x] = a[y * W + x] * 0.55 + (s / c) * 0.45;
    }
    const gw = (W >> 1) + 1, gh = (H >> 1) + 1;
    const g = new Float32Array(gw * gh); for (let i = 0; i < g.length; i++) g[i] = r();
    const px = new Uint8Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x;
      const p = Math.min(1, Math.max(0, (b[i] - 0.3) / 0.5)) * 0.74;
      const grain = g[(y >> 1) * gw + (x >> 1)] * 0.8 + r() * 0.2;
      if (grain < p) px[i] = 1;
    }
    if (opts.dust) {
      if (opts.under) {                                     // 1º envio depois de limpar: mesmas marcas por baixo
        for (let i = 0; i < W * H; i++) if (opts.under[i]) px[i] = 1;
        addDust(px, r, focus || { x: W / 2, y: H / 2, rad: 245 }, 'none', 0.4);
      } else addDust(px, r, focus || { x: W / 2, y: H / 2, rad: 245 }, 'auto', 1);
    }
    return px;
  }

  // ---------- Sujeirinha (aleatória a cada envio, como giz de verdade) ----------
  const SPECKS = [[[0, 0]], [[0, 0], [1, 0]], [[0, 0], [1, 1], [2, 0]], [[0, 0], [0, 1]], [[0, 0], [1, 0], [2, 0]], [[0, 1], [1, 0], [2, 1]], [[0, 0], [1, 1]]];
  function speck(px, r, x, y) {
    const sh = SPECKS[Math.floor(r() * SPECKS.length)];
    for (const [dx, dy] of sh) { const xx = x + dx, yy = y + dy; if (xx >= 0 && xx < W && yy >= 0 && yy < H) px[yy * W + xx] = 1; }
  }
  function addDust(px, r, f, streaks, amount) {
    // 1) grupinhos de pó pela lousa toda, um pouco mais perto do desenho
    const n = Math.round((80 + Math.floor(r() * 50)) * (amount == null ? 1 : amount));
    for (let k = 0; k < n; k++) {
      let x0, y0;
      if (r() < 0.45) { const a = r() * 6.283, rr = Math.sqrt(r()) * f.rad * 1.15; x0 = f.x + rr * Math.cos(a); y0 = f.y + rr * Math.sin(a) * 0.9; }
      else { x0 = r() * W; y0 = r() * H; }
      const sx = uni(r, 5, 18), cnt = 5 + Math.floor(r() * 22);
      for (let j = 0; j < cnt; j++) speck(px, r, Math.floor(x0 + gauss(r) * sx), Math.floor(y0 + gauss(r) * sx * 0.75));
    }
    // 2) nuvens fracas (pó espalhado)
    const clouds = Math.round((2 + Math.floor(r() * 4)) * (amount == null ? 1 : Math.max(amount, 0.5)));
    for (let k = 0; k < clouds; k++) {
      const near = r() < 0.6;
      const cx = near ? f.x + gauss(r) * f.rad * 0.5 : r() * W, cy = near ? f.y + gauss(r) * f.rad * 0.4 : r() * H;
      const rx = uni(r, 50, 130), ry = rx * uni(r, 0.5, 0.9), cnt = Math.floor(rx * ry * uni(r, 0.006, 0.014));
      for (let j = 0; j < cnt; j++) { const a = r() * 6.283, d = Math.sqrt(r()); speck(px, r, Math.floor(cx + Math.cos(a) * d * rx), Math.floor(cy + Math.sin(a) * d * ry)); }
    }
    // 3) às vezes, riscos de apagador na diagonal (fracos ou fortes)
    // auto: de vez em quando e leves · heavy: lousa recém-apagada
    const roll = r();
    const groups = streaks === 'heavy' ? 6 + Math.floor(r() * 5) : streaks === 'auto' ? (roll < 0.7 ? 0 : 2 + Math.floor(r() * 3)) : 0;
    for (let g = 0; g < groups; g++) {
      const ang = -uni(r, 0.35, 0.95);                      // sobe para a direita
      const len = uni(r, 70, 300), lines = 3 + Math.floor(r() * 6), gap = uni(r, 3, 7);
      const x0 = r() * W, y0 = r() * H, dens = uni(r, 0.25, 0.65);
      const ca = Math.cos(ang), sa = Math.sin(ang), nx = -sa, ny = ca;
      for (let l = 0; l < lines; l++) {
        const off = (l - lines / 2) * gap + gauss(r) * 1.5, lenL = len * uni(r, 0.5, 1), st = uni(r, 0, len - lenL);
        let on = r() < 0.7;
        for (let t = st; t < st + lenL; t += 1.6) {
          if (r() < 0.04) on = !on;                           // falhas no risco
          if (on && r() < dens) speck(px, r, Math.floor(x0 + ca * t + nx * off), Math.floor(y0 + sa * t + ny * off));
        }
      }
      if (r() < 0.4) {                                        // mancha mais cheia em volta do risco
        const cx = x0 + ca * len * 0.5, cy = y0 + sa * len * 0.5, rx = uni(r, 30, 80), ry = rx * 0.5;
        const cnt = Math.floor(rx * ry * 0.05);
        for (let j = 0; j < cnt; j++) { const a = r() * 6.283, d = Math.sqrt(r()); const u = Math.cos(a) * d * rx, v = Math.sin(a) * d * ry; speck(px, r, Math.floor(cx + u * ca - v * sa), Math.floor(cy + u * sa + v * ca)); }
      }
    }
  }
  // bits como o app oficial faz: linha a linha, 8 pontos por byte, 1º ponto no bit mais alto, branco = 1
  function packBits(px, rotate180) {
    const out = new Uint8Array(W * H / 8);
    for (let i = 0; i < W * H; i++) {
      const v = rotate180 ? px[W * H - 1 - i] : px[i];
      if (v) out[i >> 3] |= 0x80 >> (i & 7);
    }
    return out;
  }
  // centraliza pelo desenho real e deixa o mais alto possível (limitado pelas margens laterais)
  function fitMask(c, maxHf, maxWf, grow) {
    const ctx = c.getContext('2d');
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
    for (let y = 0; y < c.height; y += 2) for (let x = 0; x < c.width; x += 2) {
      if (d[(y * c.width + x) * 4] > 60) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    }
    if (x1 < 0) return { c, focus: null };
    const bw = x1 - x0 + 2, bh = y1 - y0 + 2, CW = W * S, CH = H * S;
    let sy = maxHf * CH / bh; if (!grow) sy = Math.min(sy, 1);
    let sx = sy;
    if (bw * sx > maxWf * CW) {
      sx = Math.max(maxWf * CW / bw, sy * 0.85);              // 1º estreita um pouco (até 15%)
      if (bw * sx > maxWf * CW) { const k = maxWf * CW / (bw * sx); sx *= k; sy *= k; }  // 2º diminui
    }
    const out = makeCanvas(CW, CH), o = out.getContext('2d');
    o.fillStyle = '#000'; o.fillRect(0, 0, CW, CH);
    o.imageSmoothingEnabled = true;
    o.drawImage(c, x0, y0, bw, bh, CW / 2 - bw * sx / 2, CH / 2 - bh * sy / 2, bw * sx, bh * sy);
    return { c: out, focus: { x: W / 2, y: H / 2, rad: Math.max(bw * sx, bh * sy) / S / 2 + 30 } };
  }

  // ===== letra do Ricardo (traços gravados no app) e naipes desenhados por ele =====
  let HAND = null, SUITS = null;
  function setHand(g) { HAND = g; }
  function setSuits(o) { SUITS = o; }
  const HG = (c) => {
    if ('0123456789'.includes(c)) return 'dig';
    if ('ABCDEFGHIJKLMNOPQRSTUVWXYZ?!/'.includes(c)) return 'cap';
    if ('ÁÉÍÓÚÂÊÔÃÕÀ'.includes(c)) return 'capAcc';
    if (c === 'Ç') return 'capCed';
    if ('bdfhklt'.includes(c)) return 'asc';
    if ('gjpqy'.includes(c)) return 'desc';
    if ('áéíóúâêôãõà'.includes(c) || c === 'i') return 'lowAcc';
    if (c === 'ç') return 'lowCed';
    if (c === ':') return 'colon'; if (c === '-') return 'dash';
    return 'low';
  };
  const HSPEC = { dig: [1, 0], cap: [1, 0], capAcc: [1.28, 0], capCed: [1.22, 0.22], asc: [1, 0], desc: [0.95, 0.35], low: [0.6, 0], lowAcc: [0.9, 0], lowCed: [0.8, 0.22], colon: [0.62, 0] };
  function sbox(st) { let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9; st.forEach(s => s.forEach(p => { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); })); return { x0, x1, y0, y1 }; }
  function handLine(text, rnd, tight) {
    const out = []; let pen = 0; const last = {}, T = [...text];
    const nd = T.filter(c => c >= '0' && c <= '9').length;
    const dGap = tight ? 0.12 : nd <= 5 ? 0.26 : Math.max(0.19, 0.26 - (nd - 5) * 0.02);   // número comprido: aproxima um pouco
    for (let ci = 0; ci < T.length; ci++) {
      const c = T[ci];
      if (c === ' ') { pen += 0.45; continue; }
      const vs = (HAND[c] || []).filter(v => v && v.length); if (!vs.length) { pen += 0.4; continue; }
      let i = Math.floor(rnd() * vs.length); if (vs.length > 1 && i === last[c]) i = (i + 1) % vs.length; last[c] = i;
      const gl = vs[i], b = sbox(gl), grp = HG(c);
      const hora = c === 'h' && /[0-9]/.test(T[ci - 1] || '') && /[0-9]/.test(T[ci + 1] || '');   // "h" de hora: menor e mais perto
      if (grp === 'dash') {
        const k = 0.32 / Math.max(b.x1 - b.x0, 0.01), cy = (b.y0 + b.y1) / 2;
        gl.forEach(s => out.push(s.map(p => [pen + (p[0] - b.x0) * k, -0.35 + (p[1] - cy) * k]))); pen += 0.44; continue;
      }
      const sp = HSPEC[grp], Hh = (hora ? sp[0] * 0.75 : sp[0]) * (1 + (rnd() - 0.5) * 0.08);
      const k = Hh / Math.max(b.y1 - b.y0, 0.02), base = sp[1] + (rnd() - 0.5) * 0.04;
      gl.forEach(s => out.push(s.map(p => [pen + (p[0] - b.x0) * k, base - (b.y1 - p[1]) * k])));
      pen += (b.x1 - b.x0) * k + (grp === 'dig' ? (T[ci + 1] === 'h' ? 0.17 : dGap) : hora ? 0.17 : 0.13);
    }
    return out;
  }
  function handBlock(text, rnd) {                       // nomes compostos: duas linhas
    const words = text.trim().split(/\s+/);
    if (words.length < 2) return { st: handLine(text, rnd), lines: 1 };
    let best = 1, bd = 1e9;
    for (let i = 1; i < words.length; i++) { const d = Math.abs(words.slice(0, i).join(' ').length - words.slice(i).join(' ').length); if (d < bd) { bd = d; best = i; } }
    const out = [];
    [words.slice(0, best).join(' '), words.slice(best).join(' ')].forEach((t, n) => {
      const st = handLine(t, rnd), b = sbox(st), cx = (b.x0 + b.x1) / 2;
      st.forEach(s => out.push(s.map(p => [p[0] - cx, p[1] + n * 1.55])));
    });
    return { st: out, lines: 2 };
  }
  function strokeHand(ctx, st, s, ox, oy, lw) {
    ctx.save(); ctx.strokeStyle = '#fff'; ctx.fillStyle = '#fff'; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.lineWidth = lw * S;
    st.forEach(seg => {
      if (seg.length === 1) { dot(ctx, (seg[0][0] * s + ox) * S, (seg[0][1] * s + oy) * S, lw / 2 * S); return; }
      ctx.beginPath(); seg.forEach((p, i) => { const X = (p[0] * s + ox) * S, Y = (p[1] * s + oy) * S; if (i) ctx.lineTo(X, Y); else ctx.moveTo(X, Y); }); ctx.stroke();
    });
    ctx.restore();
  }
  const handLW = (s) => Math.max(9, Math.min(17, s * 0.058));
  function drawHandText(ctx, text, r, size) {
    const k = size || 1, blk = handBlock(text, r), b = sbox(blk.st), bw = b.x1 - b.x0, bh = b.y1 - b.y0;
    let s = (blk.lines === 2 ? 0.8 : 0.52) * H / bh; if (bw * s > 0.88 * W) s = 0.88 * W / bw; s *= k;
    const ox = W / 2 - (b.x0 + bw / 2) * s, oy = H / 2 - (b.y0 + bh / 2) * s;
    strokeHand(ctx, blk.st, s, ox, oy, handLW(s));
    return { x: W / 2, y: H / 2, rad: Math.max(bw, bh) * s / 2 + 30 };
  }
  function drawHandCard(ctx, v, suit, r, size) {
    const k = size || 1, st = handLine(v, r, true), b = sbox(st), vw = b.x1 - b.x0, vh = b.y1 - b.y0;
    const img = SUITS[suit];
    let h = 0.52 * H * k, s = h / vh, sw = img.width * h / img.height, gap = 0.035 * W * k;
    let tot = vw * s + gap + sw;
    if (tot > 0.88 * W) { const f = 0.88 * W / tot; s *= f; h *= f; sw *= f; gap *= f; tot = 0.88 * W; }
    const x0 = (W - tot) / 2, y0 = (H - h) / 2;
    strokeHand(ctx, st, s, x0 - b.x0 * s, y0 - b.y0 * s, handLW(s));
    ctx.drawImage(img, (x0 + vw * s + gap) * S, y0 * S, sw * S, h * S);
    return { x: W / 2, y: H / 2, rad: tot / 2 + 30 };
  }

  // ===== quadrado mágico 4×4: linhas, colunas, diagonais, centro, cantos e quadrantes somam N =====
  function magicSquare(N, r) {
    let q = [[N - 20, 1, 12, 7], [11, 8, N - 21, 2], [5, 10, 3, N - 18], [4, N - 19, 6, 9]];
    const rot = (m) => m[0].map((_, c) => m.map(row => row[c]).reverse());
    const k = Math.floor(r() * 4); for (let i = 0; i < k; i++) q = rot(q);    // gira e espelha ao acaso
    if (r() < 0.5) q = q.map(row => row.slice().reverse());
    return q;
  }
  function checkSquare(q, N) {
    const sums = [];
    for (let i = 0; i < 4; i++) { sums.push(q[i].reduce((a, b) => a + b, 0)); sums.push(q[0][i] + q[1][i] + q[2][i] + q[3][i]); }
    sums.push(q[0][0] + q[1][1] + q[2][2] + q[3][3], q[0][3] + q[1][2] + q[2][1] + q[3][0]);
    sums.push(q[1][1] + q[1][2] + q[2][1] + q[2][2], q[0][0] + q[0][3] + q[3][0] + q[3][3]);
    [[0, 0], [0, 2], [2, 0], [2, 2]].forEach(([a, b]) => sums.push(q[a][b] + q[a][b + 1] + q[a + 1][b] + q[a + 1][b + 1]));
    const flat = q.flat();
    return sums.every(x => x === N) && flat.every(x => x > 0) && new Set(flat).size === 16;
  }
  function drawSquare(ctx, N, r, size, line) {
    const q = magicSquare(N, r), side = 0.86 * H * (size || 1), cs = side / 4, x0 = (W - side) / 2, y0 = (H - side) / 2;
    const glw = 8 * (line || 1);
    // grade a giz, levemente torta
    const grid = [];
    for (let i = 0; i <= 4; i++) {
      const a = [], b = [];
      for (let t = 0; t <= 12; t++) {
        const u = -6 + t * (side + 12) / 12;
        a.push([x0 + i * cs + (r() - 0.5) * 3, y0 + u]); b.push([x0 + u, y0 + i * cs + (r() - 0.5) * 3]);
      }
      grid.push(a, b);
    }
    strokeHand(ctx, grid, 1, 0, 0, glw);
    if (HAND) q.forEach((row, ri) => row.forEach((v, ci) => {
      const st = handLine(String(v), r), b = sbox(st), bw = b.x1 - b.x0, bh = b.y1 - b.y0;
      let s = cs * 0.48 / bh; if (bw * s > cs * 0.7) s = cs * 0.7 / bw;
      const cx = x0 + ci * cs + cs / 2 + (r() - 0.5) * 4, cy = y0 + ri * cs + cs / 2 + (r() - 0.5) * 4;
      strokeHand(ctx, st, s, cx - (b.x0 + bw / 2) * s, cy - (b.y0 + bh / 2) * s, Math.max(6, Math.min(12, s * 0.07)));
    }));
    else q.forEach((row, ri) => row.forEach((v, ci) => { ctx.save(); ctx.fillStyle = '#fff'; ctx.font = WGT + Math.round(cs * 0.5 * S) + 'px ' + FONT; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(String(v), (x0 + ci * cs + cs / 2) * S, (y0 + ri * cs + cs / 2) * S); ctx.restore(); }));
    return { x: W / 2, y: H / 2, rad: side / 2 + 20 };
  }
  function scaleMask(c, k) {                          // relógio menor: encolhe pelo centro
    const out = makeCanvas(c.width, c.height), o = out.getContext('2d');
    o.fillStyle = '#000'; o.fillRect(0, 0, out.width, out.height); o.imageSmoothingEnabled = true;
    o.drawImage(c, (1 - k) * c.width / 2, (1 - k) * c.height / 2, c.width * k, c.height * k);
    return out;
  }
  function render(kind, data, opts) {
    const r = rng((opts.seed != null ? opts.seed : (Date.now() ^ (Math.random() * 1e9))) >>> 0);
    const { c, ctx } = newMask();
    let focus = null;
    if (kind === 'clock') focus = drawClock(ctx, data.h, data.m, r, opts.numerals);
    const useHand = !!HAND && (kind === 'text' || (kind === 'card' && (data.full || SUITS)));
    const sz = opts.size ? Math.min(1, Math.max(0.3, opts.size)) : 1;
    if (useHand && kind === 'text') focus = drawHandText(ctx, data.text, r, sz);
    else if (useHand && kind === 'card') focus = data.full ? drawHandText(ctx, cardName(data.v, data.s), r, sz) : drawHandCard(ctx, data.v, data.s, r, sz);
    else if (kind === 'text') focus = drawText(ctx, data.text, r);
    else if (kind === 'card') focus = data.full ? drawText(ctx, cardName(data.v, data.s), r) : drawCard(ctx, data.v, data.s, r);
    else if (kind === 'strokes') focus = drawStrokes(ctx, data.strokes, r);
    else if (kind === 'square') focus = drawSquare(ctx, data.n, r, sz, opts.line);
    let mask = c;
    const k = kind === 'card' && opts.size ? Math.min(1, Math.max(0.3, opts.size)) : 1;   // tamanho escolhido na barra
    if (kind === 'clock' && sz < 1) { mask = scaleMask(c, sz); focus = { x: W / 2, y: H / 2, rad: 270 * sz }; }
    else if (kind === 'square') { /* já no tamanho certo */ }
    else if (useHand) { /* já posicionado e no tamanho certo */ }
    else if (kind === 'text' || (kind === 'card' && data.full)) { const f = fitMask(c, 0.78 * k, 0.88 * k, true); mask = f.c; focus = f.focus || focus; }
    else if (kind === 'card') { const f = fitMask(c, 0.78 * k, 0.9 * k, true); mask = f.c; focus = f.focus || focus; }
    if (kind === 'clear') {
      const px = new Uint8Array(W * H);
      if (opts.dust) addDust(px, r, { x: W / 2, y: H / 2, rad: 330 }, 'heavy', 0.6);
      return { px, bytes: packBits(px, !!opts.rotate180) };
    }
    const px = chalkify(mask, r, opts, focus);
    return { px, bytes: packBits(px, !!opts.rotate180) };
  }
  function drawPreview(canvas, px) {
    canvas.width = W; canvas.height = H;
    const ctx = canvas.getContext('2d');
    const img = ctx.createImageData(W, H);
    for (let i = 0; i < W * H; i++) {
      const v = px[i] ? 236 : 14;
      img.data[i * 4] = v; img.data[i * 4 + 1] = v; img.data[i * 4 + 2] = px[i] ? 228 : 16; img.data[i * 4 + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
  }

  // ---------- Dias vividos (só datas de calendário) ----------
  function daysLived(dd, mm, aa, now) {
    now = now || new Date();
    const yy = (aa > now.getFullYear() % 100 ? 1900 : 2000) + aa;
    const t = Date.UTC(yy, mm - 1, dd);
    const c = new Date(t);
    if (c.getUTCFullYear() !== yy || c.getUTCMonth() !== mm - 1 || c.getUTCDate() !== dd) return null;
    const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
    const n = Math.round((today - t) / 86400000);
    return n < 0 ? null : n;
  }

  const api = { W, H, render, drawPreview, daysLived, cardName, rng, setHand, setSuits, hasHand: () => !!HAND, magicSquare, checkSquare };
  if (typeof module !== 'undefined') module.exports = api; else root.Lousa = api;
})(typeof window !== 'undefined' ? window : globalThis);
