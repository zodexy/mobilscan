import json
import os

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv python install' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        if 'setuptools wheel' not in source:
            # Insert setuptools installation right after venv creation
            lines = source.split('\n')
            new_lines = []
            for line in lines:
                new_lines.append(line)
                if 'uv venv' in line:
                    new_lines.append('!/usr/local/bin/uv pip install --python /content/.venv setuptools wheel')
            
            # Reconstruct cell source
            cell['source'] = [l + ('\n' if i < len(new_lines)-1 else '') for i, l in enumerate(new_lines)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

print('Done!')
