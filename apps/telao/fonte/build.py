# Monta www/index.html juntando app.html + a tela bloqueada pronta (comum/telas) + o leitor da letra do Post-It
import os, shutil
aqui = os.path.dirname(os.path.abspath(__file__))
raiz = os.path.join(aqui, '..', '..', '..')
telas = os.path.join(raiz, 'comum', 'telas')
ler = lambda n, d=aqui: open(os.path.join(d, n), encoding='utf-8').read()
html = ler('app.html')
for peca in ('tela-bloqueio.css', 'tela-bloqueio.js'):
    html = html.replace('/*PECA:' + peca + '*/', ler(peca, telas))
html = html.replace('/*POSTIT*/', ler('postit-leitor.js'))
assert '/*PECA:' not in html and '/*POSTIT*/' not in html
www = os.path.join(aqui, '..', 'www')
os.makedirs(os.path.join(www, 'ini'), exist_ok=True)
open(os.path.join(www, 'index.html'), 'w', encoding='utf-8').write(html)
shutil.copy(os.path.join(telas, 'ini', 'papel.jpg'), os.path.join(www, 'ini', 'papel.jpg'))
shutil.copy(os.path.join(raiz, 'apps', 'relogio', 'www', 'ably.min.js'), os.path.join(www, 'ably.min.js'))
shutil.copy(os.path.join(telas, 'TelasNativas.swift'), os.path.join(aqui, '..', 'extras', 'TelasNativas.swift'))
print('ok', len(html) // 1024, 'KB')
