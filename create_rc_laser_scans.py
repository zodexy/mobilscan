import json, struct, os
import math
from PIL import Image

def generate_ptx():
    data_dir = "Scan_20260912_211922"
    transforms_path = os.path.join(data_dir, "transforms.json")
    out_dir = os.path.join(data_dir, "laser_scans")
    os.makedirs(out_dir, exist_ok=True)
    
    with open(transforms_path, "r") as f:
        data = json.load(f)
    
    print(f"Generating PTX scans in {out_dir} ...")
    
    frames = data["frames"]
    for i, frame in enumerate(frames):
        if i % 10 == 0:
            print(f"Processing frame {i}/{len(frames)}")
            
        file_path = frame["file_path"]
        base_name = os.path.basename(file_path).replace(".jpg", "")
        depth_path = os.path.join(data_dir, "depth", base_name + ".bin")
        img_path = os.path.join(data_dir, "images", base_name + ".jpg")
        
        if not os.path.exists(depth_path) or not os.path.exists(img_path):
            continue
            
        try:
            img = Image.open(img_path)
            img = img.resize((256, 192), Image.Resampling.BILINEAR)
            img = img.convert("RGB")
            # Convert to list of pixels (flattened)
            img_data = list(img.getdata())
        except Exception:
            img_data = None
        
        tm = frame["transform_matrix"]
        
        # c2w matrix
        c2w = [
            [tm[0][0], -tm[1][0], -tm[2][0], tm[3][0]],
            [tm[0][1], -tm[1][1], -tm[2][1], tm[3][1]],
            [tm[0][2], -tm[1][2], -tm[2][2], tm[3][2]],
            [0, 0, 0, 1]
        ]
        
        fl_x, fl_y = frame["intrinsics_matrix"][0][0], frame["intrinsics_matrix"][1][1]
        cx, cy = frame["intrinsics_matrix"][2][0], frame["intrinsics_matrix"][2][1]
        
        w, h = 1920, 1440
        depth_w, depth_h = 256, 192
        scale_x = depth_w / w
        scale_y = depth_h / h
        
        cx_scaled = cx * scale_x
        cy_scaled = cy * scale_y
        fx_scaled = fl_x * scale_x
        fy_scaled = fl_y * scale_y
        
        with open(depth_path, "rb") as f:
            d = f.read()
        floats = struct.unpack(f"<{len(d)//4}f", d)
        
        out_path = os.path.join(out_dir, f"{base_name}.ptx")
        with open(out_path, "w") as f_out:
            f_out.write(f"{depth_w}\n")
            f_out.write(f"{depth_h}\n")
            # Scanner local registration mark (always identity)
            f_out.write("0 0 0\n")
            f_out.write("1 0 0\n")
            f_out.write("0 1 0\n")
            f_out.write("0 0 1\n")
            
            # Transformation matrix M (row-major for v_world = v_local * M)
            # This is the transpose of c2w
            f_out.write(f"{c2w[0][0]:.6f} {c2w[1][0]:.6f} {c2w[2][0]:.6f} 0.000000\n")
            f_out.write(f"{c2w[0][1]:.6f} {c2w[1][1]:.6f} {c2w[2][1]:.6f} 0.000000\n")
            f_out.write(f"{c2w[0][2]:.6f} {c2w[1][2]:.6f} {c2w[2][2]:.6f} 0.000000\n")
            f_out.write(f"{c2w[0][3]:.6f} {c2w[1][3]:.6f} {c2w[2][3]:.6f} 1.000000\n")
            
            idx = 0
            for r in range(depth_h):
                for c in range(depth_w):
                    z = floats[idx]
                    if z > 0.1 and z < 5.0:
                        x = (c - cx_scaled) * z / fx_scaled
                        y = (r - cy_scaled) * z / fy_scaled
                        
                        if img_data:
                            r_col, g_col, b_col = img_data[idx]
                        else:
                            r_col, g_col, b_col = 128, 128, 128
                            
                        # Output local coordinates!
                        f_out.write(f"{x:.6f} {y:.6f} {z:.6f} 0.5 {r_col} {g_col} {b_col}\n")
                    else:
                        f_out.write("0 0 0 0 0 0 0\n")
                    idx += 1

    print(f"Finished generating {len(frames)} PTX scans in {out_dir}!")

generate_ptx()
