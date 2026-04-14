# ECG Analyser

A web application that accepts Holter ECG R-file uploads, decodes them, classifies beats using a HeartKit deep learning model, detects bigeminy episodes, and displays an interactive timeline dashboard.

## Features

- **Upload** binary R-files from ECG Browser / Viatom Holter monitors
- **Decode** delta-compressed ECG signals (125 Hz → resampled to 100 Hz)
- **Classify** each beat as Normal QRS / PAC / PVC using HeartKit BEAT-3-EFF-SM (EfficientNetV2, 3-class)
- **Detect** bigeminy episodes (alternating Normal–PVC runs ≥ 6 beats)
- **Visualise** results with an interactive timeline, density heatmap, hourly burden chart, and episode list
- **Persist** all bigeminy episodes in a single Parquet file; re-uploading a recording overwrites episodes for that time period
- **Archive** every uploaded R-file in `data/raw/`

## Project Structure

```
├── app.py                  # Flask web application (decoder + classifier + routes)
├── templates/
│   ├── index.html          # Upload page with drag-and-drop
│   ├── processing.html     # Progress/spinner during analysis
│   └── results.html        # Interactive timeline dashboard
├── models/
│   └── beat-3-eff-sm/
│       ├── model.keras      # HeartKit beat classifier model
│       ├── model.tflite
│       ├── configuration.json
│       └── metrics.json
├── data/                    # Persistent storage (GCS-mounted in Cloud Run)
│   ├── raw/                 # Permanent archive of uploaded R-files
│   └── bigeminy_episodes.parquet  # All-time episode data
├── uploads/                 # Temporary per-session files
├── requirements.txt
├── Dockerfile
├── docker-compose.yml
└── .vscode/
    └── launch.json          # VS Code debug configuration
```

## Prerequisites

- **Python 3.11+**
- **Docker** (for containerised deployment)
- **Google Cloud SDK** (for Cloud Run deployment)

---

## Local Development

### 1. Create a virtual environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

### 2. Install dependencies

```powershell
pip install -r requirements.txt
```

### 3. Run the development server

```powershell
python app.py
```

Opens at **http://localhost:5000** with Flask debug mode (auto-reload on code changes, in-browser tracebacks).

### 4. Debug in VS Code

Press **F5** to launch the app with the VS Code debugger attached. The launch configuration is in `.vscode/launch.json`:

- Set breakpoints anywhere in `app.py`
- Step through the analysis pipeline
- Inspect variables (decoded samples, beat classifications, episodes)
- Jinja2 template debugging is enabled

### 5. Test with sample files

Upload R-files from the `data/raw/` or `import/` folder. File names must match the pattern `R{YYYYMMDDHHMMSS}` (e.g. `R20260305212215`).

---

## Docker (Local)

### Build

```powershell
docker build -t ecg-analyser .
```

### Run

```powershell
docker run -p 5000:5000 -v ecg-data:/app/data ecg-analyser
```

Opens at **http://localhost:5000**. The named volume `ecg-data` persists the Parquet file and raw R-files across container restarts.

### Docker Compose

```powershell
docker compose up --build
```

This uses `docker-compose.yml` which sets up persistent volumes for both `uploads/` and `data/`.

---

## Deploy to Google Cloud Run

### 1. Authenticate

```powershell
gcloud auth login
gcloud config set project leatham-sandbox
gcloud auth configure-docker europe-west2-docker.pkg.dev
```

### 2. Create a GCS bucket for persistent storage

```powershell
gcloud storage buckets create gs://ecg-analyser --location=europe-west2
```

### 3. Build, tag, and push the image

```powershell
docker build -t ecg-analyser .
docker tag ecg-analyser europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser
docker push europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser
```

### 4. Deploy to Cloud Run

```powershell
gcloud run deploy ecg-analyser `
  --image europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser `
  --region europe-west2 `
  --port 5000 `
  --memory 4Gi `
  --cpu 2 `
  --timeout 600 `
  --max-instances 1 `
  --execution-environment gen2 `
  --add-volume "name=ecg-data,type=cloud-storage,bucket=ecg-analyser" `
  --add-volume-mount "volume=ecg-data,mount-path=/app/data" `
  --allow-unauthenticated
```

Key flags:
| Flag | Purpose |
|---|---|
| `--execution-environment gen2` | Required for GCS FUSE volume mounts |
| `--add-volume` | Mounts the GCS bucket as a filesystem volume |
| `--timeout 600` | Allows time for long ECG recordings |
| `--max-instances 1` | Single-writer to avoid Parquet conflicts |
| `--memory 4Gi --cpu 2` | TensorFlow + large signal processing |

### 5. Grant bucket permissions

Find the Cloud Run service account:

```powershell
gcloud run services describe ecg-analyser --region europe-west2 `
  --format="value(spec.template.spec.serviceAccountName)"
```

Grant it access to the bucket:

```powershell
gcloud storage buckets add-iam-policy-binding gs://ecg-analyser `
  --member="serviceAccount:945103730531-compute@developer.gserviceaccount.com" `
  --role="roles/storage.objectAdmin"
```

### 6. Access

The service URL is shown after deployment, e.g.:

```
https://ecg-analyser-945103730531.europe-west2.run.app
```

---

## Redeploying After Code Changes

```powershell
docker build -t ecg-analyser .
docker tag ecg-analyser europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser
docker push europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser
gcloud run deploy ecg-analyser `
  --image europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr/ecg-analyser `
  --region europe-west2
```

Only the `--image` and `--region` flags are needed for updates — the volume mount and other settings are retained from the previous deployment.

---

## How It Works

1. **Upload**: R-files are saved to a temp session folder and permanently archived to `data/raw/`
2. **Decode**: Binary delta-compressed samples are expanded to a 125 Hz signal
3. **Resample**: Polyphase resampling from 125 Hz to 100 Hz (model input rate)
4. **R-peak detection**: PhysioKit identifies R-peaks in the cleaned/normalised ECG
5. **Beat classification**: 512-sample windows around each peak are layer-normalised and classified in batches by the Keras model (QRS / PAC / PVC)
6. **Bigeminy detection**: Alternating Normal–PVC runs of ≥ 6 beats are flagged as episodes
7. **Persistence**: Episodes are written to `data/bigeminy_episodes.parquet`, replacing any existing episodes within the recording's time range
8. **Visualisation**: The results page renders an interactive timeline, density heatmap, hourly burden chart, and filterable episode table

## Supported File Format

Binary R-files from ECG Browser / Viatom Holter monitors:
- Filename pattern: `R{YYYYMMDDHHMMSS}` (timestamp encoded in the name)
- 9-byte header (version, channels, reserved, header_size)
- Delta-compressed single-channel data: `0x80` = absolute 16-bit LE, `0x7F XX` = extended positive delta, `0x81 XX` = extended negative delta, single bytes for small deltas
- Sample rate: 125 Hz
