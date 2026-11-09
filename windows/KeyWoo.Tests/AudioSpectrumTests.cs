using KeyWoo.Core;
using Xunit;

namespace KeyWoo.Tests;

public sealed class AudioSpectrumTests {
    private static float[] Tone(double frequency, int offset, int count = 512, double gain = 0.15,
        double sampleRate = 48_000) => Enumerable.Range(offset, count)
        .Select(index => (float)(gain * Math.Sin(2 * Math.PI * frequency * index / sampleRate))).ToArray();

    private static double[] Values(AudioSpectrum spectrum) =>
        [spectrum.Low, spectrum.Mid, spectrum.High, spectrum.Level, spectrum.Beat];

    [Theory]
    [InlineData(80, 0)]
    [InlineData(1000, 1)]
    [InlineData(8000, 2)]
    public void ContinuousTonesFavorTheirFrequencyBand(double frequency, int dominantBand) {
        var analyzer = new AudioSpectrumAnalyzer();
        AudioSpectrum result = AudioSpectrum.Silent;
        for (int block = 0; block < 200; block++) result = analyzer.Process(Tone(frequency, block * 512), 48_000);
        Assert.All(Values(result), value => Assert.InRange(value, 0, 1));
        Assert.True(result.Level > 0.75);
        double[] bands = [result.Low, result.Mid, result.High];
        for (int band = 0; band < bands.Length; band++) {
            if (band != dominantBand) Assert.True(bands[dominantBand] > bands[band] + 0.05);
        }
    }

    [Fact]
    public void SilenceAndInvalidSamplesReleaseWithoutPoisoningLaterState() {
        var analyzer = new AudioSpectrumAnalyzer();
        var silence = new float[512];
        Assert.Equal(AudioSpectrum.Silent, analyzer.Process(silence, 48_000));
        AudioSpectrum active = AudioSpectrum.Silent;
        for (int block = 0; block < 100; block++) active = analyzer.Process(Tone(1000, block * 512), 48_000);
        AudioSpectrum tail = AudioSpectrum.Silent;
        for (int block = 0; block < 20; block++) tail = analyzer.Process(silence, 48_000);
        Assert.InRange(tail.Level, double.Epsilon, active.Level - double.Epsilon);
        float[] invalid = [float.NaN, float.PositiveInfinity, float.NegativeInfinity, float.MaxValue, -float.MaxValue];
        Assert.All(Values(analyzer.Process(invalid, 48_000)), value => Assert.InRange(value, 0, 1));
        for (int block = 0; block < 500; block++) tail = analyzer.Process(silence, 48_000);
        Assert.Equal(AudioSpectrum.Silent, tail);
        Assert.Equal(AudioSpectrum.Silent, analyzer.Process(silence, double.NaN));
        Assert.Equal(AudioSpectrum.Silent, analyzer.Process([], 48_000));
    }

    [Fact]
    public void SampleRateChangeResetsTheCrossoverAndEnvelope() {
        var analyzer = new AudioSpectrumAnalyzer();
        for (int block = 0; block < 100; block++) analyzer.Process(Tone(80, block * 512), 48_000);
        Assert.Equal(AudioSpectrum.Silent, analyzer.Process(new float[441], 44_100));
        var fresh = new AudioSpectrumAnalyzer();
        for (int block = 0; block < 30; block++) {
            var samples = Tone(1000, block * 441, 441, sampleRate: 44_100);
            Assert.Equal(fresh.Process(samples, 44_100), analyzer.Process(samples, 44_100));
        }
    }

    [Theory]
    [InlineData(40)]
    [InlineData(80)]
    [InlineData(1000)]
    public void SmallCaptureBlocksDoNotCreateFalseBeatsButPreserveTheFirstOnset(double frequency) {
        var analyzer = new AudioSpectrumAnalyzer();
        double settledBeat = 0;
        for (int block = 0; block < 320; block++) {
            var result = analyzer.Process(Tone(frequency, block * 512, gain: 0.03), 48_000);
            if (block > 280) settledBeat = Math.Max(settledBeat, result.Beat);
        }
        Assert.True(settledBeat < 0.08);
        var onset = analyzer.Process(Tone(frequency, 320 * 512), 48_000);
        Assert.True(onset.Beat > 0.45);
        var motion = new AudioSpectrumMotion();
        Assert.True(motion.Advance(onset, 1.0 / 60).Beat > 0.4);
    }

    [Theory]
    [InlineData(80)]
    [InlineData(1000)]
    public void LoudMusicRetainsHeadroomForAnotherKick(double frequency) {
        var analyzer = new AudioSpectrumAnalyzer();
        int offset = 0;
        AudioSpectrum Block(double gain) {
            var result = analyzer.Process(Tone(frequency, offset, gain: gain), 48_000);
            offset += 512;
            return result;
        }
        AudioSpectrum before = AudioSpectrum.Silent;
        for (int index = 0; index < 320; index++) before = Block(0.4);
        Assert.True(before.Level < 0.95 && before.Beat < 0.08);
        double onset = 0;
        for (int index = 0; index < 4; index++) onset = Math.Max(onset, Block(0.8).Beat);
        Assert.True(onset > 0.35);
        AudioSpectrum after = AudioSpectrum.Silent;
        for (int index = 0; index < 160; index++) after = Block(0.8);
        Assert.InRange(after.Level, before.Level + 0.04, 1 - double.Epsilon);
        Assert.True(after.Beat < 0.08);
    }

    [Fact]
    public void MailboxFadesWhenCallbacksStopAndSnapshotsDoNotAccumulateDecay() {
        var processor = new AudioSpectrumProcessor();
        Assert.Equal(AudioSpectrum.Silent, processor.Snapshot(10));
        for (int block = 0; block < 100; block++) processor.Receive(Tone(1000, block * 512), 48_000, 10);
        var active = processor.Snapshot(10);
        var fading = processor.Snapshot(10.6);
        Assert.True(active.Level > 0.75);
        Assert.InRange(fading.Level, double.Epsilon, active.Level * 0.3);
        Assert.Equal(fading, processor.Snapshot(10.6));
        Assert.Equal(AudioSpectrum.Silent, processor.Snapshot(13));
        processor.Reset();
        Assert.Equal(AudioSpectrum.Silent, processor.Snapshot(10));
    }

    [Fact]
    public void LightRespondsQuicklyWhileContourMovesCalmlyAndBothSettle() {
        var motion = new AudioSpectrumMotion();
        var target = new AudioSpectrum(0.8, 0.6, 0.4, 0.9, 1);
        var first = motion.Advance(target, 1.0 / 60);
        Assert.True(first.Beat > 0.95);
        Assert.True(first.Contour!.Value.Beat < 0.1 && first.Contour.Value.Low < first.Low * 0.25);
        for (int frame = 0; frame < 60; frame++) motion.Advance(target, 1.0 / 60);
        Assert.True(motion.Value.Contour!.Value.Low > target.Low * 0.9 && motion.Value.Contour.Value.Beat > 0.9);
        var previous = motion.Value;
        Assert.Equal(previous, motion.Advance(AudioSpectrum.Silent, double.NaN));
        for (int frame = 0; frame < 180; frame++) motion.Advance(AudioSpectrum.Silent, 1.0 / 60);
        Assert.Equal(AudioSpectrum.Silent, motion.Value);
        motion.Advance(target, 1.0 / 60);
        motion.Reset();
        Assert.Equal(AudioSpectrum.Silent, motion.Value);
    }

    [Theory]
    [InlineData(0.1)]
    [InlineData(0.3)]
    [InlineData(2)]
    public void StalledDisplayResumesWithOneGentleGeometryStep(double elapsed) {
        var motion = new AudioSpectrumMotion();
        var result = motion.Advance(new AudioSpectrum(1, 1, 1, 1, 1), elapsed);
        var shape = result.Contour!.Value;
        Assert.All(new[] { shape.Low, shape.Mid, shape.High, shape.Level, shape.Beat }, value => Assert.InRange(value, 0, 0.05));
        Assert.True(result.Beat > 0.95);
    }
}
