#!/usr/bin/env bash
# Build and deploy the ECG analyser to Google Cloud Run.
#
# Usage:
#   ./deploy.sh                 # full build, push, deploy
#   ./deploy.sh --skip-build    # reuse existing local image
#   ./deploy.sh --skip-push     # deploy whatever is already in the registry
#   ./deploy.sh --skip-build --skip-push

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────
PROJECT="leatham-sandbox"
REGION="europe-west2"
REGISTRY="europe-west2-docker.pkg.dev/leatham-sandbox/leatham-acr"
IMAGE="ecg-analyser"
SERVICE="ecg-analyser"
FULL_TAG="$REGISTRY/$IMAGE:latest"

SKIP_BUILD=0
SKIP_PUSH=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --skip-push)  SKIP_PUSH=1  ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
    CYAN=""; GREEN=""; RESET=""
fi
step() { printf "\n%s==> %s%s\n" "$CYAN" "$1" "$RESET"; }
ok()   { printf "    %sOK: %s%s\n" "$GREEN" "$1" "$RESET"; }

# ── Build ────────────────────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    step "Building Docker image"
    docker compose build
    ok "Image built"
fi

# ── Tag ──────────────────────────────────────────────────────────────────────
step "Tagging image → $FULL_TAG"
docker tag "ecg-$IMAGE" "$FULL_TAG"
ok "Tagged"

# ── Push ─────────────────────────────────────────────────────────────────────
if [[ $SKIP_PUSH -eq 0 ]]; then
    step "Configuring Docker auth for Artifact Registry"
    gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

    step "Pushing image to Artifact Registry"
    docker push "$FULL_TAG"
    ok "Pushed"
fi

# ── Deploy ────────────────────────────────────────────────────────────────────
step "Deploying to Cloud Run ($SERVICE in $REGION)"
gcloud run deploy "$SERVICE" \
    --image "$FULL_TAG" \
    --region "$REGION" \
    --project "$PROJECT" \
    --platform managed \
    --quiet

# ── Done ──────────────────────────────────────────────────────────────────────
printf "\n%sDeployed successfully!%s\n" "$GREEN" "$RESET"
url=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" --format "value(status.url)" 2>/dev/null || true)
if [[ -n "$url" ]]; then
    printf "%sService URL: %s%s\n" "$CYAN" "$url" "$RESET"
fi
