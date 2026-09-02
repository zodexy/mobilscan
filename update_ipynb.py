import json

with open('Gaussian_Splatting_Backend.ipynb', 'r', encoding='utf-8') as f:
    nb = json.load(f)

# Step 1
for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'uv pip install' in ''.join(cell['source']):
        cell['source'] = [
            "!curl -LsSf https://astral.sh/uv/install.sh | sh\n",
            "!/usr/local/bin/uv python install 3.10\n",
            "!/usr/local/bin/uv venv --python 3.10 /content/.venv\n",
            "!/usr/local/bin/uv pip install --python /content/.venv \"setuptools<70\" wheel\n",
            "!/usr/local/bin/uv pip install --python /content/.venv \"numpy<2\"\n",
            "!/usr/local/bin/uv pip install --python /content/.venv torch==2.1.2 torchvision==0.16.2 --extra-index-url https://download.pytorch.org/whl/cu121\n",
            "!/usr/local/bin/uv pip install --python /content/.venv ninja\n",
            "!/usr/local/bin/uv pip install --python /content/.venv nerfstudio\n"
        ]

# Step 3
for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'convert_arkit_to_nerfstudio' in ''.join(cell['source']):
        source_code = """import json
import os
import shutil
from PIL import Image

def convert_arkit_to_nerfstudio(data_dir):
    input_json_path = os.path.join(data_dir, "transforms.json")
    
    if not os.path.exists(input_json_path):
        subdirs = [os.path.join(data_dir, d) for d in os.listdir(data_dir) if os.path.isdir(os.path.join(data_dir, d))]
        if subdirs and os.path.exists(os.path.join(subdirs[0], "transforms.json")):
            data_dir = subdirs[0]
            input_json_path = os.path.join(data_dir, "transforms.json")
        else:
            print(f"\u274c HIBA: Nem találom a transforms.json fájlt itt: {input_json_path}")
            return data_dir
            
    # Mentsük el az eredeti ARKit json-t, ha még nincs
    arkit_json_path = os.path.join(data_dir, "transforms_arkit.json")
    if os.path.exists(arkit_json_path):
        print("Már át van konvertálva, arkit mentés megvan.")
        input_json_path = arkit_json_path
    else:
        shutil.copy(input_json_path, arkit_json_path)
        
    with open(input_json_path, 'r') as f:
        data = json.load(f)
        
    frames = data.get("frames", [])
    if not frames:
        print("\u274c HIBA: Nincsenek képkockák a transforms.json-ben!")
        return data_dir
        
    first_image_path = os.path.join(data_dir, frames[0]["file_path"])
    if not os.path.exists(first_image_path):
        print(f"\u274c HIBA: Nem találom az első képet: {first_image_path}.")
        return data_dir
        
    with Image.open(first_image_path) as img:
        w, h = img.size
        
    intrinsics = frames[0]["intrinsics_matrix"]
    fl_x = intrinsics[0][0]
    fl_y = intrinsics[1][1]
    cx = intrinsics[2][0]
    cy = intrinsics[2][1]
    
    out_data = {
        "camera_model": "OPENCV",
        "orientation_override": "none",
        "fl_x": fl_x,
        "fl_y": fl_y,
        "cx": cx,
        "cy": cy,
        "w": w,
        "h": h,
        "frames": []
    }
    
    for frame in frames:
        matrix = frame["transform_matrix"]
        
        c2w = [
            [matrix[0][0], -matrix[1][0], -matrix[2][0], matrix[3][0]],
            [matrix[0][1], -matrix[1][1], -matrix[2][1], matrix[3][1]],
            [matrix[0][2], -matrix[1][2], -matrix[2][2], matrix[3][2]],
            [matrix[0][3], -matrix[1][3], -matrix[2][3], matrix[3][3]]
        ]
        
        out_frame = {
            "file_path": frame["file_path"],
            "transform_matrix": c2w,
            "fl_x": fl_x,
            "fl_y": fl_y,
            "cx": cx,
            "cy": cy
        }
        
        out_data["frames"].append(out_frame)
        
    output_json_path = os.path.join(data_dir, "transforms.json")
    with open(output_json_path, 'w') as f:
        json.dump(out_data, f, indent=4)
        
    print(f"\u2705 Sikeresen konvertáltam {len(frames)} képkockát NerfStudio formátumra!")
    return data_dir

actual_data_dir = convert_arkit_to_nerfstudio("/content/ScanData")
with open("/content/actual_data_dir.txt", "w") as f:
    f.write(actual_data_dir)"""
        cell['source'] = [line + '\n' for line in source_code.split('\n')]
        cell['source'][-1] = cell['source'][-1].replace('\n', '')

# Step 4
for cell in nb['cells']:
    if cell['cell_type'] == 'code' and 'ns-train' in ''.join(cell['source']):
        cell['source'] = [
            "!DATA_DIR=$(cat /content/actual_data_dir.txt) && /content/.venv/bin/ns-train splatfacto --vis tensorboard --pipeline.datamanager.max-thread-workers 1 --pipeline.model.camera-optimizer.mode off --pipeline.model.cull-alpha-thresh 0.005 --pipeline.model.sh-degree 3 --timestamp \"mobilscan_run\" nerfstudio-data --data $DATA_DIR --downscale-factor 4\n"
        ]

with open('Gaussian_Splatting_Backend.ipynb', 'w', encoding='utf-8') as f:
    json.dump(nb, f, indent=2)
print("Updated successfully")
