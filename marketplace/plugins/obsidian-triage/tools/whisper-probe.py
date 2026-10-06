#!/usr/bin/env python3
"""whisper-probe.py - prove the pinned faster-whisper + av pair can decode audio
(HIMMEL-4675). Run it the way the media rungs run transcribe.py:

  uv run --python 3.12 --with-requirements <plugin>/tools/requirements-whisper.txt python whisper-probe.py

It writes a 0.2 s silent WAV and calls faster_whisper.decode_audio on it, the
exact av.open path that raised `open() got an unexpected keyword argument
'metadata_errors'` when av was newer than faster-whisper supports. No model
download, no network. Exit 0 and `whisper-probe: ok faster-whisper=X av=Y`, or
exit 1 with the error."""
import os
import sys
import tempfile
import wave


def main():
    try:
        import av
        import faster_whisper
        from faster_whisper import decode_audio
    except Exception as e:
        print(f"whisper-probe: import failed: {type(e).__name__}: {e}")
        return 1
    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(b"\0\0" * 3200)
        samples = decode_audio(path)
    except Exception as e:
        print(f"whisper-probe: decode failed (faster-whisper={faster_whisper.__version__} "
              f"av={av.__version__}): {type(e).__name__}: {e}")
        return 1
    finally:
        os.unlink(path)
    if len(samples) == 0:
        print("whisper-probe: decode returned no samples")
        return 1
    print(f"whisper-probe: ok faster-whisper={faster_whisper.__version__} av={av.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
