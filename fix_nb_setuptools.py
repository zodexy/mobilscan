import json

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv python install' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        
        # Replace setuptools wheel with setuptools<70 wheel
        source = source.replace(
            '!/usr/local/bin/uv pip install --python /content/.venv setuptools wheel',
            '!/usr/local/bin/uv pip install --python /content/.venv "setuptools<70" wheel'
        )
        
        lines = source.split('\n')
        cell['source'] = [l + ('\n' if i < len(lines)-1 else '') for i, l in enumerate(lines)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

print('Done!')
