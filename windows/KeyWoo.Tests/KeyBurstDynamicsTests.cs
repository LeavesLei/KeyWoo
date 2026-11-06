using KeyWoo.Core;
using Xunit;

namespace KeyWoo.Tests;

public sealed class KeyBurstDynamicsTests {
    private static readonly PhysicalKey A = new(0x41, 0x1E);
    private static readonly PhysicalKey B = new(0x42, 0x30);
    private static readonly PhysicalKey Space = new(0x20, 0x39);
    private static readonly PhysicalKey Enter = new(0x0D, 0x1C);
    private static readonly PhysicalKey Shift = new(0xA0, 0x2A);

    [Fact]
    public void AccentsKeepTheirOwnSnapshotWhileTheNextRowStartsImmediately() {
        var model = new KeyBurstDynamics();
        for (int i = 0; i < 14; i++) model.Press(new PhysicalKey('A' + i, 0), i * 0.05);
        Assert.Equal("EFGHIJKLMN", string.Concat(model.Keys.Select(key => key.Label)));

        model.Press(Space, 0.75);
        var exploded = Assert.IsType<KeyBurstAccent>(model.Accent);
        Assert.Equal(KeyBurstKind.Space, exploded.Strike.Kind);
        Assert.Equal(10, exploded.Keys.Count);
        Assert.Empty(model.Keys);

        model.Press(Space, 0.80);
        Assert.Same(exploded, model.Accent);
        model.Press(A, 0.85);
        Assert.Equal("A", Assert.Single(model.Keys).Label);
        Assert.Same(exploded, model.Accent);
        Assert.Equal("EFGHIJKLMN", string.Concat(exploded.Keys.Select(key => key.Label)));

        model.Press(new PhysicalKey(0x0D, 0x1C, Extended: true), 0.90);
        var collapsed = Assert.IsType<KeyBurstAccent>(model.Accent);
        Assert.Equal(KeyBurstKind.Return, collapsed.Strike.Kind);
        Assert.Equal("↵", collapsed.Strike.Label);
        Assert.Equal("A", Assert.Single(collapsed.Keys).Label);
        Assert.Empty(model.Keys);
    }

    [Fact]
    public void EachGlyphFadesOnItsOwnClockAndExpiredGlyphsCannotReappear() {
        var model = new KeyBurstDynamics();
        model.Press(A, 0);
        var first = Assert.Single(model.Keys);
        model.Press(B, 1);
        Assert.Equal(1.0, KeyBurstDynamics.Opacity(first, 2.2));
        Assert.Equal(0.5, KeyBurstDynamics.Opacity(first, 2.575), precision: 10);
        Assert.Equal(1.0, KeyBurstDynamics.Opacity(model.Keys[1], 2.575));

        model.Press(A, 2.575);
        Assert.Equal(first, model.Keys[0]);
        Assert.True(model.IsVisible(5.45));
        Assert.False(model.IsVisible(5.53));
        model.Press(Space, 5.60);
        var accent = Assert.IsType<KeyBurstAccent>(model.Accent);
        Assert.Empty(accent.Keys);
        Assert.True(model.IsVisible(5.70));
        Assert.False(model.IsVisible(5.90));
    }

    [Fact]
    public void OnlyTypingBuildsChargeAndAnAccentSpendsTheDecayedValue() {
        var model = new KeyBurstDynamics();
        model.Press(A, 0);
        model.Press(B, 0.1);
        model.Press(Shift, 0.2);
        model.Press(new PhysicalKey(0x25, 0x4B, Extended: true), 0.3);
        model.Press(Space, 0.4);
        double expected = (0.08 * Math.Exp(-0.1 / 0.6) + 0.08 + 0.16 / 6) * Math.Exp(-0.3 / 0.6);
        Assert.Equal(expected, Assert.IsType<KeyBurstAccent>(model.Accent).Strike.AccentCharge, precision: 10);

        model.Press(Enter, 0.9);
        var next = Assert.IsType<KeyBurstAccent>(model.Accent);
        Assert.Equal(KeyBurstKind.Return, next.Strike.Kind);
        Assert.Equal(0.0, next.Strike.AccentCharge);
    }

    [Fact]
    public void LabelsUseScanPositionsInsteadOfLayoutOrShiftedText() {
        var model = new KeyBurstDynamics();
        model.Press(Shift, 0);
        model.Press(new PhysicalKey(0x41, 0x10), 0.05); // AZERTY A at the Q scan position.
        model.Press(new PhysicalKey(0x24, 0x47), 0.10); // Keypad 7 with Num Lock off.
        model.Press(new PhysicalKey(0x24, 0x47, Extended: true), 0.15); // Dedicated Home.
        model.Press(new PhysicalKey(0x5B, 0x5B, Extended: true), 0.20);
        Assert.Equal(new[] { "⇧", "Q", "7", "◇", "⊞" }, model.Keys.Select(key => key.Label));
        Assert.Equal(KeyBurstKind.Character, model.Keys[2].Kind);
        Assert.Equal(KeyBurstKind.Navigation, model.Keys[3].Kind);
    }

    [Fact]
    public void ResetClearsBothRowsAndClockAndIgnoresInvalidTimestamps() {
        var model = new KeyBurstDynamics();
        model.Press(A, 1);
        model.Press(Space, 1.1);
        model.Press(B, 0.5);
        Assert.Equal(1.1, Assert.Single(model.Keys).Time);
        model.Press(A, double.NaN);
        model.Press(Enter, double.PositiveInfinity);
        Assert.Single(model.Keys);
        Assert.Equal(KeyBurstKind.Space, Assert.IsType<KeyBurstAccent>(model.Accent).Strike.Kind);
        Assert.False(model.IsVisible(double.NaN));

        model.Reset();
        Assert.Empty(model.Keys);
        Assert.Null(model.Accent);
        Assert.False(model.IsVisible(1.2));
        model.Press(A, 0.05);
        Assert.Equal(0.05, Assert.Single(model.Keys).Time);
    }
}
