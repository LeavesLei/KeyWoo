using System.Diagnostics;

namespace KeyWoo.Core;

/// <summary>Normalized visual energies. No audio samples are retained.</summary>
public readonly record struct AudioSpectrum {
    public double Low { get; }
    public double Mid { get; }
    public double High { get; }
    public double Level { get; }
    public double Beat { get; }
    public AudioContour? Contour { get; }
    public static readonly AudioSpectrum Silent = new(0, 0, 0, 0);
    public bool IsSilent => this == Silent;

    public AudioSpectrum(double low, double mid, double high, double level, double beat = 0,
        AudioContour? contour = null) {
        Low = Bounded(low);
        Mid = Bounded(mid);
        High = Bounded(high);
        Level = Bounded(level);
        Beat = Bounded(beat);
        Contour = contour;
    }

    public AudioSpectrum Scaled(double gain) => new(Low * gain, Mid * gain, High * gain, Level * gain,
        Beat * gain, Contour?.Scaled(gain));

    internal static double Bounded(double value) => double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0;
}

public readonly record struct AudioContour {
    public double Low { get; }
    public double Mid { get; }
    public double High { get; }
    public double Level { get; }
    public double Beat { get; }
    public static readonly AudioContour Silent = new(0, 0, 0, 0, 0);

    public AudioContour(double low, double mid, double high, double level, double beat) {
        Low = AudioSpectrum.Bounded(low);
        Mid = AudioSpectrum.Bounded(mid);
        High = AudioSpectrum.Bounded(high);
        Level = AudioSpectrum.Bounded(level);
        Beat = AudioSpectrum.Bounded(beat);
    }

    public AudioContour Scaled(double gain) => new(Low * gain, Mid * gain, High * gain, Level * gain, Beat * gain);
}

/// <summary>Continuous crossover energy history with separate onset and loudness scales.</summary>
public sealed class AudioSpectrumAnalyzer {
    private double dc, bass, body, lowPower, midPower, highPower, totalPower, rate, averageBass, averageLevel;
    private AudioSpectrum smoothed = AudioSpectrum.Silent;

    public AudioSpectrum Process(ReadOnlySpan<float> samples, double sampleRate) {
        if (!double.IsFinite(sampleRate) || sampleRate < 8_000 || samples.IsEmpty) return AudioSpectrum.Silent;
        if (rate != sampleRate) {
            Reset();
            rate = sampleRate;
        }
        double dcWeight = 1 - Math.Exp(-2 * Math.PI * 30 / sampleRate);
        double bassWeight = 1 - Math.Exp(-2 * Math.PI * 220 / sampleRate);
        double bodyWeight = 1 - Math.Exp(-2 * Math.PI * 2_200 / sampleRate);
        double lowPowerWeight = 1 - Math.Exp(-1 / (sampleRate * 0.018));
        double midPowerWeight = 1 - Math.Exp(-1 / (sampleRate * 0.010));
        double highPowerWeight = 1 - Math.Exp(-1 / (sampleRate * 0.006));
        double totalPowerWeight = 1 - Math.Exp(-1 / (sampleRate * 0.008));
        foreach (float sample in samples) {
            double input = float.IsFinite(sample) ? Math.Clamp((double)sample, -8, 8) : 0;
            dc += dcWeight * (input - dc);
            double signal = input - dc;
            bass += bassWeight * (signal - bass);
            body += bodyWeight * (signal - body);
            double middle = body - bass;
            double treble = signal - body;
            lowPower += lowPowerWeight * (bass * bass - lowPower);
            midPower += midPowerWeight * (middle * middle - midPower);
            highPower += highPowerWeight * (treble * treble - highPower);
            totalPower += totalPowerWeight * (signal * signal - totalPower);
        }
        double duration = samples.Length / sampleRate;
        double bassOnset = OnsetLevel(lowPower);
        double totalOnset = OnsetLevel(totalPower);
        double novelty = Math.Max(bassOnset - averageBass, (totalOnset - averageLevel) * 0.8);
        double beat = Math.Clamp((novelty - 0.025) * 8, 0, 1);
        double averageWeight = 1 - Math.Exp(-duration / 0.35);
        averageBass += averageWeight * (bassOnset - averageBass);
        averageLevel += averageWeight * (totalOnset - averageLevel);
        smoothed = new AudioSpectrum(
            Follow(smoothed.Low, LevelForPower(lowPower), duration),
            Follow(smoothed.Mid, LevelForPower(midPower), duration),
            Follow(smoothed.High, LevelForPower(highPower), duration),
            Follow(smoothed.Level, LevelForPower(totalPower), duration),
            Follow(smoothed.Beat, beat, duration, 0.005, 0.13));
        return smoothed;
    }

    public void Reset() {
        dc = bass = body = lowPower = midPower = highPower = totalPower = rate = averageBass = averageLevel = 0;
        smoothed = AudioSpectrum.Silent;
    }

    private static double LevelForPower(double power) {
        double db = 10 * Math.Log10(Math.Max(1e-12, power));
        double value;
        if (db <= -30.4) value = (db + 62) / 48;
        else if (db >= -26.4) value = 0.70 + (db + 28.4) * (0.30 / 28.4);
        else {
            double delta = db + 30.4;
            value = 31.6 / 48 + delta / 48 + (0.30 / 28.4 - 1.0 / 48) * delta * delta / 8;
        }
        return Math.Clamp(value, 0, 1);
    }

    private static double OnsetLevel(double power) => Math.Max(0, (10 * Math.Log10(Math.Max(1e-12, power)) + 62) / 48);

    internal static double Follow(double current, double target, double duration, double attack = 0.012,
        double release = 0.18) {
        double weight = 1 - Math.Exp(-duration / (target > current ? attack : release));
        double value = current + weight * (target - current);
        return value < 0.0005 ? 0 : value;
    }
}

/// <summary>Interpolate light quickly and keep the geometry on a calmer, bounded display-clock response.</summary>
public sealed class AudioSpectrumMotion {
    private readonly ContourChannel low = new(), mid = new(), high = new(), level = new(), beat = new();
    public AudioSpectrum Value { get; private set; } = AudioSpectrum.Silent;

    public AudioSpectrum Advance(AudioSpectrum target, double elapsed) {
        double duration = double.IsFinite(elapsed) ? Math.Clamp(elapsed, 0, 0.1) : 0;
        double shapeDuration = double.IsFinite(elapsed) ? Math.Clamp(elapsed, 0, 1.0 / 60) : 0;
        double perceptualBeat = Math.Pow(target.Beat, 0.70);
        double shapedBeat = perceptualBeat * (1.7 - 0.7 * perceptualBeat);
        var contour = new AudioContour(low.Advance(target.Low, shapeDuration), mid.Advance(target.Mid, shapeDuration),
            high.Advance(target.High, shapeDuration), level.Advance(target.Level, shapeDuration),
            beat.Advance(shapedBeat, shapeDuration, true));
        var next = new AudioSpectrum(
            AudioSpectrumAnalyzer.Follow(Value.Low, target.Low, duration, 0.008, 0.075),
            AudioSpectrumAnalyzer.Follow(Value.Mid, target.Mid, duration, 0.008, 0.075),
            AudioSpectrumAnalyzer.Follow(Value.High, target.High, duration, 0.008, 0.075),
            AudioSpectrumAnalyzer.Follow(Value.Level, target.Level, duration, 0.008, 0.075),
            AudioSpectrumAnalyzer.Follow(Value.Beat, target.Beat, duration, 0.004, 0.055));
        Value = next == AudioSpectrum.Silent && contour == AudioContour.Silent ? AudioSpectrum.Silent
            : new AudioSpectrum(next.Low, next.Mid, next.High, next.Level, next.Beat, contour);
        return Value;
    }

    public void Reset() {
        low.Reset(); mid.Reset(); high.Reset(); level.Reset(); beat.Reset();
        Value = AudioSpectrum.Silent;
    }

    private sealed class ContourChannel {
        private double position, velocity;

        public double Advance(double target, double duration, bool isBeat = false) {
            if (duration <= 0) return position;
            int steps = Math.Max(1, (int)Math.Ceiling(duration * 240));
            double step = duration / steps;
            double speedLimit = isBeat ? 4.3 : 1.8;
            double accelerationLimit = isBeat ? 48 : 18;
            for (int index = 0; index < steps; index++) {
                double response = target > position ? (isBeat ? 0.045 : 0.090) : (isBeat ? 0.100 : 0.200);
                double omega = 2 / response;
                double force = omega * omega * (target - position) - 2 * omega * velocity;
                double acceleration = Math.Clamp(force, -accelerationLimit, accelerationLimit);
                velocity = Math.Clamp(velocity + acceleration * step, -speedLimit, speedLimit);
                position += velocity * step;
                if (position < 0) { position = 0; velocity = Math.Max(0, velocity); }
                if (position > 1) { position = 1; velocity = Math.Min(0, velocity); }
            }
            if (target == 0 && position < 0.0005 && Math.Abs(velocity) < 0.003) position = velocity = 0;
            return position;
        }

        public void Reset() => position = velocity = 0;
    }
}

/// <summary>A bounded mailbox between capture callbacks and the display clock.</summary>
public sealed class AudioSpectrumProcessor {
    private readonly object gate = new();
    private readonly AudioSpectrumAnalyzer analyzer = new();
    private AudioSpectrum spectrum = AudioSpectrum.Silent;
    private double? lastUpdate;

    public static double MonotonicTime => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public void Receive(ReadOnlySpan<float> samples, double sampleRate, double? time = null) {
        lock (gate) {
            spectrum = analyzer.Process(samples, sampleRate);
            lastUpdate = time is { } explicitTime && double.IsFinite(explicitTime) ? explicitTime : MonotonicTime;
        }
    }

    public AudioSpectrum Snapshot(double? time = null) {
        lock (gate) {
            if (lastUpdate is not { } updated) return AudioSpectrum.Silent;
            double now = time is { } explicitTime && double.IsFinite(explicitTime) ? explicitTime : MonotonicTime;
            double gain = Math.Exp(-Math.Max(0, now - updated - 0.12) / 0.32);
            return gain < 0.0005 ? AudioSpectrum.Silent : spectrum.Scaled(gain);
        }
    }

    public void Reset() {
        lock (gate) {
            analyzer.Reset();
            spectrum = AudioSpectrum.Silent;
            lastUpdate = null;
        }
    }
}
