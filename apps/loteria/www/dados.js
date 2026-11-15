/* Loterias — jogos, datas, prêmios (busca na internet + valores de reserva) */
'use strict';

const JOGOS = [
  {id:'virada', api:'megasena', nome:'mega da virada', cor:'#008d41', cor2:'#00a055', premioCor:'#07a54f', total:60, base:6, max:20, preco:6, virada:true},
  {id:'megasena', api:'megasena', nome:'mega-sena', cor:'#008d41', cor2:'#009b48', premioCor:'#09ab56', total:60, base:6, max:20, preco:6, dias:[0,2,4], ref:[3087,'2026-11-17'], premio:34e6, faixa:[3.5e6,60e6,5e5]},
  {id:'lotofacil', api:'lotofacil', nome:'lotofácil', cor:'#7a1b77', cor2:'#872283', premioCor:'#8c2087', total:25, base:15, max:20, preco:3.5, dias:[0,1,2,3,4,5], ref:[3831,'2026-11-16'], premio:2e6, faixa:[1.7e6,5e6,1e5]},
  {id:'quina', api:'quina', nome:'quina', cor:'#25247b', cor2:'#292a86', premioCor:'#282b8b', total:80, base:5, max:15, preco:3, dias:[0,1,2,3,4,5], ref:[7169,'2026-11-16'], premio:13.5e6, faixa:[6e5,15e6,1e5]},
  {id:'maismilionaria', api:'maismilionaria', nome:'+milionária', cor:'#20286b', cor2:'#252e74', premioCor:'#232e78', total:50, base:6, max:12, preco:6, dias:[3,5], ref:[408,'2026-11-18'], premio:116e6, faixa:[10e6,150e6,1e6]},
  {id:'lotomania', api:'lotomania', nome:'lotomania', cor:'#c45a01', cor2:'#e26500', premioCor:'#e76400', total:100, zero:true, base:50, max:50, preco:3, dias:[1,3,5], ref:[3000,'2026-11-16'], premio:6e5, faixa:[5e5,5e6,1e5]},
  {id:'timemania', api:'timemania', nome:'timemania', cor:'#e0d417', cor2:'#feee00', premioCor:'#007738', texto:'#287000', trevoA:'#047638', trevoB:'#74c399', total:80, base:10, max:10, preco:3.5, dias:[0,2,4], ref:[2469,'2026-11-17'], premio:28e6, faixa:[1e6,30e6,1e5]},
  {id:'duplasena', api:'duplasena', nome:'dupla sena', cor:'#8d2134', cor2:'#9d253b', premioCor:'#a2233b', total:50, base:6, max:15, preco:3, dias:[1,3,5], ref:[3033,'2026-11-16'], premio:13.3e6, faixa:[2e5,15e6,1e5]},
  {id:'diadesorte', api:'diadesorte', nome:'dia de sorte', cor:'#a38818', cor2:'#e1b61c', premioCor:'#755c02', nomeCor:'#725b01', total:31, base:7, max:15, preco:2.5, dias:[0,1,2,3,4,5], ref:[1349,'2026-11-16'], premio:9e5, faixa:[1.5e5,3e6,5e4]},
];
const JOGO = Object.fromEntries(JOGOS.map(j => [j.id, j]));

/* ---------- guardar ---------- */
const guarda = {
  ler(k, pad) { try { const v = localStorage.getItem('lt_' + k); return v == null ? pad : JSON.parse(v); } catch (e) { return pad; } },
  pôr(k, v) { try { localStorage.setItem('lt_' + k, JSON.stringify(v)); } catch (e) {} },
};

/* ---------- datas ---------- */
const DIAS = ['Domingo','Segunda-Feira','Terça-Feira','Quarta-Feira','Quinta-Feira','Sexta-Feira','Sábado'];
const p2 = n => String(n).padStart(2, '0');
function dataDe(iso, h, m) { const [a, me, d] = iso.split('-').map(Number); return new Date(a, me - 1, d, h || 0, m || 0, 0); }
function isoDe(d) { return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()); }
function horaDoSorteio(j, d) { if (j.hora) return j.hora; return d.getDay() === 0 ? [11, 0] : [21, 0]; }
function sorteioEm(j, iso) { const d = dataDe(iso); const [h, m] = horaDoSorteio(j, d); return dataDe(iso, h, m); }
function fechamento(j, sorteio) {
  if (j.virada) return new Date(sorteio.getFullYear() - 1, 11, 31, 22, 0, 0);
  if (j.encerramento) return sorteio;
  return new Date(sorteio.getTime() - 3600e3);
}

/* prêmio "de mentira" mas com cara de verdade, sempre o mesmo para o mesmo concurso */
function premioFalso(j, conc) {
  let s = (conc * 2654435761 + j.id.length * 97) >>> 0;
  s = (s ^ (s >>> 13)) * 1274126177 >>> 0;
  const r = (s % 10000) / 10000;
  const [a, b, passo] = j.faixa;
  const v = a + (b - a) * r * r;          // mais vezes perto do mínimo, como na vida real
  return Math.max(a, Math.round(v / passo) * passo);
}

/* ---------- formato ---------- */
function reais(v) {
  const [i, c] = v.toFixed(2).split('.');
  return 'R$ ' + i.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + ',' + c;
}
function curto(n) { return (Math.round(n * 10) / 10).toString().replace('.', ','); }
function porExtenso(v) {
  if (v >= 1e9) { const n = v / 1e9; return 'R$ ' + curto(n) + (n < 2 ? ' Bilhão' : ' Bilhões'); }
  if (v >= 1e6) { const n = v / 1e6; return 'R$ ' + curto(n) + (n < 2 ? ' Milhão' : ' Milhões'); }
  if (v >= 1e3) return 'R$ ' + curto(v / 1e3) + ' Mil';
  return reais(v);
}
function textoData(d) { return DIAS[d.getDay()] + ', ' + p2(d.getDate()) + '/' + p2(d.getMonth() + 1) + '/' + d.getFullYear() + ' às'; }
function textoHora(d) { return p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':00'; }
function textoFalta(fim, agora) {
  let ms = Math.max(0, fim - agora);
  const d = Math.floor(ms / 864e5); ms -= d * 864e5;
  const h = Math.floor(ms / 36e5); ms -= h * 36e5;
  const m = Math.floor(ms / 6e4);
  if (d > 0) return d + (d === 1 ? ' dia' : ' dias') + ' e ' + h + (h === 1 ? ' hora' : ' horas');
  if (h > 0) return h + (h === 1 ? ' hora' : ' horas') + ' e ' + m + ' minutos';
  return m + ' minutos';
}
function combinacoes(n, k) { if (k > n) return 0; let r = 1; for (let i = 1; i <= k; i++) r = r * (n - k + i) / i; return Math.round(r); }

/* ---------- informação de cada jogo (concurso, data, prêmio) ---------- */
function infoVirada(agora) {
  // sorteio em 1º de janeiro às 11h; depois disso passa para o ano seguinte
  let ano = agora.getFullYear();
  if (agora > new Date(ano, 0, 1, 11, 0, 0)) ano += 1;
  const sorteio = new Date(ano, 0, 1, 11, 0, 0);
  const salvo = guarda.ler('net_virada', null);
  let conc = 3100 + (ano - 2027) * 160, premio = 1e9;
  if (salvo && salvo.ano === ano) { if (salvo.conc) conc = salvo.conc; if (salvo.premio) premio = salvo.premio; }
  return {conc, premio, sorteio, fecha: fechamento(JOGO.virada, sorteio)};
}

function info(j, agora) {
  agora = agora || new Date();
  if (j.virada) return infoVirada(agora);
  // ponto de partida: o que veio da internet (se houver) ou o do vídeo
  const net = guarda.ler('net_' + j.id, null);
  let conc = j.ref[0], iso = j.ref[1], premio = j.premio, daNet = false;
  if (net && net.conc && net.iso && (net.iso > iso || (net.iso === iso && net.conc >= conc))) {
    conc = net.conc; iso = net.iso; premio = net.premio || premio; daNet = true;
  }
  let sorteio = sorteioEm(j, iso);
  // se o próximo sorteio já passou (sem internet), anda no calendário do jogo
  let andou = 0;
  if (fechamento(j, sorteio) <= agora) {
    const d = dataDe(iso);
    while (fechamento(j, sorteio) <= agora && andou < 2000) {
      d.setDate(d.getDate() + 1);
      if (j.dias.includes(d.getDay())) { andou++; sorteio = sorteioEm(j, isoDe(d)); }
    }
    conc += andou;
    premio = premioFalso(j, conc);
  }
  return {conc, premio, sorteio, fecha: fechamento(j, sorteio), daNet: daNet && !andou};
}

function viradaVisivel(agora) {
  const modo = guarda.ler('virada', 'auto');
  if (modo === 'sim') return true;
  if (modo === 'nao') return false;
  agora = agora || new Date();
  const m = agora.getMonth();
  if (m >= 10) return true;                                   // novembro e dezembro
  return m === 0 && agora.getDate() === 1 && agora.getHours() < 11;   // até o sorteio
}

/* ---------- busca na internet ---------- */
function buscarTexto(url) {
  const nativo = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lt;
  if (nativo) return nativo.postMessage({cmd: 'buscar', url});
  const c = new AbortController(); setTimeout(() => c.abort(), 8000);
  return fetch(url, {signal: c.signal, cache: 'no-store'}).then(r => { if (!r.ok) throw new Error(r.status); return r.text(); });
}
function isoDeBR(s) { const m = /(\d{2})\/(\d{2})\/(\d{4})/.exec(s || ''); return m ? m[3] + '-' + m[2] + '-' + m[1] : null; }
function num(v) { const n = typeof v === 'number' ? v : parseFloat(String(v || '').replace(/[^\d.,]/g, '').replace(/\.(?=\d{3})/g, '').replace(',', '.')); return isFinite(n) ? n : 0; }

const FONTES = [
  api => 'https://servicebus2.caixa.gov.br/portaldeloterias/api/' + api,
  api => 'https://loteriascaixa-api.herokuapp.com/api/' + api + '/latest',
];

async function buscarJogo(j) {
  for (const f of FONTES) {
    try {
      const o = JSON.parse(await buscarTexto(f(j.api)));
      const conc = num(o.numeroConcursoProximo || o.proximoConcurso) || (num(o.numero || o.concurso) + 1);
      const iso = isoDeBR(o.dataProximoConcurso);
      const premio = num(o.valorEstimadoProximoConcurso);
      if (!conc || !iso) continue;
      const r = {conc, iso, premio, quando: Date.now()};
      if (j.id === 'megasena') {
        // Mega da Virada: concurso que termina em 0 ou 5 e, se vier, o valor do especial
        const est = Object.keys(o).filter(k => /especial/i.test(k) && /estimad/i.test(k)).map(k => num(o[k])).find(v => v > 1e8);
        const agora = new Date();
        let ano = agora.getFullYear(); if (agora > new Date(ano, 0, 1, 11)) ano += 1;
        const v = {ano};
        if (est) v.premio = est;
        guarda.pôr('net_virada', v);
      }
      return r;
    } catch (e) { /* tenta a próxima fonte */ }
  }
  return null;
}

async function atualizarTudo() {
  const lista = JOGOS.filter(j => !j.virada);
  let ok = 0;
  await Promise.all(lista.map(async j => {
    const r = await buscarJogo(j);
    if (r) { guarda.pôr('net_' + j.id, r); ok++; }
  }));
  guarda.pôr('net_quando', {quando: Date.now(), ok, total: lista.length});
  return ok;
}
