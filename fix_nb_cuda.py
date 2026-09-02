import json

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv python install' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        
        # Replace cu118 with cu121
        source = source.replace('cu118', 'cu121')
        
        lines = source.split('\n')
        cell['source'] = [l + ('\n' if i < len(lines)-1 else '') for i, l in enumerate(lines)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

print('Done!')
