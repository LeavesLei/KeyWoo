#!/usr/bin/env python3
"""Public metadata first; explicit --execute installs the tested small runtime.
No account, API key, audio device, or user content is used. Run from any directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build' / 'mrt2-setup-reports'
BASE = ROOT / '.build' / 'mrt2-assets'
REPO = 'google/magenta-realtime-2'
LIMIT = 3_000_000_000
MODEL_REVISION = '010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc'

def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true', help='Explicitly install dependencies and download the preflighted public small bundle.')
    parser.add_argument('--python', default='/opt/homebrew/bin/python3.11')
    args = parser.parse_args()
    package = fetch('https://pypi.org/pypi/magenta-rt/2.0.3/json')
    metadata = fetch('https://huggingface.co/api/models/' + REPO)
    if metadata.get('gated') not in (None, False):
        raise RuntimeError('Model access requires an account or acceptance; stopped without requesting access.')
    revision = MODEL_REVISION
    entries = fetch('https://huggingface.co/api/models/' + REPO + '/tree/' + revision + '?recursive=true&expand=false&limit=1000')
    def wanted(path):
        return path in {'models/mrt2_small/mrt2_small.mlxfn', 'models/mrt2_small/mrt2_small_state.safetensors'}
    files = [entry for entry in entries if entry['type'] == 'file' and wanted(entry['path'])]
    if len(files) != 2:
        raise RuntimeError('Required small-model files absent from metadata; stopped.')
    total = sum(x['size'] for x in files)
    if total > LIMIT:
        raise RuntimeError('Model+resources exceed 3GB: ' + str(total))
    version = package['info']['version']
    if not version.startswith('2.'):
        raise RuntimeError('Unexpected package major version; review current API before installation: ' + version)
    style_cache = ROOT / 'Sources/KeyDance/Resources/AI/style-tokens.json'
    if not style_cache.is_file():
        raise RuntimeError('Bundled style-tokens.json is required for the small runtime.')
    plan = {'status': 'preflight', 'date_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'package': 'magenta-rt[mlx]==' + version, 'runtime_pins': ['mlx==0.31.2', 'mlx-metal==0.31.2'], 'model_repository': REPO, 'revision': revision, 'gated': metadata.get('gated'), 'model_license': metadata.get('cardData', {}).get('license'), 'layout': 'exported', 'includes_style_encoder': False, 'runtime_smoke_verified': False, 'app_activation_changed': False, 'bundled_style_tokens_sha256': sha256(style_cache) if style_cache.exists() else None, 'total_model_resource_bytes': total, 'byte_limit': LIMIT, 'files': files, 'model_root': str(BASE / 'magenta-rt-v2'), 'inference_run': False}
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = OUT / 'mrt2-setup-manifest.json'
    manifest.write_text(json.dumps(plan, indent=2) + '\n')
    print(json.dumps({k:v for k,v in plan.items() if k != 'files'}, indent=2), flush=True)
    if not args.execute:
        print('Preflight only. Nothing installed or downloaded. Add --execute to perform this plan.', flush=True)
        return
    env = os.environ.copy()
    env.update(UV_CACHE_DIR=str(ROOT / '.build' / 'mrt2-uv-cache'), MAGENTA_HOME=str(BASE), HF_HUB_DISABLE_IMPLICIT_TOKEN='1')
    venv = ROOT / '.build' / 'mrt2-venv'
    if not (venv / 'bin' / 'python').exists():
        subprocess.run(['uv', 'venv', '--python', args.python, '--no-python-downloads', str(venv)], check=True, env=env)
    subprocess.run(['uv', 'pip', 'install', '--python', str(venv / 'bin' / 'python'), plan['package']] + plan['runtime_pins'], check=True, env=env)
    for entry in files:
        relative = Path(entry['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Unsafe model path in metadata')
        path = BASE / 'magenta-rt-v2' / relative
        expected = entry.get('lfs', {}).get('oid')
        if path.exists() and path.stat().st_size == entry['size'] and (not expected or sha256(path) == expected):
            print('Verified existing ' + str(relative), flush=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + '.download')
        print('Downloading ' + str(relative) + ': ' + str(entry['size']) + ' bytes', flush=True)
        downloaded = 0
        with urllib.request.urlopen('https://huggingface.co/' + REPO + '/resolve/' + revision + '/' + entry['path'], timeout=120) as response, temp.open('wb') as target:
            while True:
                chunk = response.read(8 * 1024 * 1024)
                if not chunk:
                    break
                downloaded += len(chunk)
                if downloaded > entry['size']:
                    raise RuntimeError('Download larger than preflight metadata; stopped')
                target.write(chunk)
        if downloaded != entry['size'] or (expected and sha256(temp) != expected):
            raise RuntimeError('Model file size/hash mismatch: ' + str(relative))
        temp.replace(path)
    plan['status'] = 'installed_not_smoke_tested_or_enabled'
    manifest.write_text(json.dumps(plan, indent=2) + '\n')
    print('Dependencies and weights installed. Runtime has not been smoke-tested or enabled. No app settings, readiness marker, or audio playback were changed.', flush=True)

if __name__ == '__main__':
    main()
