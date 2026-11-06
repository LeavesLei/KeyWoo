"""Restore individual recorded contacts while retaining the original PCM layout."""

from array import array
from io import BytesIO
import math
import sys
import wave


SAMPLE_RATE = 48_000
CHANNELS = 2
SAMPLE_WIDTH = 2
BLOCK_FRAMES = 96  # 2 ms, short enough to resolve a contact in a complete tap.


def block_rms(samples):
    stride = BLOCK_FRAMES * CHANNELS
    levels = []
    for start in range(0, len(samples), stride):
        block = samples[start:start + stride]
        levels.append(math.sqrt(sum(value * value for value in block) / len(block)))
    return levels


def pack_noise_floor(samples, ranges):
    quiet_levels = []
    for start, end in ranges:
        # Skip the start and the existing export fade. Quiet blocks may still
        # contain natural resonance, so treat this as an upper bound on noise.
        body = sorted(block_rms(samples[start:end])[1:-3])
        if body:
            quiet_levels.append(body[len(body) // 5])
    quiet_levels.sort()
    return quiet_levels[len(quiet_levels) // 3] if quiet_levels else 0.0


def tone(samples):
    """A gentle 33 Hz rumble cut and a broad 0.8 dB presence lift above 3.5 kHz."""
    rumble_alpha = -math.expm1(-2 * math.pi * 33 / SAMPLE_RATE)
    presence_alpha = -math.expm1(-2 * math.pi * 3_500 / SAMPLE_RATE)
    presence_gain = 10 ** (0.8 / 20) - 1
    result = array("d", [0]) * len(samples)
    for channel in range(CHANNELS):
        rumble = presence = 0.0
        for index in range(channel, len(samples), CHANNELS):
            source = samples[index]
            rumble += rumble_alpha * (source - rumble)
            clean = source - rumble
            presence += presence_alpha * (clean - presence)
            result[index] = clean + presence_gain * (clean - presence)
    return result


def restore_clip(samples, floor, is_foley):
    result = tone(samples)
    levels = block_rms(result)
    # Link the channels, bound the knee relative to each contact, and leave
    # distinct low-level resonances intact (particularly wood and tile foley).
    upper = min(2.8 * floor, 0.06 * max(levels), 100 if is_foley else 160)
    gains = []
    for index, _ in enumerate(levels):
        local = max(levels[max(0, index - 1):index + 2])
        t = 1 if upper <= 0 else max(0.0, min(1.0, (local / upper - 0.30) / 0.70))
        # Soft knee with a finite floor. Neighbouring blocks protect transients,
        # including a second contact inside an original unsplit sample.
        gains.append(0.32 + 0.68 * t * t * (3 - 2 * t))

    frames = len(samples) // CHANNELS
    fade = min(round(SAMPLE_RATE * 0.0025), frames // 8)
    for frame in range(frames):
        block, phase = divmod(frame, BLOCK_FRAMES)
        left, right = gains[block], gains[min(block + 1, len(gains) - 1)]
        gain = left + (right - left) * phase / BLOCK_FRAMES
        remaining = frames - 1 - frame
        if remaining < fade:
            gain *= (1 - math.cos(math.pi * remaining / fade)) / 2
        result[frame * CHANNELS] *= gain
        result[frame * CHANNELS + 1] *= gain
    result[0] = result[1] = result[-2] = result[-1] = 0
    return result


def restore_wav(source, pack):
    """Return a PCM16 sibling whose clip offsets and frame counts are identical."""
    with wave.open(BytesIO(source), "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getnframes()) != (
            SAMPLE_RATE, CHANNELS, SAMPLE_WIDTH, pack["frames"]
        ):
            raise ValueError("Unexpected recording WAV format or frame count")
        samples = array("h")
        samples.frombytes(audio.readframes(audio.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    if len(samples) != pack["frames"] * CHANNELS:
        raise ValueError("Truncated recording PCM")

    ranges = []
    frame = 0
    for clip in pack["clips"]:
        count = clip["frames"]
        if clip["startFrame"] != frame or type(count) is not int or not 0 < count <= SAMPLE_RATE:
            raise ValueError("Unexpected recording clip range")
        ranges.append((frame * CHANNELS, (frame + count) * CHANNELS))
        frame += count
    if not ranges or frame * CHANNELS != len(samples):
        raise ValueError("Recording clip layout does not match PCM")

    floor = pack_noise_floor(samples, ranges)
    restored = array("d")
    for start, end in ranges:
        restored.extend(restore_clip(samples[start:end], floor, pack.get("category") == "recordedFoley"))

    # Match the A/B level with one gain for the whole pack, preserving relative
    # strength of keys and return strokes. Reserve headroom for dense typing.
    original_energy = sum(value * value for value in samples)
    restored_energy = sum(value * value for value in restored)
    level_match = math.sqrt(original_energy / restored_energy) if restored_energy else 1.0
    # Stay below the playback bank's 0.32 PCM limit after quantization.
    gain = min(1.10, level_match, 0.319 * 32768 / max(1, max(map(abs, restored))))
    pcm = array("h", (round(value * gain) for value in restored))
    if sys.byteorder != "little":
        pcm.byteswap()
    output = BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setparams((CHANNELS, SAMPLE_WIDTH, SAMPLE_RATE, 0, "NONE", "not compressed"))
        audio.writeframes(pcm.tobytes())
    return output.getvalue()
