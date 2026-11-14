# Monta www/index.html juntando app.html + app.js + famosos.txt
import os
aqui = os.path.dirname(os.path.abspath(__file__))
ler = lambda n: open(os.path.join(aqui, n), encoding='utf-8').read()
html = ler('app.html')
html = html.replace('/*FAMOSOS*/', '\n' + ler('famosos.txt').strip() + '\n')
html = html.replace('<script src="app.js"></script>', '<script>\n' + ler('app.js') + '\n</script>')
saida = os.path.join(aqui, '..', 'www', 'index.html')
open(saida, 'w', encoding='utf-8').write(html)
print('ok', len(html) // 1024, 'KB')
