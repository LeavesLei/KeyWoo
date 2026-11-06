#!/usr/bin/env python3
"""Verify the local worker without opening an audio device, then enable discovery."""
import json
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    python = ROOT / '.build/mrt2-venv/bin/python'
    worker = ROOT / 'Sources/KeyDance/Resources/AI/mrt2-live-worker.py'
    assets = ROOT / '.build/mrt2-assets'
    report_dir = ROOT / '.build/mrt2-setup-reports'
    report_dir.mkdir(parents=True, exist_ok=True)
    with (report_dir / 'verify-stderr.log').open('wb') as log:
        process = subprocess.Popen([str(python), str(worker), '--assets-root', str(assets)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        watchdog = threading.Timer(120, lambda: process.kill() if process.poll() is None else None)
        watchdog.daemon = True
        watchdog.start()
        started = time.monotonic()
        try:
            header = json.loads(process.stdout.readline(16385))
            if not header.get('ready'):
                raise RuntimeError(header.get('error', 'Local model did not become ready.'))
            for _ in range(3):
                process.stdin.write(b'{"cmd":"step","style":0}\n')
                process.stdin.flush()
                header = json.loads(process.stdout.readline(16385))
                if header.get('bytes') != 15360 or header.get('rate') != 48000:
                    raise RuntimeError(header.get('error', 'Invalid audio frame.'))
                remaining = 15360
                while remaining:
                    chunk = process.stdout.read(remaining)
                    if not chunk:
                        raise RuntimeError('Incomplete audio frame.')
                    remaining -= len(chunk)
            process.stdin.write(b'{"cmd":"quit"}\n')
            process.stdin.flush()
            process.wait(timeout=5)
            if process.returncode:
                raise RuntimeError('Worker did not exit normally.')
            result = dict(model='mrt2_small', magenta_rt='2.0.3', mlx='0.31.2',
                          cached_style_only=True, worker_protocol_verified=True,
                          audio_device_tested=False, elapsed_seconds=time.monotonic() - started)
            (assets / 'verified-runtime.json').write_text(json.dumps(result, indent=2) + '\n')
            print('Local AI worker verified. Reopen KeyWoo to see the AI music option.')
        finally:
            watchdog.cancel()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


if __name__ == '__main__':
    main()
