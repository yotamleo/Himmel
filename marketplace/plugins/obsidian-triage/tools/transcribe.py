#!/usr/bin/env python3
"""transcribe.py - local faster-whisper transcript of one WAV. stdout = text.

Invoked by ig-media-fetch.py via:
  uv run --python 3.12 --with faster-whisper python transcribe.py <wav> [model]

No network at call time beyond the one-time model-weights fetch uv/faster-whisper
performs on first use (cached under the HF cache dir thereafter). CPU int8."""
import sys

def main():
    if len(sys.argv) < 2:
        print("usage: transcribe.py <wav> [model]", file=sys.stderr)
        sys.exit(1)
    wav = sys.argv[1]
    model_name = sys.argv[2] if len(sys.argv) > 2 else "base"
    from faster_whisper import WhisperModel
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    segments, _info = model.transcribe(wav)
    text = " ".join(seg.text.strip() for seg in segments).strip()
    sys.stdout.write(text + "\n")

if __name__ == "__main__":
    main()
