// QuickLZ 1.5.0, nivel 1, buffer de streaming 64, 64 valores de hash.
// Mesmo formato usado pelo Inversion Board (lib "ble_jni" do app PITATA Pro).
// A imagem e comprimida em pedacos de 64 bytes, com 4 bytes (tamanho original) na frente.
(function (root) {
  const HASH_VALUES = 64;
  const UNCONDITIONAL_MATCHLEN = 6;
  const UNCOMPRESSED_END = 4;
  const MINOFFSET = 2;
  const CWORD_LEN = 4;

  function hashFunc(i) {
    return ((i >>> 12) ^ i) & (HASH_VALUES - 1);
  }

  function newState() {
    return {
      cache: new Uint32Array(HASH_VALUES),
      offset: new Int32Array(HASH_VALUES).fill(-1), // -1 = vazio
      buf: new Uint8Array(64),
      counter: 0,
    };
  }

  function resetTable(st) {
    st.offset.fill(-1);
  }

  function write32(d, p, v) {
    d[p] = v & 255; d[p + 1] = (v >>> 8) & 255; d[p + 2] = (v >>> 16) & 255; d[p + 3] = (v >>> 24) & 255;
  }
  function write16(d, p, v) { d[p] = v & 255; d[p + 1] = (v >>> 8) & 255; }
  function write24(d, p, v) { d[p] = v & 255; d[p + 1] = (v >>> 8) & 255; d[p + 2] = (v >>> 16) & 255; }

  // Comprime "size" bytes de s (a partir de 0). Retorna o numero de bytes gravados em out (a partir de outPos),
  // ou 0 se nao compensa comprimir.
  function core(s, size, out, outPos, st) {
    const lastByte = size - 1;
    let src = 0;
    let cwordPtr = outPos;
    let dst = outPos + CWORD_LEN;
    let cword = 0x80000000 >>> 0;
    const lastMatchStart = lastByte - UNCONDITIONAL_MATCHLEN - UNCOMPRESSED_END;
    let fetch = 0;
    let lits = 0;
    const rd3 = (p) => s[p] | (s[p + 1] << 8) | (s[p + 2] << 16);
    const same = (p, n) => { for (let k = n; k > 0; k--) if (s[p + k] !== s[p]) return false; return true; };

    if (src <= lastMatchStart) fetch = rd3(src);
    while (src <= lastMatchStart) {
      if ((cword & 1) === 1) {
        if (src > (size >> 1) && (dst - outPos) > src - (src >> 5)) return 0;
        write32(out, cwordPtr, ((cword >>> 1) | 0x80000000) >>> 0);
        cwordPtr = dst;
        dst += CWORD_LEN;
        cword = 0x80000000 >>> 0;
        fetch = rd3(src);
      }
      let hash = hashFunc(fetch);
      const cached = (fetch ^ st.cache[hash]) >>> 0;
      st.cache[hash] = fetch;
      const o = st.offset[hash];
      st.offset[hash] = src;
      if (cached === 0 && o !== -1 &&
          (src - o > MINOFFSET || (src === o + 1 && lits >= 3 && src > 3 && same(src - 3, 6)))) {
        if (s[o + 3] !== s[src + 3]) {
          hash <<= 4;
          cword = ((cword >>> 1) | 0x80000000) >>> 0;
          write16(out, dst, (3 - 2) | hash);
          src += 3;
          dst += 2;
        } else {
          const oldSrc = src;
          hash <<= 4;
          cword = ((cword >>> 1) | 0x80000000) >>> 0;
          src += 4;
          if (s[o + (src - oldSrc)] === s[src]) {
            src++;
            if (s[o + (src - oldSrc)] === s[src]) {
              const q = lastByte - UNCOMPRESSED_END - (src - 5) + 1;
              const remaining = q > 255 ? 255 : q;
              src++;
              while (s[o + (src - oldSrc)] === s[src] && (src - oldSrc) < remaining) src++;
            }
          }
          const matchlen = src - oldSrc;
          if (matchlen < 18) {
            write16(out, dst, (matchlen - 2) | hash);
            dst += 2;
          } else {
            write24(out, dst, ((matchlen << 16) | hash) >>> 0);
            dst += 3;
          }
        }
        fetch = rd3(src);
        lits = 0;
      } else {
        lits++;
        out[dst++] = s[src++];
        cword = cword >>> 1;
        fetch = ((fetch >>> 8) & 0xffff) | (s[src + 2] << 16);
      }
    }
    while (src <= lastByte) {
      if ((cword & 1) === 1) {
        write32(out, cwordPtr, ((cword >>> 1) | 0x80000000) >>> 0);
        cwordPtr = dst;
        dst += CWORD_LEN;
        cword = 0x80000000 >>> 0;
      }
      if (src <= lastByte - 3) {
        const f = rd3(src);
        const h = hashFunc(f);
        st.offset[h] = src;
        st.cache[h] = f;
      }
      out[dst++] = s[src++];
      cword = cword >>> 1;
    }
    while ((cword & 1) !== 1) cword = cword >>> 1;
    write32(out, cwordPtr, ((cword >>> 1) | 0x80000000) >>> 0);
    const n = dst - outPos;
    return n < 9 ? 9 : n;
  }

  // Igual a qlz_compress() com streaming de 64 bytes.
  function compressChunk(chunk, out, outPos, st) {
    const size = chunk.length;
    const base = size < 216 ? 3 : 9;
    let r, compressed;
    // copia para o buffer interno (os ponteiros "o" apontam para la)
    let s;
    if (st.counter + size - 1 >= 64) {
      resetTable(st);
      s = chunk;
      const n = core(s, size, out, outPos + base, st);
      resetTable(st);
      if (n === 0) {
        out.set(chunk, outPos + base);
        r = size + base; compressed = 0;
      } else { r = n + base; compressed = 1; }
      st.counter = 0;
    } else {
      // regiao do buffer a partir de st.counter (aqui sempre 0, pois os pedacos tem 64 bytes)
      st.buf.set(chunk, st.counter);
      s = st.counter === 0 ? st.buf.subarray(0, size) : st.buf.subarray(st.counter, st.counter + size);
      const n = core(s, size, out, outPos + base, st);
      if (n === 0) {
        out.set(chunk, outPos + base);
        r = size + base; compressed = 0;
        resetTable(st);
      } else { r = n + base; compressed = 1; }
      st.counter += size;
    }
    if (base === 3) {
      out[outPos] = 0 | compressed;
      out[outPos + 1] = r & 255;
      out[outPos + 2] = size & 255;
    } else {
      out[outPos] = 2 | compressed;
      write32(out, outPos + 1, r);
      write32(out, outPos + 5, size);
    }
    out[outPos] |= (1 << 2) | (1 << 6) | (3 << 4);
    return r;
  }

  // Igual ao "compress" nativo: [tamanho original u32 LE] + pedacos de 64 bytes comprimidos.
  function boardCompress(data) {
    const st = newState();
    const out = new Uint8Array(4 + Math.ceil(data.length / 64) * (64 + 400));
    write32(out, 0, data.length);
    let pos = 4;
    for (let i = 0; i < data.length; i += 64) {
      const chunk = data.subarray(i, Math.min(i + 64, data.length));
      pos += compressChunk(chunk, out, pos, st);
    }
    return out.slice(0, pos);
  }

  const api = { boardCompress };
  if (typeof module !== 'undefined') module.exports = api; else root.QLZ = api;
})(this);
