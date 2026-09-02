import modal
from modal.mount import Mount
import subprocess
import os

app = modal.App("deployer")

# Create a Modal environment that runs Python 3.10
image = modal.Image.debian_slim(python_version="3.10").pip_install("modal", "fastapi", "pydantic", "python-multipart", "uvicorn").add_local_dir("backend", remote_path="/root/backend")

@app.function(image=image, timeout=1800)
def deploy():
    # Set the credentials in the environment
    env = os.environ.copy()
    env["MODAL_TOKEN_ID"] = "ak-NWIyQkot6KmzglU3XSYOvG"
    env["MODAL_TOKEN_SECRET"] = "as-4kSHP7Lboo900COw5ZLyrM"
    
    # Deploy modal_app.py from inside the cloud (Python 3.10)
    print("Starting remote deploy...")
    result = subprocess.run(["python", "-m", "modal", "deploy", "/root/backend/modal_app.py"], env=env, capture_output=True, text=True)
    
    print("STDOUT:")
    print(result.stdout)
    if result.stderr:
        print("STDERR:")
        print(result.stderr)
    
    if result.returncode != 0:
        raise Exception("Remote deploy failed")
    print("Remote deploy succeeded!")
