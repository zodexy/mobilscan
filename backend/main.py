import os
import uuid
import zipfile
import shutil
import asyncio
from fastapi import FastAPI, UploadFile, File, BackgroundTasks, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

app = FastAPI(title="Mobilscan Backend API")

# Store job statuses in memory (in production, use Redis or a database)
# job_id -> status ("processing", "completed", "failed")
jobs = {}

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
OUTPUT_DIR = os.path.join(BASE_DIR, "output")

os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)

class JobStatus(BaseModel):
    job_id: str
    status: str

async def process_scan(job_id: str, zip_path: str):
    """
    This function handles the extraction and Gaussian Splatting training.
    """
    job_dir = os.path.join(DATA_DIR, job_id)
    try:
        # 1. Unzip the file
        print(f"[{job_id}] Unzipping {zip_path}...")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(job_dir)
        
        # 2. Fix transforms (like we did manually in Colab)
        # TODO: call fix_transforms logic here if needed
        
        # 3. Run Gaussian Splatting / Nerfstudio training
        print(f"[{job_id}] Starting Gaussian Splatting training...")
        # Simulate training time
        await asyncio.sleep(10) 
        
        # 4. Generate the output .splat file
        # In a real scenario, the training outputs a .ply, and we might convert it to .splat
        output_file = os.path.join(OUTPUT_DIR, f"{job_id}.splat")
        
        # For now, just create a dummy .splat file to signify completion
        with open(output_file, "w") as f:
            f.write("DUMMY SPLAT DATA")
            
        print(f"[{job_id}] Training completed successfully.")
        jobs[job_id] = "completed"
        
    except Exception as e:
        print(f"[{job_id}] Failed during processing: {e}")
        jobs[job_id] = "failed"
    finally:
        # Cleanup zip file
        if os.path.exists(zip_path):
            os.remove(zip_path)
            
@app.post("/upload", response_model=JobStatus)
async def upload_scan(background_tasks: BackgroundTasks, file: UploadFile = File(...)):
    """
    Upload a Scan_X.zip file from the mobile app.
    Returns a job_id to poll for status.
    """
    if not file.filename.endswith('.zip'):
        raise HTTPException(status_code=400, detail="Only .zip files are allowed")
        
    job_id = str(uuid.uuid4())
    jobs[job_id] = "processing"
    
    zip_path = os.path.join(DATA_DIR, f"{job_id}.zip")
    
    with open(zip_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    # Start the processing in the background
    background_tasks.add_task(process_scan, job_id, zip_path)
    
    return JobStatus(job_id=job_id, status="processing")

@app.get("/status/{job_id}", response_model=JobStatus)
async def get_status(job_id: str):
    """
    Poll the status of a specific job.
    """
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
        
    return JobStatus(job_id=job_id, status=jobs[job_id])

@app.get("/download/{job_id}")
async def download_splat(job_id: str):
    """
    Download the generated .splat file once processing is completed.
    """
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
        
    if jobs[job_id] != "completed":
        raise HTTPException(status_code=400, detail="Job is not completed yet")
        
    output_file = os.path.join(OUTPUT_DIR, f"{job_id}.splat")
    if not os.path.exists(output_file):
        raise HTTPException(status_code=404, detail="Splat file not found")
        
    return FileResponse(output_file, filename=f"scan_{job_id}.splat")

@app.get("/view/{job_id}")
async def view_splat(job_id: str):
    """
    Serve the HTML viewer for a specific job.
    """
    html_path = os.path.join(BASE_DIR, "..", "web-viewer", "index.html")
    if not os.path.exists(html_path):
        raise HTTPException(status_code=404, detail="Viewer not found")
        
    with open(html_path, "r", encoding="utf-8") as f:
        html_content = f.read()
        
    return HTMLResponse(content=html_content, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
