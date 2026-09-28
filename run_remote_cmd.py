import modal

image = modal.Image.from_registry("nerfstudio/nerfstudio:latest")
app = modal.App("cmd-runner")

@app.function(image=image)
def run_cmd():
    import subprocess
    result = subprocess.run(["ns-export", "--help"], capture_output=True, text=True)
    return result.stdout

@app.local_entrypoint()
def main():
    print(run_cmd.remote())
