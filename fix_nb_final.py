import json

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv python install' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        
        # Revert cu121 to cu118
        source = source.replace('cu121', 'cu118')
        
        # Remove tiny-cuda-nn line entirely!
        lines = source.split('\n')
        new_lines = [l for l in lines if 'tiny-cuda-nn' not in l]
        
        cell['source'] = [l + ('\n' if i < len(new_lines)-1 else '') for i, l in enumerate(new_lines)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

print('Done!')
