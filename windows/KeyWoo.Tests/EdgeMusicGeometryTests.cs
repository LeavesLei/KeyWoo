using KeyWoo.Core;
using Xunit;

namespace KeyWoo.Tests;

public sealed class EdgeMusicGeometryTests {
    private static IReadOnlyList<EdgeMusicRegion> Regions(AudioSpectrum spectrum, double time = 0,
        double keyboard = 0, bool reducedMotion = false, double intensity = 1.5, double? keyboardEnergy = null) =>
        EdgeMusicGeometry.Regions(spectrum, time, intensity, keyboard, reducedMotion, keyboardEnergy);

    private static double Visibility(EdgeMusicRegion region) => region.BodyOpacity * region.RadiusX * region.BodyHeight
        + region.CrestOpacity * region.CrestRadiusX * region.CrestHeight;

    [Fact]
    public void MusicLivesOnTheSidesAndSilenceDrawsNothing() {
        Assert.Empty(Regions(AudioSpectrum.Silent));
        foreach (double time in new[] { 0.0, 2.5, 8, 50 }) {
            var regions = Regions(new AudioSpectrum(1, 1, 1, 1, 1), time);
            Assert.Equal(2, regions.Count);
            Assert.True(regions[0].CenterX + regions[0].RadiusX < 0.36);
            Assert.True(regions[1].CenterX - regions[1].RadiusX > 0.64);
            Assert.True(regions[0].CrestX + regions[0].CrestRadiusX < 0.36);
            Assert.True(regions[1].CrestX - regions[1].CrestRadiusX > 0.64);
            foreach (var region in regions) {
                Assert.All(new[] { region.BodyHeight, region.CrestHeight, region.RadiusX, region.Shoulder },
                    value => Assert.True(double.IsFinite(value) && value >= 0));
                Assert.InRange(region.BodyOpacity, 0, 1);
                Assert.InRange(region.CrestOpacity, 0, 1);
                Assert.True(1 - (1 - region.BodyOpacity) * (1 - region.CrestOpacity) < 0.85);
            }
        }
    }

    [Fact]
    public void BassAndTrebleReverseTheDominantSideWithoutMovingAnchors() {
        var bass = Regions(new AudioSpectrum(0.9, 0.15, 0.08, 0.8, 0.35));
        var treble = Regions(new AudioSpectrum(0.08, 0.15, 0.9, 0.8, 0.35));
        var middle = Regions(new AudioSpectrum(0.08, 0.9, 0.08, 0.8, 0.35));
        Assert.True(Visibility(bass[0]) > Visibility(bass[1]) * 1.25);
        Assert.True(Visibility(treble[1]) > Visibility(treble[0]) * 1.25);
        Assert.True(Visibility(middle[1]) > Visibility(middle[0]) * 1.25);
        for (int side = 0; side < 2; side++) {
            Assert.Equal(bass[side].CenterX, treble[side].CenterX);
            Assert.Equal(bass[side].CrestX, treble[side].CrestX);
        }
    }

    [Theory]
    [InlineData(80, 0)]
    [InlineData(8000, 1)]
    public void CapturedTonesProduceTheIntendedSideEmphasis(double frequency, int dominantSide) {
        var analyzer = new AudioSpectrumAnalyzer();
        var spectrum = AudioSpectrum.Silent;
        for (int block = 0; block < 200; block++) {
            var samples = Enumerable.Range(block * 512, 512)
                .Select(index => (float)(0.15 * Math.Sin(2 * Math.PI * frequency * index / 48_000))).ToArray();
            spectrum = analyzer.Process(samples, 48_000);
        }
        var regions = Regions(spectrum);
        Assert.Equal(2, regions.Count);
        Assert.True(Visibility(regions[dominantSide]) > Visibility(regions[1 - dominantSide]) * 1.1);
    }

    [Fact]
    public void QuietMusicAndTypingRemainSubtleWhileReducedMotionKeepsGeometryStill() {
        var spectrum = new AudioSpectrum(0.85, 0.65, 0.75, 0.85, 0.65);
        var strong = Regions(spectrum);
        var quiet = Regions(spectrum.Scaled(0.25));
        var typing = Regions(spectrum, keyboard: 1);
        var still = Regions(spectrum, reducedMotion: true);
        var laterStill = Regions(spectrum.Scaled(0.3), time: 10, reducedMotion: true);
        for (int side = 0; side < 2; side++) {
            Assert.True(Visibility(quiet[side]) > 0);
            Assert.True(Visibility(strong[side]) > Visibility(quiet[side]) * 3);
            Assert.True(Visibility(typing[side]) < Visibility(strong[side]));
            Assert.Equal(strong[side].CrestX, typing[side].CrestX);
            Assert.Equal(still[side].BodyHeight, laterStill[side].BodyHeight);
            Assert.Equal(still[side].CrestHeight, laterStill[side].CrestHeight);
            Assert.Equal(still[side].RadiusX, laterStill[side].RadiusX);
            Assert.Equal(still[side].Shoulder, laterStill[side].Shoulder);
        }
    }

    [Fact]
    public void SustainedTypingSoftensVerticalAccentsWithoutMovingTheSides() {
        var steady = new AudioSpectrum(0.8, 0.65, 0.6, 0.8);
        var accent = new AudioSpectrum(0.8, 0.65, 0.6, 0.8, 0.85);
        var baseline = Regions(steady, keyboardEnergy: 0);
        var baseTyping = Regions(steady, keyboardEnergy: 1);
        var solo = Regions(accent, keyboardEnergy: 0);
        var typing = Regions(accent, keyboardEnergy: 1);
        for (int side = 0; side < 2; side++) {
            Assert.Equal(baseline[side].BodyHeight, baseTyping[side].BodyHeight);
            double soloLift = solo[side].CrestHeight - baseline[side].CrestHeight;
            double typingLift = typing[side].CrestHeight - baseTyping[side].CrestHeight;
            Assert.InRange(typingLift, soloLift * 0.60, soloLift * 0.85);
            Assert.Equal(solo[side].CenterX, typing[side].CenterX);
            Assert.Equal(solo[side].CrestX, typing[side].CrestX);
            Assert.Equal(solo[side].RadiusX, typing[side].RadiusX);
            Assert.Equal(solo[side].Hue, typing[side].Hue);
        }
    }

    [Fact]
    public void LoudMusicStillReshapesOnTheBeatAndReleasesAtFixedAnchors() {
        foreach (double intensity in new[] { 1.0, 1.5 }) {
            var before = Regions(new AudioSpectrum(0.78, 0.78, 0.78, 0.78, 0.15), intensity: intensity);
            var peak = Regions(new AudioSpectrum(0.84, 0.84, 0.84, 0.84, 1), intensity: intensity);
            var released = Regions(new AudioSpectrum(0.84, 0.84, 0.84, 0.84, 0.15), intensity: intensity);
            for (int side = 0; side < 2; side++) {
                Assert.True(peak[side].CrestHeight - released[side].CrestHeight >= 6);
                Assert.True(released[side].CrestHeight > before[side].CrestHeight + 0.5);
                Assert.Equal(before[side].CrestX, peak[side].CrestX);
                Assert.Equal(peak[side].CrestX, released[side].CrestX);
            }
        }
    }

    [Fact]
    public void CaptureClockToDisplayClockKeepsSmallBeatsVisibleAndWaveMotionSmooth() {
        const double sampleRate = 48_000;
        const int blockSize = 512;
        const double warmup = 2;
        const double period = 0.5;
        const int beats = 8;
        var analyzer = new AudioSpectrumAnalyzer();
        var motion = new AudioSpectrumMotion();
        var target = AudioSpectrum.Silent;
        int nextSample = 0;
        var frames = new List<(double Time, AudioSpectrum Spectrum)>();
        double boost = Math.Pow(10, 3.0 / 20);
        for (int frame = 1; frame <= (warmup + beats * period) * 60; frame++) {
            double displayTime = frame / 60.0;
            while ((nextSample + blockSize) / sampleRate <= displayTime + 1e-12) {
                var samples = new float[blockSize];
                for (int index = 0; index < samples.Length; index++) {
                    double time = (nextSample + index) / sampleRate;
                    double musicTime = time - warmup;
                    double phase = musicTime % period;
                    double gain = 1;
                    if (musicTime >= 0 && musicTime < beats * period && phase < 0.09) {
                        double envelope = Math.Min(1, Math.Min(phase / 0.004, (0.09 - phase) / 0.010));
                        gain += (boost - 1) * envelope;
                    }
                    samples[index] = (float)(0.18 * gain * Math.Sin(2 * Math.PI * 80 * time)
                        + 0.075 * Math.Sin(2 * Math.PI * 1000 * time)
                        + 0.045 * Math.Sin(2 * Math.PI * 8000 * time));
                }
                target = analyzer.Process(samples, sampleRate);
                nextSample += blockSize;
            }
            var spectrum = motion.Advance(target, 1.0 / 60);
            if (displayTime >= warmup - 0.1) frames.Add((displayTime, spectrum));
        }
        foreach (double intensity in new[] { 1.0, 1.5 }) {
            var geometry = frames.Select(frame => Regions(frame.Spectrum, frame.Time, intensity: intensity)).ToArray();
            Assert.All(geometry, regions => Assert.Equal(2, regions.Count));
            for (int side = 0; side < 2; side++) {
                double[] heights = geometry.Select(regions => regions[side].CrestHeight).ToArray();
                double[] deltas = heights.Skip(1).Zip(heights, (later, earlier) => later - earlier).ToArray();
                Assert.All(deltas, delta => Assert.True(Math.Abs(delta) <= (intensity == 1 ? 3 : 4)));
                Assert.All(deltas.Skip(1).Zip(deltas, (later, earlier) => Math.Abs(later - earlier)),
                    acceleration => Assert.True(acceleration <= 1.5));
            }
        }
        var leftHeights = frames.Select(frame => (frame.Time, Height: Regions(frame.Spectrum, frame.Time, intensity: 1)[0].CrestHeight)).ToArray();
        for (int beat = 0; beat < beats; beat++) {
            double onset = warmup + beat * period;
            double baseline = leftHeights.Last(frame => frame.Time <= onset + 1e-10).Height;
            double peak = leftHeights.Where(frame => frame.Time > onset && frame.Time <= onset + 0.18).Max(frame => frame.Height);
            double tail = leftHeights.Where(frame => frame.Time >= onset + 0.38 && frame.Time <= onset + 0.48).Average(frame => frame.Height);
            double lift = peak - baseline;
            Assert.True(lift >= 6, $"Beat {beat} should visibly lift the shape. Actual lift {lift}.");
            Assert.True(tail <= peak - lift * 0.35, $"Beat {beat} should recover between accents.");
        }
    }
}
