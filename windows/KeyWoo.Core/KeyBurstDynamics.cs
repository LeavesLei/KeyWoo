namespace KeyWoo.Core;

public enum KeyBurstKind { Character, Space, Return, Delete, Navigation, Modifier }

public readonly record struct KeyBurstGlyph(long Sequence, PhysicalKey Key, double Time,
    KeyBurstKind Kind, string Label, double AccentCharge);

public sealed record KeyBurstAccent(IReadOnlyList<KeyBurstGlyph> Keys, KeyBurstGlyph Strike);

/// <summary>Transient visual state for accepted physical presses, using a monotonic clock.</summary>
public sealed class KeyBurstDynamics {
    public const int MaximumKeys = 10;
    private const double KeyHoldDuration = 2.2;
    private const double KeyFadeDuration = 0.75;
    private const double AccentRetention = 0.38;
    private const double AccentVisualDuration = 0.26;
    private const double ChargeWindow = 0.6;
    private readonly List<KeyBurstGlyph> keys = new(MaximumKeys);
    private readonly Queue<double> recentCharacters = new(8);
    private double? lastPress;
    private double? lastChargeUpdate;
    private double storedCharge;
    private long sequence;

    public KeyBurstDynamics() => Keys = keys.AsReadOnly();

    public IReadOnlyList<KeyBurstGlyph> Keys { get; }
    public KeyBurstAccent? Accent { get; private set; }

    public void Press(PhysicalKey key, double time) {
        if (!double.IsFinite(time)) return;
        time = Math.Max(lastPress ?? time, time);
        lastPress = time;

        var kind = KindFor(key);
        bool isAccent = kind is KeyBurstKind.Space or KeyBurstKind.Return;
        double spentCharge = 0;
        if (kind == KeyBurstKind.Character) {
            while (recentCharacters.TryPeek(out double oldest) && time - oldest > ChargeWindow) {
                recentCharacters.Dequeue();
            }
            double cadence = Math.Min(1, recentCharacters.Count / 6.0);
            storedCharge = Math.Min(1, ChargeAt(time) + 0.08 + cadence * 0.16);
            lastChargeUpdate = time;
            if (recentCharacters.Count == 8) recentCharacters.Dequeue();
            recentCharacters.Enqueue(time);
        } else if (isAccent) {
            spentCharge = ChargeAt(time);
            storedCharge = 0;
            lastChargeUpdate = time;
        }

        var glyph = new KeyBurstGlyph(++sequence, key, time, kind, LabelFor(key, kind), spentCharge);
        if (Accent is { } previous && time - previous.Strike.Time >= AccentRetention) Accent = null;
        if (isAccent) {
            bool hasVisibleKeys = keys.Count > 0 && Opacity(keys[^1], time) > 0;
            // Keep old slots for the renderer. An empty accent may not interrupt a group already in flight.
            if (hasVisibleKeys || Accent is null) {
                IReadOnlyList<KeyBurstGlyph> outgoing = hasVisibleKeys
                    ? Array.AsReadOnly(keys.ToArray())
                    : Array.Empty<KeyBurstGlyph>();
                Accent = new(outgoing, glyph);
            }
            keys.Clear();
        } else {
            keys.RemoveAll(existing => Opacity(existing, time) == 0);
            if (keys.Count == MaximumKeys) keys.RemoveAt(0);
            keys.Add(glyph);
        }
    }

    public void Reset() {
        keys.Clear();
        Accent = null;
        recentCharacters.Clear();
        lastPress = null;
        lastChargeUpdate = null;
        storedCharge = 0;
    }

    public bool IsVisible(double time) {
        if (!double.IsFinite(time)) return false;
        return (keys.Count > 0 && Opacity(keys[^1], time) > 0.01)
            || (Accent is { } outgoing && time - outgoing.Strike.Time < AccentVisualDuration);
    }

    public static double Opacity(KeyBurstGlyph key, double time) {
        if (!double.IsFinite(time) || !double.IsFinite(key.Time)) return 0;
        double progress = Math.Clamp((time - key.Time - KeyHoldDuration) / KeyFadeDuration, 0, 1);
        return 1 - progress * progress * (3 - 2 * progress);
    }

    private double ChargeAt(double time) => lastChargeUpdate is { } updated
        ? storedCharge * Math.Exp(-Math.Max(0, time - updated) / ChargeWindow)
        : 0;

    private static KeyBurstKind KindFor(PhysicalKey key) {
        // These Windows actions can share scan values with ordinary positions on some devices.
        if (KeyboardKeys.IsOneShot(key.VirtualKey) || key.VirtualKey is 0x03 or 0x2C) return KeyBurstKind.Navigation;
        return key.MacCode switch {
            49 => KeyBurstKind.Space,
            36 or 76 => KeyBurstKind.Return,
            51 or 117 => KeyBurstKind.Delete,
            48 or 53 or >= 114 and <= 116 or >= 118 and <= 126 => KeyBurstKind.Navigation,
            >= 54 and <= 63 => KeyBurstKind.Modifier,
            65535 => key.VirtualKey switch {
                0x20 => KeyBurstKind.Space,
                0x0D => KeyBurstKind.Return,
                0x08 or 0x2E => KeyBurstKind.Delete,
                0x09 or 0x1B or >= 0x21 and <= 0x28 or 0x2D => KeyBurstKind.Navigation,
                0x14 => KeyBurstKind.Modifier,
                _ => KeyboardKeys.IsModifier(key.VirtualKey) ? KeyBurstKind.Modifier : KeyBurstKind.Character
            },
            _ => KeyBurstKind.Character
        };
    }

    private static string LabelFor(PhysicalKey key, KeyBurstKind kind) {
        switch (kind) {
            case KeyBurstKind.Space: return "␣";
            case KeyBurstKind.Return: return "↵";
            case KeyBurstKind.Delete: return "⌫";
            case KeyBurstKind.Modifier:
                return KeyboardKeys.Modifier(key.VirtualKey) switch {
                    KeyModifiers.Shift => "⇧",
                    KeyModifiers.Control => "⌃",
                    KeyModifiers.Alt => "⌥",
                    KeyModifiers.Windows => "⊞",
                    _ => key.MacCode is 57 || key.VirtualKey == 0x14 ? "⇪" : "◇"
                };
        }

        // Use the shared hardware scan mapping first so input language and Shift do not change the label.
        if (!KeyboardKeys.IsOneShot(key.VirtualKey) && key.VirtualKey is not (0x03 or 0x2C)
            && PositionLabels.TryGetValue(key.MacCode, out var position)) return position;
        if (key.VirtualKey == 0x1B) return "esc";
        if (key.VirtualKey == 0x09) return "⇥";
        string label = KeyboardKeys.Name(key.VirtualKey);
        if (label.StartsWith("Num ", StringComparison.Ordinal)) label = label[4..];
        if (label.StartsWith("VK ", StringComparison.Ordinal)) return "•";
        return label.Length <= 3 ? label.ToUpperInvariant() : "◇";
    }

    private static readonly Dictionary<int, string> PositionLabels = new() {
        // ANSI rows in the same positions as macOS KeyLayout.
        [50] = "`", [18] = "1", [19] = "2", [20] = "3", [21] = "4", [23] = "5", [22] = "6",
        [26] = "7", [28] = "8", [25] = "9", [29] = "0", [27] = "−", [24] = "=",
        [48] = "⇥", [12] = "Q", [13] = "W", [14] = "E", [15] = "R", [17] = "T", [16] = "Y",
        [32] = "U", [34] = "I", [31] = "O", [35] = "P", [33] = "[", [30] = "]", [42] = "\\",
        [0] = "A", [1] = "S", [2] = "D", [3] = "F", [5] = "G", [4] = "H", [38] = "J",
        [40] = "K", [37] = "L", [41] = ";", [39] = "′",
        [6] = "Z", [7] = "X", [8] = "C", [9] = "V", [11] = "B", [45] = "N", [46] = "M",
        [43] = ",", [47] = ".", [44] = "/",
        [53] = "esc", [123] = "←", [126] = "↑", [125] = "↓", [124] = "→",
        [114] = "◇", [115] = "◇", [116] = "◇", [119] = "END", [121] = "◇", [71] = "◇", [10] = "◇",
        [122] = "F1", [120] = "F2", [99] = "F3", [118] = "F4", [96] = "F5", [97] = "F6",
        [98] = "F7", [100] = "F8", [101] = "F9", [109] = "F10", [103] = "F11", [111] = "F12",
        [65] = ".", [67] = "×", [69] = "+", [75] = "÷", [78] = "−",
        [82] = "0", [83] = "1", [84] = "2", [85] = "3", [86] = "4", [87] = "5",
        [88] = "6", [89] = "7", [91] = "8", [92] = "9"
    };
}
