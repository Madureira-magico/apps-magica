# Monta www/index.html juntando app.html + a fonte Cryptext + a imagem do "a"/"o" final
# + as PEÇAS PRONTAS de comum/telas (tela de início do Mosaico, tela bloqueada do Timeline e a animação do iPhone)
import os, shutil
aqui = os.path.dirname(os.path.abspath(__file__))
telas = os.path.join(aqui, '..', '..', '..', 'comum', 'telas')
ler = lambda n, d=aqui: open(os.path.join(d, n), encoding='utf-8').read()
html = ler('app.html')
for peca in ('tela-inicio.css', 'tela-bloqueio.css', 'tela-inicio.js', 'tela-bloqueio.js'):
    html = html.replace('/*PECA:' + peca + '*/', ler(peca, telas))
html = html.replace('/*CRYPTEXT*/', ler('cryptext.css'))
html = html.replace('/*FINAL_A*/', ler('final_a.txt').strip())
assert '/*PECA:' not in html
saida = os.path.join(aqui, '..', 'www', 'index.html')
open(saida, 'w', encoding='utf-8').write(html)
# a parte do iPhone das telas vai junto com o app
shutil.copy(os.path.join(telas, 'TelasNativas.swift'), os.path.join(aqui, '..', 'extras', 'TelasNativas.swift'))
print('ok', len(html) // 1024, 'KB')
