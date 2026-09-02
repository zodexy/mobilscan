import json
import os

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv python install' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        
        # Ensure we use uv pip install with --no-build-isolation for tiny-cuda-nn
        source = source.replace(
            '!/content/.venv/bin/pip install git+https://github.com/NVlabs/tiny-cuda-nn/#subdirectory=bindings/torch',
            '!/usr/local/bin/uv pip install --python /content/.venv --no-build-isolation git+https://github.com/NVlabs/tiny-cuda-nn/#subdirectory=bindings/torch'
        )
        
        lines = source.split('\n')
        cell['source'] = [l + ('\n' if i < len(lines)-1 else '') for i, l in enumerate(lines)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

print('Done!')
