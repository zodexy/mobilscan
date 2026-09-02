import json
with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)
nb['cells'][8]['source'] = ['!DATA_DIR=$(cat /content/actual_data_dir.txt) && /content/.venv/bin/ns-train splatfacto --vis tensorboard --pipeline.model.camera-optimizer.mode off --pipeline.model.cull-alpha-thresh 0.005 --pipeline.model.sh-degree 3 --timestamp "mobilscan_run" nerfstudio-data --data $DATA_DIR --downscale-factor 3']
with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)
print('Fixed notebook code cell 8!')
