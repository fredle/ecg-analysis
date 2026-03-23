"""
ECG Browser R-file Decoder
==========================
Decodes the delta-compressed single-channel ECG binary format used by
the ECG Browser application (Viatom/Vihealth Holter monitors).

File naming: {device_id}R{YYYYMMDDHHMMSS} or R{YYYYMMDDHHMMSS} (import folder)

FORMAT
------
Header (9 bytes):
  Byte 0: Version (observed: 0x01)
  Byte 1: Channel count (observed: 0x02)
  Bytes 2-7: Reserved (zeros)
  Byte 8: Header size (0x09 = 9)

Data section (remaining bytes):
  Byte 0 of data: Padding / unused (always 0x00)
  Remaining bytes use variable-length delta encoding:

  0x80         -> Absolute value: next 2 bytes = signed 16-bit LE sample value
                  (used as periodic sync points every ~7500 samples / 60s,
                   and for the first sample)
  0x7F XX      -> Extended positive delta: delta = +(127 + unsigned(XX))
                  Range: +127 to +382
  0x81 XX      -> Extended negative delta: delta = -(127 + unsigned(XX))
                  Range: -127 to -382
  0x00-0x7E    -> Single-byte delta: signed value 0 to +126
  0x82-0xFF    -> Single-byte delta: signed value -126 to -1

Sample rate: 125 Hz (from device metadata)
Resolution: 16-bit signed
"""

import struct
import os
import sys
import re
from datetime import datetime, timedelta


def decode_ecg_r_file(filepath):
    """
    Decode an ECG Browser R-file (delta-compressed) into raw 16-bit samples.

    Args:
        filepath: Path to the R-file

    Returns:
        list[int]: Decoded 16-bit signed ECG sample values
    """
    with open(filepath, "rb") as f:
        file_data = f.read()

    if len(file_data) < 12:
        raise ValueError("File too small to be a valid R-file")

    # Parse header
    header = file_data[:9]
    version = header[0]
    channels = header[1]
    header_size = header[8]

    if header_size != 9:
        raise ValueError(f"Unexpected header size: {header_size}")

    data = file_data[9:]
    samples = []
    acc = 0
    i = 1  # Skip first padding byte

    while i < len(data):
        b = data[i]

        if b == 0x80:
            # Absolute 16-bit LE value (sync point)
            if i + 2 < len(data):
                acc = struct.unpack_from('<h', data, i + 1)[0]
                samples.append(acc)
                i += 3
            else:
                break

        elif b == 0x7F:
            # Extended positive delta: +(127 + unsigned next byte)
            if i + 1 < len(data):
                acc += 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break

        elif b == 0x81:
            # Extended negative delta: -(127 + unsigned next byte)
            if i + 1 < len(data):
                acc -= 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break

        else:
            # Single-byte signed delta (-126 to +126, or 0)
            delta = b - 256 if b > 127 else b
            acc += delta
            samples.append(acc)
            i += 1

    return samples


SAMPLE_RATE = 125  # Hz
SAMPLE_INTERVAL = timedelta(seconds=1 / SAMPLE_RATE)  # 8ms per sample


def parse_timestamp_from_filename(filepath):
    """
    Extract the recording start timestamp from an R-file filename.

    Supports:
      R{YYYYMMDDHHMMSS}             (import folder)
      {device_id}R{YYYYMMDDHHMMSS}  (userfiles folder)

    Returns:
        datetime: Recording start time
    """
    basename = os.path.basename(filepath)
    match = re.search(r'R(\d{14})$', basename)
    if not match:
        raise ValueError(f"Cannot extract timestamp from filename: {basename}")
    ts_str = match.group(1)
    return datetime.strptime(ts_str, "%Y%m%d%H%M%S")


def get_sample_timestamp(start_time, sample_index):
    """Get the absolute timestamp for a given sample index."""
    return start_time + timedelta(seconds=sample_index / SAMPLE_RATE)


def decode_ecg(filepath):
    """
    Decode an R-file and return samples with timing information.

    Args:
        filepath: Path to the R-file

    Returns:
        dict with keys:
            'samples': list[int] - decoded sample values
            'start_time': datetime - recording start timestamp
            'end_time': datetime - recording end timestamp
            'sample_rate': int - samples per second (125)
            'duration_seconds': float - total duration
            'filepath': str - source file path
    """
    samples = decode_ecg_r_file(filepath)
    start_time = parse_timestamp_from_filename(filepath)
    duration_sec = len(samples) / SAMPLE_RATE
    end_time = start_time + timedelta(seconds=duration_sec)

    return {
        'samples': samples,
        'start_time': start_time,
        'end_time': end_time,
        'sample_rate': SAMPLE_RATE,
        'duration_seconds': duration_sec,
        'num_samples': len(samples),
        'filepath': filepath,
    }


def find_r_files(directory):
    """Find all R-files in a directory."""
    r_files = []
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if os.path.isfile(full_path) and re.search(r'R\d{14}$', entry):
            r_files.append(full_path)
    return sorted(r_files)


def main():
    if len(sys.argv) < 2:
        # Auto-detect: look in import folder, then userfiles
        base_data = r"c:\Users\freddieleatham\AppData\Local\ECG Browser\DATA"
        search_dirs = [
            os.path.join(base_data, "import"),
            os.path.join(base_data, "userfiles", "subusr", "1"),
        ]
        all_files = []
        for d in search_dirs:
            if os.path.isdir(d):
                found = find_r_files(d)
                if found:
                    all_files.extend(found)
                    break  # use the first directory that has R-files

        if not all_files:
            print("No R-files found. Pass a file path as argument.")
            sys.exit(1)
        filepaths = all_files
    else:
        filepaths = sys.argv[1:]

    for filepath in filepaths:
        print(f"{'=' * 60}")
        print(f"File: {os.path.basename(filepath)}")
        print(f"Size: {os.path.getsize(filepath):,} bytes")

        result = decode_ecg(filepath)

        hours = result['duration_seconds'] / 3600
        print(f"Start:    {result['start_time'].strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"End:      {result['end_time'].strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"Duration: {hours:.2f} hours ({result['duration_seconds']:.0f}s)")
        print(f"Samples:  {result['num_samples']:,} @ {result['sample_rate']} Hz")
        print(f"Range:    {min(result['samples'])} to {max(result['samples'])}")

        # Show a few sample timestamps
        print(f"\nSample timestamps:")
        for idx in [0, result['num_samples'] // 4, result['num_samples'] // 2,
                     3 * result['num_samples'] // 4, result['num_samples'] - 1]:
            ts = get_sample_timestamp(result['start_time'], idx)
            print(f"  [{idx:>10,}] {ts.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  "
                  f"value={result['samples'][idx]}")
        print()


if __name__ == "__main__":
    main()
