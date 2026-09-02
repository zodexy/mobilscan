import json, os
with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'depth_path' in ''.join(cell['source']):
        source = ''.join(cell['source'])
        new_source = []
        for line in source.split('\n'):
            if 'depth_path' in line or 'depth_file_path' in line:
                continue
            new_source.append(line)
        cell['source'] = [l + ('\n' if i < len(new_source)-1 else '') for i, l in enumerate(new_source)]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)

try:
    with open('actual_data_dir.txt', 'r') as f:
        data_dir = f.read().strip()
    transforms_path = os.path.join(data_dir, 'transforms.json')
    if os.path.exists(transforms_path):
        with open(transforms_path, 'r') as f:
            t = json.load(f)
        for frame in t['frames']:
            if 'depth_file_path' in frame:
                del frame['depth_file_path']
        with open(transforms_path, 'w') as f:
            json.dump(t, f, indent=4)
        print('Fixed transforms.json!')
except Exception as e:
    print('Could not fix transforms.json:', e)
