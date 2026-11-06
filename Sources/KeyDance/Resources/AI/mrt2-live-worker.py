#!/usr/bin/env python3
"""Local MRT2 small worker; stdout is JSON headers followed by Float32 stereo PCM.

No audio device, network request, user text, persistent input log, or file import.
MAGENTA_HOME / --assets-root is the parent of the magenta-rt-v2 model directory.
"""
import argparse
import ctypes
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import select
import time
import traceback


class MacProcessActivity:
    """Own a public NSProcessInfo token without blocking display/system sleep."""
    OPTIONS = 0x00FFFFFF & ~(1 << 20)

    def __init__(self):
        self.foundation = ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
        self.objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
        self.objc.objc_getClass.argtypes = [ctypes.c_char_p]
        self.objc.objc_getClass.restype = ctypes.c_void_p
        self.objc.sel_registerName.argtypes = [ctypes.c_char_p]
        self.objc.sel_registerName.restype = ctypes.c_void_p
        self._address = ctypes.cast(self.objc.objc_msgSend, ctypes.c_void_p).value
        self._id = self._typed(ctypes.c_void_p)
        self._void_id = self._typed(None, ctypes.c_void_p)
        self._void = self._typed(None)
        self._string = self._typed(ctypes.c_void_p, ctypes.c_char_p)
        self._begin = self._typed(ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p)
        self._integer = self._typed(ctypes.c_long)
        self._boolean = self._typed(ctypes.c_bool)
        self.info = self._id(self._class('NSProcessInfo'), self._sel('processInfo'))
        if not self.info:
            raise RuntimeError('Foundation returned no process information object.')
        self.token = None

    def _typed(self, result, *arguments):
        return ctypes.CFUNCTYPE(result, ctypes.c_void_p, ctypes.c_void_p, *arguments)(self._address)

    def _class(self, name):
        return self.objc.objc_getClass(name.encode('ascii'))

    def _sel(self, name):
        return self.objc.sel_registerName(name.encode('ascii'))

    def begin(self):
        if self.token:
            return
        pool = self._id(self._id(self._class('NSAutoreleasePool'), self._sel('alloc')), self._sel('init'))
        reason = None
        try:
            reason = self._string(self._id(self._class('NSString'), self._sel('alloc')), self._sel('initWithUTF8String:'), b'KeyWoo local music generation requested by the user')
            token = self._begin(self.info, self._sel('beginActivityWithOptions:reason:'), self.OPTIONS, reason)
            if not token:
                raise RuntimeError('Foundation returned no activity token.')
            self.token = self._id(token, self._sel('retain'))
        finally:
            if reason:
                self._void(reason, self._sel('release'))
            if pool:
                self._void(pool, self._sel('drain'))

    def end(self):
        if self.token:
            token, self.token = self.token, None
            self._void_id(self.info, self._sel('endActivity:'), token)
            self._void(token, self._sel('release'))

    def snapshot(self):
        return {'activity_active': bool(self.token),
                'thermal_state': self._integer(self.info, self._sel('thermalState')),
                'low_power_mode': bool(self._boolean(self.info, self._sel('isLowPowerModeEnabled')))}


def main():
    # Preserve a dedicated protocol descriptor; redirect even native printf logs
    # away from stdout before importing any ML/native dependencies.
    transport = os.fdopen(os.dup(sys.stdout.fileno()), 'wb', buffering=0)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr

    def send_bytes(data):
        remaining = memoryview(data)
        while remaining:
            written = transport.write(remaining)
            if not written:
                raise BrokenPipeError('Protocol reader closed.')
            remaining = remaining[written:]

    def emit(value):
        send_bytes((json.dumps(value, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8'))

    activity = None
    telemetry = None
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--assets-root', default=os.environ.get('MAGENTA_HOME'))
        parser.add_argument('--style-tokens', default=str(Path(__file__).with_name('style-tokens.json')))
        args = parser.parse_args()
        if not args.assets_root:
            raise ValueError('Local model directory is not configured.')
        assets = Path(args.assets_root).expanduser().resolve()
        files = [
            'models/mrt2_small/mrt2_small.mlxfn',
            'models/mrt2_small/mrt2_small_state.safetensors',
        ]
        if not all((assets / 'magenta-rt-v2' / file).is_file() for file in files):
            raise ValueError('Local MRT2 small model files are incomplete.')
        cache = json.loads(Path(args.style_tokens).read_text())
        styles = cache.get('tokens')
        if cache.get('version') != 1 or cache.get('model') != 'mrt2_small' or not isinstance(styles, list) or len(styles) != 2 or any(not isinstance(style, list) or len(style) != 12 or any(type(token) is not int or not 0 <= token < 1024 for token in style) for style in styles):
            raise ValueError('The bundled musical style tokens are invalid.')
        version = importlib.metadata.version('mlx')
        if version != '0.31.2':
            raise RuntimeError('This exported model requires the matching MLX 0.31.2 runtime; found ' + version)
        os.environ['MAGENTA_HOME'] = str(assets)
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
        started = time.perf_counter()
        # Activity belongs to this Python process, not its Swift parent. The
        # public Foundation option leaves system and display idle sleep allowed.
        activity = MacProcessActivity()
        activity.begin()
        telemetry_path = os.environ.get('KEYWOO_MRT_QA_TELEMETRY')
        if telemetry_path:
            telemetry = open(telemetry_path, 'w', encoding='utf-8', buffering=1)
        import numpy as np
        from magenta_rt import MagentaRT2StdMlxfn
        from magenta_rt.config import MUSICCOCA, PIANOROLL_WITH_ONSETS

        class CachedStyleOnly:
            # Public style_model injection keeps the exported function's built-in
            # codec but avoids loading the large, unneeded style-encoder weights.
            # The worker always supplies the validated cached token lists above.
            def embed(self, *args, **kwargs):
                raise RuntimeError('Runtime style encoding is disabled; use bundled tokens.')
            def tokenize(self, *args, **kwargs):
                raise RuntimeError('Runtime style tokenization is disabled; use bundled tokens.')

        model = MagentaRT2StdMlxfn(size='mrt2_small', style_model=CachedStyleOnly(), warmup_steps=5)
        # Warm the actual conditioned decode path before announcing readiness.
        # Its first call can exceed the small live ring buffer's time capacity.
        # Discarding the state keeps the user's session logically fresh.
        model.generate(conditioning={MUSICCOCA.key: styles[0], PIANOROLL_WITH_ONSETS.key: [-1] * 128}, frames=1, state=None)
        state = None
        sequence = 0

        def record_telemetry(generation_ms=None):
            if telemetry is None:
                return
            import resource
            import mlx.core as mx
            row = {'elapsed_seconds': time.perf_counter() - started,
                   'sequence': sequence, 'generation_ms': generation_ms,
                   'mlx_active_bytes': mx.get_active_memory(),
                   'mlx_cache_bytes': mx.get_cache_memory(),
                   'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                   **activity.snapshot()}
            telemetry.write(json.dumps(row, separators=(',', ':'), allow_nan=False) + '\n')

        record_telemetry()
        emit({'ready': True, 'model': 'mrt2_small', 'frames': 1920, 'rate': 48000, 'channels': 2, 'format': 'float32le', 'style_count': 2, 'startup_seconds': time.perf_counter() - started})
        while True:
            # The protocol has at most one request in flight, so no second line
            # can be hidden in BufferedReader while select waits on the fd.
            # A paused/stopped Swift consumer sends no steps: release this local
            # activity after one second, and reacquire before resumed work.
            if not select.select([sys.stdin.fileno()], [], [], 1.0)[0]:
                activity.end()
                continue
            line = sys.stdin.buffer.readline(16_385)
            if not line:
                return
            if len(line) > 16_384:
                raise ValueError('Control message exceeds the bounded protocol size.')
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError('Control message must be an object.')
            command = request.get('cmd', 'step')
            if command == 'quit':
                return
            if command != 'step':
                raise ValueError('Unsupported command.')
            notes = request.get('notes', [-1] * 128)
            if not isinstance(notes, list) or len(notes) != 128 or any(type(n) is not int or n < -1 or n > 3 for n in notes):
                raise ValueError('notes must contain exactly 128 integers from -1 through 3.')
            style = request.get('style', 0)
            if type(style) is not int or style not in (0, 1):
                raise ValueError('style must be 0 or 1.')
            reset = request.get('reset', False)
            if type(reset) is not bool:
                raise ValueError('reset must be a boolean.')
            if reset:
                state = None
            activity.begin()
            tick = time.perf_counter()
            waveform, state = model.generate(conditioning={MUSICCOCA.key: styles[style], PIANOROLL_WITH_ONSETS.key: notes}, frames=1, state=state)
            samples = np.asarray(waveform.samples, dtype='<f4', order='C')
            if waveform.sample_rate != 48_000 or samples.shape != (1920, 2) or not np.isfinite(samples).all():
                raise RuntimeError('Model returned an invalid audio frame.')
            payload = samples.tobytes(order='C')
            generation_ms = (time.perf_counter() - tick) * 1000
            emit({'frames': 1920, 'bytes': len(payload), 'rate': 48000, 'sequence': sequence, 'generation_ms': generation_ms})
            send_bytes(payload)
            sequence += 1
            if sequence % 25 == 0:
                record_telemetry(generation_ms)
    except BrokenPipeError:
        return
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        try:
            emit({'error': str(error)})
        except BrokenPipeError:
            pass
        sys.exit(1)
    finally:
        if activity is not None:
            activity.end()
        if telemetry is not None:
            telemetry.close()
        transport.close()


if __name__ == '__main__':
    main()
