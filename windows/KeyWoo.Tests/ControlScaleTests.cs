using KeyWoo.Core;
using Xunit;

namespace KeyWoo.Tests;

public sealed class ControlScaleTests {
    [Fact]
    public void WholeVolumeRangeIsLinearAndRecommendedGainIsPreserved() {
        var scale = ControlScale.KeyboardVolume;
        Assert.Equal(0, scale.DisplayValue(0));
        Assert.Equal(0.5, scale.DisplayValue(8));
        Assert.Equal(1, scale.DisplayValue(16));
        Assert.Equal(0.0625, scale.DisplayValue(1));
        Assert.Equal(1, scale.StoredValue(0.0625));
        Assert.Equal(8, scale.StoredValue(0.5));
    }

    [Fact]
    public void OldIntensityValuesMapToTheNewDisplayRange() {
        var scale = ControlScale.RhythmIntensity;
        Assert.Equal(0.25, scale.DisplayValue(0.4));
        Assert.Equal(1, scale.DisplayValue(1.5));
        Assert.Equal(0.625, scale.DisplayValue(0.95), 12);
        Assert.Equal(0.95, scale.StoredValue(0.625), 12);
        Assert.Equal(0.4, scale.StoredValue(0.25));
    }

    [Fact]
    public void ExistingSettingsRoundTripWithoutQuantization() {
        foreach (double value in new[] { 0, 0.5, 1, 1.6, 3.75, 4, 8, 12.34567, 16 })
            Assert.Equal(value, ControlScale.KeyboardVolume.StoredValue(ControlScale.KeyboardVolume.DisplayValue(value)), 12);
        foreach (double value in new[] { 0.4, 0.55, 0.83, 0.95, 1, 1.234567, 1.5 })
            Assert.Equal(value, ControlScale.RhythmIntensity.StoredValue(ControlScale.RhythmIntensity.DisplayValue(value)), 12);
    }

    [Fact]
    public void PercentStepsAreUniformAndInvalidValuesStayBounded() {
        var volume = ControlScale.KeyboardVolume;
        for (int percent = 0; percent < 100; percent++)
            Assert.Equal(0.16, volume.StoredValue((percent + 1) / 100.0) - volume.StoredValue(percent / 100.0), 12);
        var intensity = ControlScale.RhythmIntensity;
        for (int percent = 25; percent < 100; percent++)
            Assert.Equal(1.1 / 75, intensity.StoredValue((percent + 1) / 100.0) - intensity.StoredValue(percent / 100.0), 12);
        Assert.Equal(0, volume.DisplayValue(double.NaN));
        Assert.Equal(1, volume.DisplayValue(double.PositiveInfinity));
        Assert.Equal(0, volume.StoredValue(-1));
        Assert.Equal(1.5, intensity.StoredValue(2));
    }
}
