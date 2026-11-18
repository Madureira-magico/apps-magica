# Monta www/index.html juntando app.html + a fonte Cryptext + a imagem do "a"/"o" final
import os
aqui = os.path.dirname(os.path.abspath(__file__))
ler = lambda n: open(os.path.join(aqui, n), encoding='utf-8').read()
html = ler('app.html')
html = html.replace('/*CRYPTEXT*/', ler('cryptext.css'))
html = html.replace('/*FINAL_A*/', ler('final_a.txt').strip())
saida = os.path.join(aqui, '..', 'www', 'index.html')
open(saida, 'w', encoding='utf-8').write(html)
print('ok', len(html) // 1024, 'KB')
