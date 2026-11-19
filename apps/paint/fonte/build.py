# Monta www/index.html juntando app.html + as PEÇAS PRONTAS de comum/telas (tela bloqueada do Timeline)
import os, shutil
aqui = os.path.dirname(os.path.abspath(__file__))
telas = os.path.join(aqui, '..', '..', '..', 'comum', 'telas')
ler = lambda n, d=aqui: open(os.path.join(d, n), encoding='utf-8').read()
html = ler('app.html')
for peca in ('tela-bloqueio.css', 'tela-bloqueio.js', 'barra-falsa.js'):
    html = html.replace('/*PECA:' + peca + '*/', ler(peca, telas))
assert '/*PECA:' not in html
saida = os.path.join(aqui, '..', 'www', 'index.html')
open(saida, 'w', encoding='utf-8').write(html)
# a parte do iPhone das telas vai junto com o app
shutil.copy(os.path.join(telas, 'TelasNativas.swift'), os.path.join(aqui, '..', 'extras', 'TelasNativas.swift'))
print('ok', len(html) // 1024, 'KB')
