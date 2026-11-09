namespace KeyWoo.Core;

public enum EdgeMusicProfile { Bass, Detail }

public readonly record struct EdgeMusicRegion(double CenterX, double RadiusX, double BodyHeight,
    double BodyOpacity, double CrestX, double CrestRadiusX, double CrestHeight, double CrestOpacity,
    double Hue, EdgeMusicProfile Profile, double Shoulder);

/// <summary>Music shapes remain anchored at the sides and yield visual room to keyboard feedback.</summary>
public static class EdgeMusicGeometry {
    public static IReadOnlyList<EdgeMusicRegion> Regions(AudioSpectrum spectrum, double time, double intensity,
        double keyboardDrive, bool reducedMotion, double? keyboardEnergy = null) {
        double low = spectrum.Low, mid = spectrum.Mid, high = spectrum.High;
        double level = Math.Max(spectrum.Level, low * 0.55 + mid * 0.30 + high * 0.15);
        double beat = spectrum.Beat;
        var shape = spectrum.Contour ?? new AudioContour(low, mid, high, level, Math.Pow(beat, 0.70));
        double shapeLevel = Math.Max(shape.Level, shape.Low * 0.55 + shape.Mid * 0.30 + shape.High * 0.15);
        if (Math.Max(Math.Max(level, beat), Math.Max(shapeLevel, shape.Beat)) <= 0.001) return [];
        double gain = double.IsFinite(intensity) ? Math.Clamp(intensity, 0.4, 1.35) : 1;
        double engagement = AudioSpectrum.Bounded(keyboardEnergy ?? keyboardDrive);
        double room = 1 - engagement * 0.65;
        double typingComfort = 1 - engagement * 0.28;
        double transient = Math.Pow(beat, 0.70) * Math.Sqrt(level);
        var regions = new EdgeMusicRegion[2];
        for (int side = 0; side < 2; side++) {
            bool left = side == 0;
            double rawBand = Band(low, mid, high, left);
            double shapeBand = Band(shape.Low, shape.Mid, shape.High, left);
            double rawBody = Math.Pow(Math.Max(0, (rawBand - 0.025) / 0.975), 1.22);
            double body = Math.Pow(Math.Max(0, (shapeBand - 0.025) / 0.975), 1.22);
            double center = left ? 0.16 : 0.84;
            double radius = reducedMotion ? (left ? 0.12 : 0.10)
                : (left ? 0.105 + body * 0.048 : 0.090 + body * 0.037);
            double steadyLight = 0.26 * Math.Pow(rawBody, 0.72);
            double localBeat = transient * (0.22 + 0.78 * Math.Sqrt(rawBand));
            double shapeBeat = shape.Beat * Math.Sqrt(shapeLevel) * (0.22 + 0.78 * Math.Sqrt(shapeBand));
            double rawLift = (left ? 22 : 20) * shapeBeat * Math.Sqrt(gain);
            double excess = Math.Clamp(rawLift - 16, 0, 12);
            double softLift = rawLift <= 16 ? rawLift : 16 + excess - excess * excess / 24;
            double beatLift = reducedMotion ? 0 : softLift * typingComfort;
            double shoulder = reducedMotion ? (left ? 0.48 : 0.46)
                : (left ? 0.44 + shape.Mid * 0.12 : 0.28 + 0.38 * shape.Mid / (shape.Mid + shape.High + 0.10));
            regions[side] = new EdgeMusicRegion(center, radius,
                reducedMotion ? 24 : (left ? 14 + body * 42 : 12 + body * 36) + beatLift * 0.42,
                Math.Min(0.23, 0.22 * Math.Pow(rawBody, 0.80) * gain * room), center,
                reducedMotion ? (left ? 0.11 : 0.095) : (left ? 0.106 + body * 0.038 : 0.080 + body * 0.037),
                reducedMotion ? 19 : (left ? 10 + body * 48 : 12 + body * 43) * Math.Sqrt(gain) + beatLift,
                Math.Min(0.54, (steadyLight + localBeat * 0.26) * gain * room),
                left ? 0.51 + mid * 0.035 : 0.72 + high * 0.045,
                left ? EdgeMusicProfile.Bass : EdgeMusicProfile.Detail, shoulder);
        }
        return regions;
    }

    private static double Band(double low, double mid, double high, bool left) {
        double right = (low * 0.08 + mid * 0.48 + high * 0.68) / 1.24;
        return left ? low * 0.86 + mid * 0.12 + high * 0.02 : right * 1.20 / (1 + right * 0.20);
    }
}
