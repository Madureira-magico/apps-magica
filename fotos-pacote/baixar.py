#!/usr/bin/env python3
"""Baixa o pacote de fotos do Mosaic, separado por grupo de cor.

Fontes (sem chave): Openverse (fotos do Flickr com licença aberta) e,
se faltar, Wikimedia Commons. Cada foto é reduzida (lado maior 640 px),
filtrada (sem foto lisa, branca ou preta demais) e sem repetidas.

Uso: python3 baixar.py temas.txt SAIDA
"""
import io, json, os, re, sys, time, zipfile, random, threading
TRAVA_ROSTO = threading.Lock()
import urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageOps, ImageStat
try:
    import cv2, numpy as np
    ROSTOS = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    if ROSTOS.empty():
        raise RuntimeError("sem detector de rosto")
except Exception:
    ROSTOS = None

UA = "MosaicFotosPacote/1.0 (https://github.com/Madureira-magico/apps-magica)"
LADO = 640
QUALIDADE = 72


def get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def ler_temas(caminho):
    grupos, atual = [], None
    for linha in open(caminho, encoding="utf-8"):
        linha = linha.strip()
        if not linha or (linha.startswith("#") and not linha.startswith("##")):
            continue
        if linha.startswith("##"):
            atual = {"grupo": linha[2:].strip(), "temas": []}
            grupos.append(atual)
            continue
        busca, _, qtd = linha.partition("|")
        atual["temas"].append((busca.strip(), int(qtd.strip() or 15)))
    return grupos


# ---------- fontes ----------
def openverse(busca, pagina):
    q = urllib.parse.urlencode({"q": busca, "page_size": 20, "page": pagina,
                                "category": "photograph", "mature": "false",
                                "source": "flickr"})
    dados = json.loads(get("https://api.openverse.org/v1/images/?" + q))
    for r in dados.get("results", []):
        if (r.get("width") or 0) and r["width"] < 500:
            continue
        yield {"url": r["url"], "autor": r.get("creator") or "",
               "licenca": (r.get("license") or "") + " " + (r.get("license_version") or ""),
               "origem": r.get("foreign_landing_url") or "", "fonte": "openverse"}


def wikimedia(busca, pagina):
    q = urllib.parse.urlencode({
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": "filetype:bitmap " + busca, "gsrnamespace": 6,
        "gsrlimit": 30, "gsroffset": (pagina - 1) * 30,
        "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": LADO})
    dados = json.loads(get("https://commons.wikimedia.org/w/api.php?" + q))
    for p in (dados.get("query", {}).get("pages", {}) or {}).values():
        ii = (p.get("imageinfo") or [{}])[0]
        if not ii.get("thumburl"):
            continue
        meta = ii.get("extmetadata", {})
        autor = re.sub("<[^>]+>", "", meta.get("Artist", {}).get("value", ""))
        yield {"url": ii["thumburl"], "autor": autor.strip(),
               "licenca": meta.get("LicenseShortName", {}).get("value", ""),
               "origem": ii.get("descriptionurl", ""), "fonte": "wikimedia"}


# ---------- análise da foto ----------
def dhash(img):
    p = list(img.convert("L").resize((9, 8)).getdata())
    bits = 0
    for y in range(8):
        for x in range(8):
            bits = (bits << 1) | (p[y * 9 + x] > p[y * 9 + x + 1])
    return bits


def preparar(dados):
    """Devolve (jpeg_bytes, info) ou None se a foto não serve."""
    img = Image.open(io.BytesIO(dados))
    img = ImageOps.exif_transpose(img).convert("RGB")
    w, h = img.size
    if min(w, h) < 300 or max(w, h) / min(w, h) > 2.2:
        return None
    pequena = img.resize((32, 32))
    st = ImageStat.Stat(pequena.convert("L"))
    media, desvio = st.mean[0], st.stddev[0]
    if desvio < 14 or media > 238 or media < 14:   # lisa, branca ou preta demais
        return None
    # objeto em fundo branco/liso (foto de catálogo ou museu): bordas quase todas iguais
    borda = [pequena.getpixel((x, y)) for x in range(32) for y in (0, 31)] + \
            [pequena.getpixel((x, y)) for y in range(32) for x in (0, 31)]
    clara = sum(1 for p in borda if min(p) > 225)
    if clara > len(borda) * 0.7:
        return None
    img.thumbnail((LADO, LADO), Image.LANCZOS)
    # rosto de desconhecido aparecendo grande: não serve para a galeria
    if ROSTOS is not None:
        cinza = np.array(img.convert("L"))
        with TRAVA_ROSTO:   # o detector não aguenta duas fotos ao mesmo tempo
            achados = list(ROSTOS.detectMultiScale(cinza, 1.1, 10, minSize=(40, 40)))
        for (x, y, fw, fh) in achados:
            if fw > img.size[0] * 0.08:
                return None
    cor = [round(c) for c in ImageStat.Stat(pequena).mean]
    quad = []
    for (x, y) in ((0, 0), (16, 0), (0, 16), (16, 16)):
        quad.append([round(c) for c in ImageStat.Stat(pequena.crop((x, y, x + 16, y + 16))).mean])
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=QUALIDADE, optimize=True, progressive=True)
    return buf.getvalue(), {"cor": cor, "quadrantes": quad, "brilho": round(media),
                            "largura": img.size[0], "altura": img.size[1],
                            "hash": dhash(img)}


def parecida(h, vistos):
    return any(bin(h ^ v).count("1") <= 6 for v in vistos)


def slug(t):
    return re.sub("[^a-z0-9]+", "-", t.lower()).strip("-")


def baixar_tema(busca, qtd, vistos, urls_vistas, log):
    pegas = []
    for fonte in (openverse, wikimedia):
        for pagina in range(1, 9):
            if len(pegas) >= qtd:
                break
            try:
                cand = [c for c in fonte(busca, pagina) if c["url"] not in urls_vistas]
            except Exception as e:
                log.append(f"  ! {fonte.__name__} '{busca}' pág {pagina}: {e}")
                time.sleep(3)
                break
            time.sleep(1.2)
            if not cand:
                break

            def baixa(c):
                try:
                    return c, preparar(get(c["url"]))
                except Exception:
                    return c, None
            with ThreadPoolExecutor(8) as ex:
                for c, res in ex.map(baixa, cand):
                    urls_vistas.add(c["url"])
                    if not res or len(pegas) >= qtd:
                        continue
                    jpg, info = res
                    if parecida(info["hash"], vistos):
                        continue
                    vistos.append(info["hash"])
                    pegas.append((jpg, {**c, **info}))
        if len(pegas) >= qtd:
            break
    return pegas


def folha(imagens, destino):
    """Folha de amostra: todas as fotos do grupo em miniatura."""
    n = len(imagens)
    if not n:
        return
    col = 10
    lin = (n + col - 1) // col
    t = 90
    f = Image.new("RGB", (col * t, lin * t), "white")
    for i, jpg in enumerate(imagens):
        im = ImageOps.fit(Image.open(io.BytesIO(jpg)), (t - 2, t - 2))
        f.paste(im, ((i % col) * t + 1, (i // col) * t + 1))
    f.save(destino, "JPEG", quality=80)


def main():
    temas, saida = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(saida, "amostras"), exist_ok=True)
    grupos = ler_temas(temas)
    lista, log, vistos, urls = [], [], [], set()
    zpath = os.path.join(saida, "pacote-fotos-mosaico.zip")
    z = zipfile.ZipFile(zpath, "w", zipfile.ZIP_STORED)
    for g in grupos:
        jpgs_grupo = []
        for busca, qtd in g["temas"]:
            pegas = baixar_tema(busca, qtd, vistos, urls, log)
            log.append(f"{g['grupo']:24} {busca:24} {len(pegas):3}/{qtd}")
            print(log[-1], flush=True)
            for i, (jpg, info) in enumerate(pegas, 1):
                nome = f"fotos/{g['grupo']}/{slug(busca)}-{i:02d}.jpg"
                z.writestr(nome, jpg)
                jpgs_grupo.append(jpg)
                info.pop("hash", None)
                lista.append({"arquivo": nome, "grupo": g["grupo"], "tema": busca,
                              **{k: info[k] for k in ("cor", "quadrantes", "brilho", "largura", "altura")},
                              "autor": info["autor"], "licenca": info["licenca"].strip(),
                              "origem": info["origem"], "fonte": info["fonte"]})
        folha(jpgs_grupo, os.path.join(saida, "amostras", g["grupo"] + ".jpg"))
    z.writestr("lista.json", json.dumps({"versao": 1, "fotos": lista}, ensure_ascii=False, indent=0))
    z.close()
    with open(os.path.join(saida, "lista.json"), "w", encoding="utf-8") as f:
        json.dump({"versao": 1, "fotos": lista}, f, ensure_ascii=False, indent=0)
    mb = os.path.getsize(zpath) / 1e6
    resumo = [f"Total: {len(lista)} fotos, pacote {mb:.1f} MB", ""]
    for g in grupos:
        resumo.append(f"{g['grupo']}: {sum(1 for x in lista if x['grupo'] == g['grupo'])}")
    resumo += ["", "Detalhe:"] + log
    open(os.path.join(saida, "resumo.txt"), "w", encoding="utf-8").write("\n".join(resumo) + "\n")
    print("\n".join(resumo[:12]))


if __name__ == "__main__":
    main()
