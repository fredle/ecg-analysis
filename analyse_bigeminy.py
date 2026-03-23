"""
Bigeminy Analysis using HeartKit BEAT-3-EFF-SM
===============================================
Decodes ECG R-files, runs heartkit's pre-trained beat classifier
to detect PVCs, then identifies bigeminy episodes (alternating
Normal-PVC pattern) throughout the recording.

Outputs a JSON report with all bigeminy episodes and their timestamps.
"""

import os
import sys
import json
import struct
import re
import numpy as np
from datetime import datetime, timedelta
from scipy.signal import resample_poly
from math import gcd

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ORIG_SAMPLE_RATE = 125       # Hz - device native rate
MODEL_SAMPLE_RATE = 100      # Hz - heartkit model expected rate
FRAME_SIZE = 512             # samples at 100 Hz (~5.12s)
CONFIDENCE_THRESHOLD = 0.5   # minimum softmax probability to accept classification
MIN_BIGEMINY_BEATS = 6       # minimum consecutive alternating N-PVC beats to count as bigeminy episode

CLASS_NAMES = ["QRS", "PAC", "PVC"]  # class 0=normal, 1=PAC, 2=PVC

BASE_DATA = r"c:\Users\freddieleatham\AppData\Local\ECG Browser\DATA"
MODEL_DIR = os.path.join(BASE_DATA, "models", "beat-3-eff-sm")
MODEL_PATH = os.path.join(MODEL_DIR, "model.keras")


# ---------------------------------------------------------------------------
# R-file decoder (from decode_ecg.py)
# ---------------------------------------------------------------------------
def decode_ecg_r_file(filepath):
    """Decode an ECG Browser R-file (delta-compressed) into raw 16-bit samples."""
    with open(filepath, "rb") as f:
        file_data = f.read()

    if len(file_data) < 12:
        raise ValueError("File too small to be a valid R-file")

    header = file_data[:9]
    header_size = header[8]
    if header_size != 9:
        raise ValueError(f"Unexpected header size: {header_size}")

    data = file_data[9:]
    samples = []
    acc = 0
    i = 1  # skip padding byte

    while i < len(data):
        b = data[i]
        if b == 0x80:
            if i + 2 < len(data):
                acc = struct.unpack_from('<h', data, i + 1)[0]
                samples.append(acc)
                i += 3
            else:
                break
        elif b == 0x7F:
            if i + 1 < len(data):
                acc += 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break
        elif b == 0x81:
            if i + 1 < len(data):
                acc -= 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break
        else:
            delta = b - 256 if b > 127 else b
            acc += delta
            samples.append(acc)
            i += 1

    return samples


def parse_timestamp_from_filename(filepath):
    """Extract recording start timestamp from R-file filename."""
    basename = os.path.basename(filepath)
    match = re.search(r'R(\d{14})$', basename)
    if not match:
        raise ValueError(f"Cannot extract timestamp from filename: {basename}")
    return datetime.strptime(match.group(1), "%Y%m%d%H%M%S")


def find_r_files(directory):
    """Find all R-files in a directory."""
    r_files = []
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if os.path.isfile(full_path) and re.search(r'R\d{14}$', entry):
            r_files.append(full_path)
    return sorted(r_files)


# ---------------------------------------------------------------------------
# Signal processing
# ---------------------------------------------------------------------------
def resample_125_to_100(signal_125):
    """Resample from 125 Hz to 100 Hz using polyphase filter (rational 4/5)."""
    # 100/125 = 4/5
    return resample_poly(signal_125, up=4, down=5).astype(np.float32)


def layer_norm(x, epsilon=0.01):
    """Z-score normalisation matching heartkit's layer_norm preprocessor."""
    mean = np.mean(x)
    std = np.std(x)
    return (x - mean) / (std + epsilon)


# ---------------------------------------------------------------------------
# Beat classification
# ---------------------------------------------------------------------------
def classify_beats(ecg_100hz, peaks, model, batch_size=256):
    """
    Classify each beat using the heartkit BEAT-3-EFF-SM model (batched).

    For each R-peak, extracts a 512-sample window centred on the peak,
    applies layer normalisation, then runs batched inference for speed.

    Args:
        ecg_100hz: ECG signal resampled to 100 Hz (numpy array)
        peaks: array of R-peak indices in the 100 Hz signal
        model: loaded keras model
        batch_size: number of windows per batch for model.predict()

    Returns:
        beat_classes: array of class indices (0=QRS, 1=PAC, 2=PVC, -1=unclassified)
        beat_probs: array of classification confidence values
    """
    n_peaks = len(peaks)
    beat_classes = np.full(n_peaks, -1, dtype=np.int32)
    beat_probs = np.zeros(n_peaks, dtype=np.float32)

    half_frame = FRAME_SIZE // 2  # 256 samples

    # Pre-extract all valid windows
    valid_indices = []
    windows = []
    for i in range(n_peaks):
        start = peaks[i] - half_frame
        stop = start + FRAME_SIZE
        if start < 0 or stop > len(ecg_100hz):
            continue
        window = ecg_100hz[start:stop].copy()
        window = layer_norm(window, epsilon=0.01)
        windows.append(window)
        valid_indices.append(i)

    if not windows:
        return beat_classes, beat_probs

    # Stack into single array (N, 512, 1)
    X = np.array(windows, dtype=np.float32).reshape(-1, FRAME_SIZE, 1)
    print(f"    Running batched inference on {len(X)} windows...")

    # Batched prediction — much faster than individual calls
    logits = model.predict(X, batch_size=batch_size, verbose=1)

    # Apply softmax
    from scipy.special import softmax as scipy_softmax
    probs = scipy_softmax(logits, axis=-1)

    pred_classes = np.argmax(probs, axis=-1)
    pred_probs = np.max(probs, axis=-1)

    for idx, vi in enumerate(valid_indices):
        if pred_probs[idx] >= CONFIDENCE_THRESHOLD:
            beat_classes[vi] = int(pred_classes[idx])
        else:
            beat_classes[vi] = 0  # default to normal if below threshold
        beat_probs[vi] = float(pred_probs[idx])

    return beat_classes, beat_probs


# ---------------------------------------------------------------------------
# Bigeminy detection
# ---------------------------------------------------------------------------
def detect_bigeminy_episodes(peaks, beat_classes, beat_probs, start_time,
                              min_beats=MIN_BIGEMINY_BEATS):
    """
    Detect bigeminy episodes: alternating Normal(0) - PVC(2) pattern.

    Bigeminy = every other beat is a PVC, so the pattern is:
      Normal, PVC, Normal, PVC, Normal, PVC, ...

    Args:
        peaks: R-peak indices in the 100 Hz signal
        beat_classes: class for each beat (0=QRS, 1=PAC, 2=PVC)
        beat_probs: confidence for each beat
        start_time: recording start datetime
        min_beats: minimum number of beats in a bigeminy run

    Returns:
        list of episode dicts
    """
    episodes = []
    n = len(beat_classes)
    i = 0

    while i < n - 1:
        # Look for the start of a bigeminy pattern
        # Check if we have Normal-PVC or PVC-Normal starting
        run_start = None
        run_beats = []

        # Try starting with Normal (class 0) at position i
        if beat_classes[i] == 0 and i + 1 < n and beat_classes[i + 1] == 2:
            # Found N-PVC start
            j = i
            while j < n:
                expected = 0 if (j - i) % 2 == 0 else 2  # alternating N, PVC
                if beat_classes[j] == expected:
                    run_beats.append(j)
                    j += 1
                else:
                    break

            if len(run_beats) >= min_beats:
                run_start = run_beats[0]
                run_end = run_beats[-1]

                peak_start = peaks[run_start]
                peak_end = peaks[run_end]

                ts_start = start_time + timedelta(seconds=peak_start / MODEL_SAMPLE_RATE)
                ts_end = start_time + timedelta(seconds=peak_end / MODEL_SAMPLE_RATE)
                duration = (peak_end - peak_start) / MODEL_SAMPLE_RATE

                n_normal = sum(1 for b in run_beats if beat_classes[b] == 0)
                n_pvc = sum(1 for b in run_beats if beat_classes[b] == 2)
                avg_conf = float(np.mean([beat_probs[b] for b in run_beats]))

                episodes.append({
                    "start_time": ts_start.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
                    "end_time": ts_end.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
                    "duration_seconds": round(duration, 2),
                    "total_beats": len(run_beats),
                    "normal_beats": n_normal,
                    "pvc_beats": n_pvc,
                    "avg_confidence": round(avg_conf, 3),
                    "start_sample_100hz": int(peak_start),
                    "end_sample_100hz": int(peak_end),
                })

                # Skip past this episode
                i = run_beats[-1] + 1
                continue

        i += 1

    return episodes


# ---------------------------------------------------------------------------
# Hourly summary
# ---------------------------------------------------------------------------
def compute_hourly_summary(peaks, beat_classes, start_time, total_duration_sec):
    """Compute hourly beat counts and bigeminy burden."""
    hours = int(np.ceil(total_duration_sec / 3600))
    summary = []

    for h in range(hours):
        hour_start_sec = h * 3600
        hour_end_sec = min((h + 1) * 3600, total_duration_sec)
        hour_start_sample = int(hour_start_sec * MODEL_SAMPLE_RATE)
        hour_end_sample = int(hour_end_sec * MODEL_SAMPLE_RATE)

        mask = (peaks >= hour_start_sample) & (peaks < hour_end_sample)
        hour_classes = beat_classes[mask]

        n_total = int(np.sum(mask))
        n_normal = int(np.sum(hour_classes == 0))
        n_pac = int(np.sum(hour_classes == 1))
        n_pvc = int(np.sum(hour_classes == 2))
        n_unclassified = int(np.sum(hour_classes == -1))

        ts = start_time + timedelta(seconds=hour_start_sec)

        summary.append({
            "hour": ts.strftime("%Y-%m-%d %H:%M"),
            "total_beats": n_total,
            "normal_beats": n_normal,
            "pac_beats": n_pac,
            "pvc_beats": n_pvc,
            "unclassified_beats": n_unclassified,
            "pvc_burden_pct": round(100 * n_pvc / n_total, 2) if n_total > 0 else 0,
        })

    return summary


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print("=" * 60)
    print("Bigeminy Analysis using HeartKit BEAT-3-EFF-SM")
    print("=" * 60)

    # Suppress TF warnings
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "2"

    import keras
    import physiokit as pk

    # Load model
    print(f"\nLoading model from {MODEL_PATH}...")
    model = keras.models.load_model(MODEL_PATH)
    print(f"  Model loaded: input={model.input_shape}, output={model.output_shape}")

    # Find R-files
    search_dirs = [
        os.path.join(BASE_DATA, "import"),
        os.path.join(BASE_DATA, "userfiles", "subusr", "1"),
    ]
    all_files = []
    for d in search_dirs:
        if os.path.isdir(d):
            found = find_r_files(d)
            if found:
                all_files.extend(found)
                break

    if not all_files:
        print("No R-files found.")
        sys.exit(1)

    print(f"\nFound {len(all_files)} R-file(s)")

    # Process each file and build combined report
    all_results = []

    for filepath in all_files:
        basename = os.path.basename(filepath)
        print(f"\n{'─' * 60}")
        print(f"Processing: {basename}")
        print(f"  File size: {os.path.getsize(filepath):,} bytes")

        # 1. Decode
        print("  Decoding R-file...")
        raw_samples = decode_ecg_r_file(filepath)
        start_time = parse_timestamp_from_filename(filepath)
        print(f"  Decoded {len(raw_samples):,} samples @ {ORIG_SAMPLE_RATE} Hz")
        print(f"  Start time: {start_time.strftime('%Y-%m-%d %H:%M:%S')}")

        # 2. Convert to float and resample 125 -> 100 Hz
        print("  Resampling 125 Hz -> 100 Hz...")
        ecg_125 = np.array(raw_samples, dtype=np.float32)
        ecg_100 = resample_125_to_100(ecg_125)
        duration_sec = len(ecg_100) / MODEL_SAMPLE_RATE
        print(f"  Resampled to {len(ecg_100):,} samples @ {MODEL_SAMPLE_RATE} Hz")
        print(f"  Duration: {duration_sec / 3600:.2f} hours")

        # 3. Find R-peaks using physiokit
        print("  Finding R-peaks...")
        ecg_clean = pk.ecg.clean(ecg_100, sample_rate=MODEL_SAMPLE_RATE)
        ecg_norm = pk.signal.normalize_signal(ecg_clean, eps=0.1, axis=None)
        peaks = pk.ecg.find_peaks(ecg_norm, sample_rate=MODEL_SAMPLE_RATE)
        peaks = np.array(peaks, dtype=np.int32)
        print(f"  Found {len(peaks):,} R-peaks")

        if len(peaks) == 0:
            print("  WARNING: No R-peaks found, skipping file.")
            continue

        avg_hr = 60 * len(peaks) / duration_sec
        print(f"  Average HR: {avg_hr:.0f} bpm")

        # 4. Classify each beat
        print("  Classifying beats (this may take a few minutes)...")
        beat_classes, beat_probs = classify_beats(ecg_100, peaks, model)

        n_normal = int(np.sum(beat_classes == 0))
        n_pac = int(np.sum(beat_classes == 1))
        n_pvc = int(np.sum(beat_classes == 2))
        n_unk = int(np.sum(beat_classes == -1))
        print(f"  Beat classification: QRS={n_normal}, PAC={n_pac}, PVC={n_pvc}, Unclassified={n_unk}")

        # 5. Detect bigeminy episodes
        print("  Detecting bigeminy episodes...")
        episodes = detect_bigeminy_episodes(peaks, beat_classes, beat_probs, start_time)
        print(f"  Found {len(episodes)} bigeminy episode(s)")

        for ep_idx, ep in enumerate(episodes):
            print(f"    Episode {ep_idx + 1}: {ep['start_time']} - {ep['end_time']} "
                  f"({ep['duration_seconds']}s, {ep['total_beats']} beats, "
                  f"conf={ep['avg_confidence']:.2f})")

        # 6. Hourly summary
        hourly = compute_hourly_summary(peaks, beat_classes, start_time, duration_sec)

        end_time = start_time + timedelta(seconds=duration_sec)

        file_result = {
            "file": basename,
            "start_time": start_time.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_time.strftime("%Y-%m-%d %H:%M:%S"),
            "duration_hours": round(duration_sec / 3600, 2),
            "sample_rate_original": ORIG_SAMPLE_RATE,
            "sample_rate_analysis": MODEL_SAMPLE_RATE,
            "total_beats": len(peaks),
            "beat_summary": {
                "normal_qrs": n_normal,
                "pac": n_pac,
                "pvc": n_pvc,
                "unclassified": n_unk,
                "pvc_burden_pct": round(100 * n_pvc / len(peaks), 2) if len(peaks) > 0 else 0,
            },
            "bigeminy_episodes": episodes,
            "bigeminy_summary": {
                "total_episodes": len(episodes),
                "total_bigeminy_beats": sum(ep["total_beats"] for ep in episodes),
                "total_bigeminy_seconds": round(sum(ep["duration_seconds"] for ep in episodes), 2),
            },
            "hourly_summary": hourly,
        }

        all_results.append(file_result)

    # Build final report
    report = {
        "analysis": "Bigeminy Detection",
        "model": "HeartKit BEAT-3-EFF-SM (EfficientNetV2, 3-class)",
        "model_classes": CLASS_NAMES,
        "confidence_threshold": CONFIDENCE_THRESHOLD,
        "min_bigeminy_beats": MIN_BIGEMINY_BEATS,
        "analysis_timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "recordings": all_results,
    }

    # Compute overall summary across all recordings
    total_episodes = sum(r["bigeminy_summary"]["total_episodes"] for r in all_results)
    total_pvc = sum(r["beat_summary"]["pvc"] for r in all_results)
    total_beats = sum(r["total_beats"] for r in all_results)

    report["overall_summary"] = {
        "total_recordings": len(all_results),
        "total_beats_analysed": total_beats,
        "total_pvc": total_pvc,
        "overall_pvc_burden_pct": round(100 * total_pvc / total_beats, 2) if total_beats > 0 else 0,
        "total_bigeminy_episodes": total_episodes,
        "total_bigeminy_seconds": round(
            sum(r["bigeminy_summary"]["total_bigeminy_seconds"] for r in all_results), 2
        ),
    }

    # Save JSON report
    output_path = os.path.join(BASE_DATA, "bigeminy_report.json")
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)

    print(f"\n{'=' * 60}")
    print(f"REPORT SAVED: {output_path}")
    print(f"{'=' * 60}")
    print(f"Total recordings:      {report['overall_summary']['total_recordings']}")
    print(f"Total beats analysed:  {report['overall_summary']['total_beats_analysed']:,}")
    print(f"Total PVCs:            {report['overall_summary']['total_pvc']:,}")
    print(f"PVC burden:            {report['overall_summary']['overall_pvc_burden_pct']}%")
    print(f"Bigeminy episodes:     {report['overall_summary']['total_bigeminy_episodes']}")
    print(f"Bigeminy total time:   {report['overall_summary']['total_bigeminy_seconds']}s")


if __name__ == "__main__":
    main()
