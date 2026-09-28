import urllib.request, json, zipfile, io
req = urllib.request.Request('https://api.github.com/repos/zodexy/mobilscan/actions/runs?per_page=1')
runs = json.loads(urllib.request.urlopen(req).read())
run_id = runs['workflow_runs'][0]['id']
print(f'Run ID: {run_id}')
req = urllib.request.Request(f'https://api.github.com/repos/zodexy/mobilscan/actions/runs/{run_id}/logs')
try:
    res = urllib.request.urlopen(req)
    z = zipfile.ZipFile(io.BytesIO(res.read()))
    for name in z.namelist():
        if 'Build Unsigned App' in name:
            log = z.read(name).decode('utf-8', errors='replace')
            lines = log.split('\n')
            errs = [i for i, l in enumerate(lines) if 'error:' in l.lower()]
            for i in errs:
                print('\n'.join(lines[max(0, i-2):i+3]))
                print('---')
except Exception as e:
    print(e)
