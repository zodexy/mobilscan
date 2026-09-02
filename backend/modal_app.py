import os
import uuid
import json
import zipfile
import shutil
import subprocess
import struct
import modal
from fastapi import FastAPI, UploadFile, File, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

# 1. Image Definition
# We install Torch and Nerfstudio on top of an Ubuntu CUDA image
image = (
    modal.Image.debian_slim(python_version="3.10")
    .apt_install("git", "wget", "ffmpeg", "libsm6", "libxext6", "build-essential", "clang")
    .pip_install(
        "torch==2.1.2", "torchvision==0.16.2", 
        index_url="https://download.pytorch.org/whl/cu121"
    )
    .pip_install("ninja", "numpy<2")
    .pip_install("nerfstudio")
    .pip_install("fastapi", "uvicorn", "python-multipart", "pydantic")
)

# 2. Volume for Storage
# This persistent volume stores zips, training data, and final .splat files
volume = modal.Volume.from_name("mobilscan-storage", create_if_missing=True)
VOLUME_DIR = "/data"

app = modal.App("mobilscan-backend")
web_api = FastAPI()

class JobStatusResponse(BaseModel):
    job_id: str
    status: str

# Helper to manage status file on the persistent volume
def update_status(job_id: str, status: str):
    status_file = os.path.join(VOLUME_DIR, "jobs_status.json")
    data = {}
    if os.path.exists(status_file):
        with open(status_file, "r") as f:
            data = json.load(f)
    data[job_id] = status
    with open(status_file, "w") as f:
        json.dump(data, f)
    volume.commit()

def get_status(job_id: str):
    status_file = os.path.join(VOLUME_DIR, "jobs_status.json")
    if os.path.exists(status_file):
        with open(status_file, "r") as f:
            data = json.load(f)
            return data.get(job_id, "unknown")
    return "unknown"

def convert_arkit_to_nerfstudio(data_dir: str):
    """
    Converts ARKit's transforms.json to the format expected by Nerfstudio's splatfacto.
    Skips COLMAP entirely since LiDAR provides perfect poses.
    """
    input_json_path = os.path.join(data_dir, "transforms.json")
    
    if not os.path.exists(input_json_path):
        # Mappa mélyén van?
        subdirs = [os.path.join(data_dir, d) for d in os.listdir(data_dir) if os.path.isdir(os.path.join(data_dir, d))]
        if subdirs and os.path.exists(os.path.join(subdirs[0], "transforms.json")):
            data_dir = subdirs[0]
            input_json_path = os.path.join(data_dir, "transforms.json")
        else:
            raise Exception(f"Nem találom a transforms.json fájlt itt: {input_json_path}")
            
    arkit_json_path = os.path.join(data_dir, "transforms_arkit.json")
    if not os.path.exists(arkit_json_path):
        shutil.copy(input_json_path, arkit_json_path)
        
    with open(input_json_path, 'r') as f:
        data = json.load(f)
        
    frames = data.get("frames", [])
    if not frames:
        raise Exception("Nincsenek képkockák a transforms.json-ben!")
        
    def get_jpeg_size(filepath):
        with open(filepath, 'rb') as f:
            f.read(2)
            b = f.read(1)
            try:
                while (b and ord(b) != 0xDA):
                    while (ord(b) != 0xFF): b = f.read(1)
                    while (ord(b) == 0xFF): b = f.read(1)
                    if (ord(b) >= 0xC0 and ord(b) <= 0xC3):
                        f.read(3)
                        h, w = struct.unpack(">HH", f.read(4))
                        return w, h
                    else:
                        f.read(int(struct.unpack(">H", f.read(2))[0])-2)
                    b = f.read(1)
            except Exception:
                pass
        return 1920, 1440

    first_image_path = os.path.join(data_dir, frames[0]["file_path"])
    w, h = get_jpeg_size(first_image_path)
        
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
        # Convert ARKit pose to Nerfstudio convention
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
        
    return data_dir

# 3. Serverless GPU Function for Processing
@app.function(
    image=image, 
    volumes={VOLUME_DIR: volume}, 
    gpu="A10G", # A10G is powerful enough and cheaper than A100.
    timeout=1800 # 30 mins max
)
def run_gaussian_splatting(job_id: str, zip_path: str):
    print(f"[{job_id}] Process started on GPU...")
    job_dir = os.path.join(VOLUME_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)
    
    try:
        update_status(job_id, "extracting")
        
        # 1. Unzip
        print(f"[{job_id}] Extracting...")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(job_dir)
            
        # 2. Fix Transforms (LiDAR ARKit to Nerfstudio)
        print(f"[{job_id}] Converting transforms...")
        actual_data_dir = convert_arkit_to_nerfstudio(job_dir)
        volume.commit()
        
        # 3. Train Splatfacto
        update_status(job_id, "training")
        print(f"[{job_id}] Training Gaussian Splats...")
        # Optimalizált paraméterek a legolcsóbb (leggyorsabb), de kiváló minőségű futáshoz
        train_cmd = [
            "ns-train", "splatfacto", 
            "--vis", "tensorboard",
            "--pipeline.datamanager.max-thread-workers", "4",
            "--pipeline.model.camera-optimizer.mode", "off", # ARKit LiDAR pozíciók fixek, nincs szükség drága optimalizálásra
            "--pipeline.model.cull-alpha-thresh", "0.01", # Kicsit magasabb küszöb, hogy gyorsabban kitörölje a felesleges pontokat (floaters)
            "--pipeline.model.sh-degree", "2", # SH degree 2 (3 helyett) jelentősen gyorsítja a tanulást és csökkenti a fájlméretet, minimális minőségvesztéssel
            "--timestamp", job_id,
            "--max-num-iterations", "7000", # 30000 helyett 7000 tökéletes az ingatlanokhoz, kb. ötödére csökkenti a költséget
            "nerfstudio-data", "--data", actual_data_dir, 
            "--downscale-factor", "4" # Képek felbontásának negyedelése (ahogy a notebookodban is volt) drasztikusan gyorsít
        ]
        
        subprocess.run(train_cmd, check=True)
        
        # 4. Export to .splat
        print(f"[{job_id}] Exporting model...")
        update_status(job_id, "exporting")
        
        # Nerfstudio saves outputs in outputs/<dataset_name>/splatfacto/<timestamp>/config.yml
        # We need to find this config.yml
        config_path = None
        for root, dirs, files in os.walk(os.path.join(os.getcwd(), "outputs")):
            if "config.yml" in files and job_id in root:
                config_path = os.path.join(root, "config.yml")
                break
                
        if not config_path:
            raise Exception("Cannot find training config.yml to export model!")
            
        export_dir = os.path.join(VOLUME_DIR, f"{job_id}_export")
        os.makedirs(export_dir, exist_ok=True)
        
        export_cmd = [
            "ns-export", "gaussian-splat", 
            "--load-config", config_path, 
            "--output-dir", export_dir
        ]
        subprocess.run(export_cmd, check=True)
        
        # The exported file is splat.ply
        ply_file = os.path.join(export_dir, "splat.ply")
        if not os.path.exists(ply_file):
            raise Exception("Export failed: splat.ply not found.")
            
        update_status(job_id, "completed")
        print(f"[{job_id}] Finished successfully!")
        
    except Exception as e:
        print(f"[{job_id}] ERROR: {e}")
        update_status(job_id, "failed")
    finally:
        volume.commit()

# 4. Web Endpoints
@web_api.post("/upload", response_model=JobStatusResponse)
async def upload_scan(background_tasks: BackgroundTasks, file: UploadFile = File(...)):
    job_id = str(uuid.uuid4())
    update_status(job_id, "uploading")
    
    zip_path = os.path.join(VOLUME_DIR, f"{job_id}.zip")
    with open(zip_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    volume.commit()
    
    # Kézi háttérfolyamat indítás helyett a Modal .spawn() metódusát hívjuk
    # Ez azonnal visszatér, és a háttérben elindítja a GPU workert
    run_gaussian_splatting.spawn(job_id, zip_path)
    
    return JobStatusResponse(job_id=job_id, status="processing")

@web_api.get("/status/{job_id}", response_model=JobStatusResponse)
async def get_status_endpoint(job_id: str):
    volume.reload() # Ensure we have the latest status from the volume
    status = get_status(job_id)
    return JobStatusResponse(job_id=job_id, status=status)

@web_api.get("/download/{job_id}")
async def download_splat(job_id: str):
    volume.reload()
    status = get_status(job_id)
    if status != "completed":
        raise HTTPException(status_code=400, detail="Job is not completed yet")
        
    ply_file = os.path.join(VOLUME_DIR, f"{job_id}_export", "splat.ply")
    if not os.path.exists(ply_file):
        raise HTTPException(status_code=404, detail="Splat file not found on volume")
        
    return FileResponse(ply_file, filename=f"scan_{job_id}.ply")

@web_api.get("/view/{job_id}")
async def view_splat(job_id: str):
    # HTML string that uses Luma WebGL to render the splat directly from the /download endpoint
    html_content = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Mobilscan 3D Viewer</title>
        <style>
            body {{ margin: 0; overflow: hidden; background-color: #111; font-family: sans-serif; }}
            #canvas-container {{ width: 100vw; height: 100vh; }}
            #ui {{ position: absolute; top: 20px; left: 20px; color: white; background: rgba(0,0,0,0.6); padding: 15px; border-radius: 10px; backdrop-filter: blur(10px); }}
            h1 {{ margin: 0 0 10px 0; font-size: 20px; color: #34d399; }}
            p {{ margin: 5px 0; font-size: 14px; color: #ccc; }}
            .controls {{ color: #60a5fa; font-weight: bold; }}
        </style>
    </head>
    <body>
        <div id="ui">
            <h1>Mobilscan 3D Bejárás</h1>
            <p>Mozgás: <span class="controls">W A S D</span></p>
            <p>Nézelődés: <span class="controls">Egér kattintás + Húzás</span></p>
            <p>Fel / Le: <span class="controls">Q / E</span></p>
        </div>
        <div id="canvas-container"></div>
        <script type="importmap">
        {{
            "imports": {{
                "three": "https://unpkg.com/three@0.157.0/build/three.module.js",
                "three/addons/": "https://unpkg.com/three@0.157.0/examples/jsm/",
                "@lumaai/luma-web": "https://unpkg.com/@lumaai/luma-web@0.2.0/dist/library/luma-web.module.js"
            }}
        }}
        </script>
        <script type="module">
            import * as THREE from 'three';
            import {{ PointerLockControls }} from 'three/addons/controls/PointerLockControls.js';
            import {{ LumaSplatsThree }} from '@lumaai/luma-web';

            const scene = new THREE.Scene();
            const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
            camera.position.set(0, 1.6, 2);

            const renderer = new THREE.WebGLRenderer({{ antialias: true }});
            renderer.setSize(window.innerWidth, window.innerHeight);
            document.getElementById('canvas-container').appendChild(renderer.domElement);

            const splatUrl = window.location.origin + '/download/{job_id}';
            let splat = new LumaSplatsThree({{
                source: splatUrl,
                loadingAnimationEnabled: true,
            }});
            scene.add(splat);

            const controls = new PointerLockControls(camera, renderer.domElement);
            document.addEventListener('click', () => controls.lock());

            const move = {{ forward: false, backward: false, left: false, right: false, up: false, down: false }};
            const speed = 0.05;

            document.addEventListener('keydown', (e) => {{
                switch(e.code) {{
                    case 'KeyW': move.forward = true; break;
                    case 'KeyS': move.backward = true; break;
                    case 'KeyA': move.left = true; break;
                    case 'KeyD': move.right = true; break;
                    case 'KeyQ': move.up = true; break;
                    case 'KeyE': move.down = true; break;
                }}
            }});
            document.addEventListener('keyup', (e) => {{
                switch(e.code) {{
                    case 'KeyW': move.forward = false; break;
                    case 'KeyS': move.backward = false; break;
                    case 'KeyA': move.left = false; break;
                    case 'KeyD': move.right = false; break;
                    case 'KeyQ': move.up = false; break;
                    case 'KeyE': move.down = false; break;
                }}
            }});

            function animate() {{
                requestAnimationFrame(animate);
                if (controls.isLocked) {{
                    if (move.forward) controls.moveForward(speed);
                    if (move.backward) controls.moveForward(-speed);
                    if (move.left) controls.moveRight(-speed);
                    if (move.right) controls.moveRight(speed);
                    if (move.up) camera.position.y += speed;
                    if (move.down) camera.position.y -= speed;
                }}
                renderer.render(scene, camera);
            }}
            animate();

            window.addEventListener('resize', () => {{
                camera.aspect = window.innerWidth / window.innerHeight;
                camera.updateProjectionMatrix();
                renderer.setSize(window.innerWidth, window.innerHeight);
            }});
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content, status_code=200)

# Wrap FastAPI with Modal ASGI app
@app.function(image=image, volumes={VOLUME_DIR: volume})
@modal.asgi_app()
def fastapi_app():
    return web_api
