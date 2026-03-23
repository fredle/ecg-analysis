FROM python:3.11-slim

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV TF_CPP_MIN_LOG_LEVEL=3

WORKDIR /app

# Install system dependencies for scipy/numpy
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libhdf5-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .
COPY templates/ templates/
COPY models/ models/

# Create uploads and data directories
RUN mkdir -p uploads data/raw

EXPOSE 5000

# Run with gunicorn for production (longer timeout for model loading + inference)
# Cloud Run sets $PORT; fall back to 5000 for local docker use
CMD gunicorn \
    --bind "0.0.0.0:${PORT:-5000}" \
    --timeout 600 \
    --workers 1 \
    --threads 4 \
    app:app
