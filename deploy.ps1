#Requires -Version 5.1
<#
.SYNOPSIS
    Build and deploy the ECG analyser to Google Cloud Run.
.DESCRIPTION
    Builds the Docker image, pushes to Artifact Registry, and deploys to Cloud Run.
.PARAMETER SkipBuild
    Skip the docker build step (use the existing local image).
.PARAMETER SkipPush
    Skip the push step (deploy whatever is already in the registry).
#>
param(
    [switch]$SkipBuild,
    [switch]$SkipPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Config ─────────────────────────────────────────────────────────────────
$PROJECT   = "leatham-sandbox"
$REGION    = "europe-west2"
$REGISTRY  = "europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr"
$IMAGE     = "ecg-analyser"
$SERVICE   = "ecg-analyser"
$FULL_TAG  = "$REGISTRY/$IMAGE`:latest"

# ── Helpers ─────────────────────────────────────────────────────────────────
function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}
function Write-OK([string]$msg) {
    Write-Host "    OK: $msg" -ForegroundColor Green
}

# ── Build ────────────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Step "Building Docker image"
    docker compose build
    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
    Write-OK "Image built"
}

# ── Tag ──────────────────────────────────────────────────────────────────────
Write-Step "Tagging image → $FULL_TAG"
docker tag "ecg-$IMAGE" $FULL_TAG
if ($LASTEXITCODE -ne 0) { throw "docker tag failed" }
Write-OK "Tagged"

# ── Push ─────────────────────────────────────────────────────────────────────
if (-not $SkipPush) {
    Write-Step "Configuring Docker auth for Artifact Registry"
    gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
    if ($LASTEXITCODE -ne 0) { throw "gcloud auth configure-docker failed" }

    Write-Step "Pushing image to Artifact Registry"
    docker push $FULL_TAG
    if ($LASTEXITCODE -ne 0) { throw "docker push failed" }
    Write-OK "Pushed"
}

# ── Deploy ────────────────────────────────────────────────────────────────────
Write-Step "Deploying to Cloud Run ($SERVICE in $REGION)"
gcloud run deploy $SERVICE `
    --image $FULL_TAG `
    --region $REGION `
    --project $PROJECT `
    --platform managed `
    --quiet
if ($LASTEXITCODE -ne 0) { throw "gcloud run deploy failed" }

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Deployed successfully!" -ForegroundColor Green
$url = gcloud run services describe $SERVICE --region $REGION --project $PROJECT --format "value(status.url)" 2>$null
if ($url) { Write-Host "Service URL: $url" -ForegroundColor Cyan }
