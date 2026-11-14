# Monta www/index.html juntando app.html + famosos.txt
import os
aqui = os.path.dirname(os.path.abspath(__file__))
html = open(os.path.join(aqui, 'app.html'), encoding='utf-8').read()
fam = open(os.path.join(aqui, 'famosos.txt'), encoding='utf-8').read().strip()
saida = os.path.join(aqui, '..', 'www', 'index.html')
os.makedirs(os.path.dirname(saida), exist_ok=True)
open(saida, 'w', encoding='utf-8').write(html.replace('/*FAMOSOS*/', '\n' + fam + '\n'))
print('ok', len(fam.splitlines()), 'famosos')
