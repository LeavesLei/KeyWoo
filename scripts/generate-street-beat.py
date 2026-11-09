#!/usr/bin/env python3
"""Render KeyWoo's original Street Beat drum kit. Python 3.9+, stdlib only."""

from array import array
from hashlib import sha256
from io import BytesIO
import json
from math import exp, pi, sin, tanh
from random import Random
import sys
import wave

RATE = 48_000
TAU = 2 * pi
STREET_BEAT = "streetBeat"
KEYBOARD_SOUNDS = "Sources/KeyDance/Resources/KeyboardSounds"
MANIFEST_NAME = "street-beat-manifest.json"
VARIANTS = 3


def band_noise(random, low, high):
    """Band-limited exciter with a gentle 6 dB/octave slope on each edge."""
    low_mix = 1 - exp(-TAU * low / RATE)
    high_mix = 1 - exp(-TAU * high / RATE)
    lower = upper = 0.0
    while True:
        source = random.random() * 2 - 1
        lower += (source - lower) * low_mix
        upper += (source - upper) * high_mix
        yield upper - lower


def kick(times, random, pitch, decay):
    click = band_noise(random, 760, 5_200)
    for t in times:
        # Beater click over the pitch drop of a short, weighty bass drum.
        phase = TAU * pitch * (53 * t + 118 * 0.010 * (1 - exp(-t / 0.010)))
        body = (sin(phase) + 0.18 * sin(2 * phase)) * exp(-t / (0.050 * decay))
        transient = 0.38 * next(click) * exp(-t / 0.0026)
        yield tanh(1.15 * (body + transient)), 0.0


def snare(times, random, pitch, decay):
    shell = band_noise(random, 260, 4_200)
    wire = band_noise(random, 1_450, 9_400)
    for t in times:
        phase = TAU * pitch * (176 * t + 67 * 0.009 * (1 - exp(-t / 0.009)))
        head = (0.67 * sin(phase) + 0.31 * sin(1.51 * phase)) * exp(-t / (0.022 * decay))
        crack = next(shell) * exp(-t / (0.012 * decay))
        rattle = next(wire) * exp(-t / (0.031 * decay))
        yield tanh(0.85 * (head + 0.82 * crack + 1.08 * rattle)), 0.04 * rattle


def rim(times, random, pitch, decay):
    contact = band_noise(random, 1_100, 7_700)
    for t in times:
        phase = TAU * pitch * t
        stick = 1.35 * next(contact) * exp(-t / 0.003)
        shell = 0.53 * sin(phase * 689) * exp(-t / (0.014 * decay))
        edge = 0.29 * sin(phase * 1_814) * exp(-t / (0.006 * decay))
        yield stick + shell + edge, 0.0


def clap(times, random, pitch, decay):
    # Four offsets represent a small group of hands; the final burst has a
    # softer tail. A separate noise stream adds width without thinning the center.
    palms = band_noise(random, 640 * pitch, 5_900 * pitch)
    sides = band_noise(random, 920 * pitch, 5_900 * pitch)
    bursts = [(0, 0.004, 0.86), (0.009, 0.004, 0.96),
              (0.020, 0.006, 1.05), (0.032, 0.030, 0.78)]
    for t in times:
        envelope = 0.0
        for offset, length, level in bursts:
            age = t - offset * decay
            if age >= 0:
                envelope += level * min(1, age / 0.0004) * exp(-age / (length * decay))
        yield tanh(1.18 * next(palms) * envelope), 0.23 * next(sides) * envelope


def hat(times, random, pitch, decay, opened=False):
    wash = band_noise(random, 3_600 * pitch, 13_500 * pitch)
    sides = band_noise(random, 5_200 * pitch, 13_500 * pitch)
    # Inharmonic cymbal modes are mixed below the noise, with shorter modes
    # on the closed hat. This keeps letter keys light during fast typing.
    length = (0.042 if opened else 0.010) * decay
    for t in times:
        phase = TAU * pitch * t
        metallic = (0.095 * sin(phase * 3_717) + 0.068 * sin(phase * 5_409)
                    + 0.041 * sin(phase * 7_283) + 0.028 * sin(phase * 9_583))
        envelope = exp(-t / length)
        mid = (next(wash) * 0.88 + metallic * exp(-t / length)) * envelope
        yield mid, (0.24 if opened else 0.12) * next(sides) * envelope


def closed_hat(times, random, pitch, decay):
    return hat(times, random, pitch, decay)


def open_hat(times, random, pitch, decay):
    return hat(times, random, pitch, decay, opened=True)


# Durations and peak levels express the intended balance within the kit. The
# application applies its existing single loudness gain to the entire pack.
DRUMS = {
    "closed-hat": (closed_hat, 0.061, 0.075),
    "kick": (kick, 0.222, 0.265),
    "snare": (snare, 0.161, 0.185),
    "rim": (rim, 0.092, 0.103),
    "open-hat": (open_hat, 0.186, 0.105),
    "clap": (clap, 0.175, 0.147),
}
SPECIAL_KEYS = {49: "kick", 36: "snare", 76: "snare", 51: "rim", 117: "rim",
                48: "open-hat", 56: "clap", 60: "clap"}


def drum_clip(role, variant):
    synth, duration, peak = DRUMS[role]
    count = round(duration * RATE)
    pitch = (0.981, 1.0, 1.019)[variant]
    decay = (0.93, 1.0, 1.07)[variant]
    random = Random(36041 + list(DRUMS).index(role) * 17 + variant)
    attack = round(0.00035 * RATE)
    release = round(0.012 * RATE)
    stereo = []
    times = (frame / RATE for frame in range(count))
    for frame, (mid, side) in enumerate(synth(times, random, pitch, decay)):
        edge = min(1.0, frame / attack, (count - 1 - frame) / release)
        # Raised cosine tapers are continuous in value and slope.
        fade = sin(edge * pi / 2) ** 2
        stereo.extend(((mid + side) * fade, (mid - side) * fade))
    gain = peak * (0.96, 1.0, 0.98)[variant] / max(map(abs, stereo))
    return [sample * gain for sample in stereo]


def wave_bytes(samples):
    pcm = array("h", (round(sample * 32767) for sample in samples))
    if sys.byteorder != "little":
        pcm.byteswap()
    buffer = BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(pcm.tobytes())
    return buffer.getvalue()


def generate_assets():
    clips, samples, pairs = [], [], {}
    for role in DRUMS:
        down = []
        for variant in range(VARIANTS):
            pcm = drum_clip(role, variant)
            down.append(len(clips))
            clips.append({"startFrame": len(samples) // 2, "frames": len(pcm) // 2,
                          "origin": "original-procedural-drum", "edge": "down",
                          "role": role, "variant": variant})
            samples.extend(pcm)
        pairs[role] = {"down": down, "up": []}
    keys = {str(code): pairs[SPECIAL_KEYS.get(code, "closed-hat")] for code in range(128)}
    wave_data = wave_bytes(samples)
    wave_path = STREET_BEAT + "/samples.wav"
    pack = {"title": "Street Beat", "titleZh": "街舞节拍", "file": wave_path,
            "sha256": sha256(wave_data).hexdigest(), "sampleRate": RATE, "channels": 2,
            "frames": len(samples) // 2, "clips": clips, "keys": keys,
            "fallback": pairs["closed-hat"], "recorded": False, "author": "KeyWoo",
            "license": "Original KeyWoo generated audio; distributed with the application"}
    manifest = {"schema": 1, "sampleRate": RATE, "packs": {STREET_BEAT: pack},
                "source": "generate-street-beat.py original drum synthesis"}
    return {
        f"{KEYBOARD_SOUNDS}/{wave_path}": wave_data,
        f"{KEYBOARD_SOUNDS}/{MANIFEST_NAME}":
            (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    }
