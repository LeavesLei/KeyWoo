using System.Globalization;
using System.Windows;
using System.Windows.Media;
using KeyWoo.Core;

namespace KeyWoo.Windows;

internal readonly record struct KeyBurstVisualOptions(double Intensity, double Brightness, bool Flashes, bool ReduceMotion);

internal static class KeyBurstDrawing {
    public const double Width = 340;
    public const double Height = 224;
    private const double Left = 29;
    private const double GlyphEmSize = 64;
    private const int MaximumGlyphs = KeyBurstDynamics.MaximumKeys;
    private const int GlyphCacheLimit = 128;
    private const double FragmentDuration = 0.26;
    private const double MinimumOpacity = 0.002;

    private static readonly Typeface KeyTypeface = new(new FontFamily("Segoe UI, Segoe UI Symbol"),
        FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    // Draw runs on the UI dispatcher. Freeze geometry so the same outline can
    // serve every font size, rotation, and color without formatting per frame.
    private static readonly Dictionary<string, Geometry> GlyphGeometry = new(StringComparer.Ordinal);
    private static readonly Pen GlyphInk = Stroke(Color.FromArgb(194, 0, 0, 0), 2.4);
    private static readonly Pen FragmentInk = Stroke(Color.FromArgb(56, 0, 0, 0), 2.4);
    private static readonly Pen FragmentHighlight = Stroke(Colors.White, 0.7);
    private static readonly KeyPalette[] Palettes = [
        new(Color.FromRgb(82, 255, 245)), new(Color.FromRgb(82, 130, 255)),
        new(Color.FromRgb(169, 82, 255)), new(Color.FromRgb(255, 82, 206)),
        new(Color.FromRgb(82, 255, 151)), new(Color.FromRgb(255, 186, 82))
    ];

    public static void Draw(DrawingContext context, Size size, KeyBurstDynamics dynamics, double time,
                            KeyBurstVisualOptions options) {
        if (!double.IsFinite(time) || !double.IsFinite(size.Width) || !double.IsFinite(size.Height) ||
            size.Width < 24 || size.Height < 36) return;

        double brightness = double.IsFinite(options.Brightness) ? Math.Clamp(options.Brightness, 0, 1) : 1;
        if (brightness <= MinimumOpacity) return;
        double baseline = size.Height * 0.57;
        bool flash = options.Flashes && !options.ReduceMotion;
        context.PushOpacity(brightness);
        if (dynamics.Accent is { } accent) DrawAccent(context, size, baseline, accent, time, options, flash);

        var keys = dynamics.Keys;
        if (keys.Count > 0) {
            var row = RowAt(keys.Count, keys[^1].Time, time, baseline, options.ReduceMotion);
            for (int index = 0; index < keys.Count; index++) {
                var key = keys[index];
                var placement = Place(key, row, index, time, options.ReduceMotion);
                double fresh = flash ? Math.Clamp(1 - (time - key.Time) / 0.18, 0, 1) * 0.45 : 0;
                DrawGlyph(context, key, placement, KeyBurstDynamics.Opacity(key, time) * placement.Opacity,
                    0.18 + fresh);
            }
        }
        context.Pop();
    }

    private static void DrawAccent(DrawingContext context, Size size, double baseline, KeyBurstAccent accent,
                                   double time, KeyBurstVisualOptions options, bool flash) {
        var strike = accent.Strike;
        double age = Math.Max(0, time - strike.Time);
        bool isSpace = strike.Kind == KeyBurstKind.Space;
        double glyphDuration = options.ReduceMotion ? 0.22 : isSpace ? 0.095 : 0.14;
        bool drawFragments = isSpace && !options.ReduceMotion && age < FragmentDuration;
        if (age >= glyphDuration && !drawFragments) return;

        int count = Math.Max(1, accent.Keys.Count);
        bool standalone = accent.Keys.Count == 0;
        var row = RowAt(count, standalone ? strike.Time : accent.Keys[^1].Time,
            strike.Time, baseline, options.ReduceMotion);
        Span<KeyPlacement> placements = stackalloc KeyPlacement[MaximumGlyphs];
        double centerX = 0;
        for (int index = 0; index < count; index++) {
            placements[index] = Place(standalone ? strike : accent.Keys[index], row, index,
                strike.Time, options.ReduceMotion);
            centerX += placements[index].Center.X;
        }
        centerX /= count;

        double charge = Math.Clamp(strike.AccentCharge, 0, 1);
        if (age < glyphDuration) {
            double progress = age / glyphDuration;
            double travel = Ease(progress);
            double flashGlow = flash ? (1 - progress) * (0.25 + charge * 0.4) : 0;
            for (int index = 0; index < count; index++) {
                var key = standalone ? strike : accent.Keys[index];
                var placement = placements[index];
                if (!options.ReduceMotion) {
                    var center = placement.Center;
                    double direction = Direction(index, count);
                    center.X += isSpace ? direction * (8 + charge * 9) * travel
                                        : (centerX - center.X) * 0.17 * travel;
                    center.Y -= (isSpace ? 12 + charge * 10 : 13 + charge * 6) * travel;
                    placement = placement with {
                        Center = center,
                        Angle = placement.Angle + direction * (isSpace ? 14 : 5) * travel,
                        Scale = placement.Scale * (1 - travel * 0.40)
                    };
                }
                double opacity = KeyBurstDynamics.Opacity(key, strike.Time) * placement.Opacity *
                                 Math.Pow(1 - progress, 1.45);
                DrawGlyph(context, key, placement, opacity, 0.18 + flashGlow);
            }
        }

        if (drawFragments) DrawFragments(context, size, accent, placements[..count], age, charge,
            options.Intensity, flash);
    }

    private static void DrawFragments(DrawingContext context, Size size, KeyBurstAccent accent,
                                      ReadOnlySpan<KeyPlacement> placements, double age, double charge,
                                      double intensity, bool flash) {
        int count = Math.Clamp(placements.Length * 2, 6, 20);
        double progress = age / FragmentDuration;
        double travel = Ease(progress);
        double fade = Math.Min(1, age / 0.018) * Math.Pow(1 - progress, 1.4);
        double force = (double.IsFinite(intensity) ? Math.Clamp(intensity, 0, 1.3) : 1) * (0.72 + charge * 0.50);
        for (int fragment = 0; fragment < count; fragment++) {
            int index = fragment * placements.Length / count;
            var key = accent.Keys.Count == 0 ? accent.Strike : accent.Keys[index];
            var placement = placements[index];
            double opacity = fade * KeyBurstDynamics.Opacity(key, accent.Strike.Time) * placement.Opacity;
            if (opacity <= MinimumOpacity) continue;
            long seed = fragment * 17 + key.Sequence * 7 + VisualCode(key.Key);
            double jitter = (Mod(seed, 7) - 3) / 3.0;
            var start = new Point(placement.Center.X + jitter * placement.Edge * 0.13 * placement.Scale,
                placement.Center.Y + (Mod(seed, 5) - 2) * placement.Edge * 0.065 * placement.Scale);
            // Clamp the destination once, so the shard doesn't stop abruptly at an edge.
            double endX = Math.Clamp(start.X + (Direction(fragment, count) * 0.82 + jitter * 0.35) *
                (35 + charge * 35) * force, 12, size.Width - 12);
            double endY = Math.Max(18, start.Y - (30 + Mod(seed, 5) * 7 + charge * 20) * force);
            var point = new Point(start.X + (endX - start.X) * travel,
                start.Y + (endY - start.Y) * travel + 10 * progress * progress);
            double angle = Math.Atan2(endY - start.Y, endX - start.X);
            double halfLength = (2.6 + Mod(seed, 3) * 1.25) * (1 - progress * 0.30) / 2;
            var offset = new Vector(Math.Cos(angle) * halfLength, Math.Sin(angle) * halfLength);
            var from = point - offset;
            var to = point + offset;
            context.PushOpacity(opacity);
            context.DrawLine(FragmentInk, from, to);
            context.DrawLine(PaletteFor(key).Fragment, from, to);
            if (flash && age < 0.07 && fragment % 4 == 0) {
                context.PushOpacity((1 - age / 0.07) * 0.52);
                context.DrawLine(FragmentHighlight, from, to);
                context.Pop();
            }
            context.Pop();
        }
    }

    private static void DrawGlyph(DrawingContext context, KeyBurstGlyph key, KeyPlacement placement,
                                  double opacity, double glow) {
        if (opacity <= MinimumOpacity || string.IsNullOrEmpty(key.Label)) return;
        var geometry = GeometryFor(key.Label);
        double fontSize = Math.Min(placement.Edge * 0.64, placement.Edge * 1.55 / key.Label.Length);
        double scale = fontSize * placement.Scale / GlyphEmSize;
        var transform = Matrix.Identity;
        transform.Scale(scale, scale);
        transform.Rotate(placement.Angle);
        transform.Translate(placement.Center.X, placement.Center.Y);

        var palette = PaletteFor(key);
        context.PushOpacity(opacity);
        context.PushTransform(new MatrixTransform(transform));
        // Several thin, translucent strokes soften the outline without a
        // bitmap blur or a colored backdrop on the layered window.
        context.PushOpacity(Math.Min(1, 0.68 + glow * 0.46));
        context.DrawGeometry(null, palette.OuterGlow, geometry);
        context.DrawGeometry(null, palette.MiddleGlow, geometry);
        context.DrawGeometry(null, palette.InnerGlow, geometry);
        context.Pop();
        context.DrawGeometry(null, GlyphInk, geometry);
        context.DrawGeometry(palette.Face, null, geometry);
        context.PushOpacity(0.12 + glow * 0.10);
        context.DrawGeometry(Brushes.White, null, geometry);
        context.Pop();
        context.Pop();
        context.Pop();
    }

    private static Geometry GeometryFor(string label) {
        if (GlyphGeometry.TryGetValue(label, out var existing)) return existing;
        var text = new FormattedText(label, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            KeyTypeface, GlyphEmSize, Brushes.White, 1);
        var geometry = text.BuildGeometry(new Point(-text.WidthIncludingTrailingWhitespace / 2, -text.Height / 2));
        geometry.Freeze();
        if (GlyphGeometry.Count < GlyphCacheLimit) GlyphGeometry.Add(label, geometry);
        return geometry;
    }

    private static RowMetrics RowAt(int count, double newestTime, double time, double baseline, bool reduceMotion) {
        double progress = count >= MaximumGlyphs || reduceMotion ? 1 : Ease((time - newestTime) / 0.12);
        double effectiveCount = Math.Max(1, count - 1 + progress);
        double compression = Math.Clamp((effectiveCount - 1) / (MaximumGlyphs - 1), 0, 1);
        return new(44 - compression * 20, 6 - compression * 2.5, baseline);
    }

    private static KeyPlacement Place(KeyBurstGlyph key, RowMetrics row, int index, double time, bool reduceMotion) {
        double entered = Ease((time - key.Time) / 0.085);
        int code = VisualCode(key.Key);
        double jitter = reduceMotion ? 0 : (Mod(key.Sequence * 7 + code, 5) - 2) * 0.75;
        double angle = reduceMotion ? 0 : Mod(key.Sequence * 11 + code, 9) - 4;
        var center = new Point(Left + row.Edge / 2 + index * (row.Edge + row.Gap), row.Baseline - row.Edge / 2 + jitter);
        if (!reduceMotion) {
            center.X += (1 - entered) * 5;
            center.Y += (1 - entered) * 7;
        }
        return new(center, row.Edge, angle, reduceMotion ? 1 : 0.86 + entered * 0.14, 0.52 + entered * 0.48);
    }

    private static double Ease(double progress) => 1 - Math.Pow(1 - Math.Clamp(progress, 0, 1), 3);
    private static double Direction(int index, int count) => count > 1 ? 2.0 * index / (count - 1) - 1 : 0;
    private static int Mod(long value, int modulus) => (int)((value % modulus + modulus) % modulus);
    private static int VisualCode(PhysicalKey key) {
        int code = key.MacCode;
        return code == ushort.MaxValue || KeyboardKeys.IsOneShot(key.VirtualKey) ? key.VirtualKey : code;
    }
    private static KeyPalette PaletteFor(KeyBurstGlyph key) =>
        Palettes[Mod(VisualCode(key.Key) * 7L + key.Sequence * 3, Palettes.Length)];

    private static SolidColorBrush Fill(Color color) {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Pen Stroke(Color color, double width) {
        var pen = new Pen(Fill(color), width) {
            LineJoin = PenLineJoin.Round,
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round
        };
        pen.Freeze();
        return pen;
    }

    private readonly record struct RowMetrics(double Edge, double Gap, double Baseline);
    private readonly record struct KeyPlacement(Point Center, double Edge, double Angle, double Scale, double Opacity);

    private sealed class KeyPalette(Color color) {
        public SolidColorBrush Face { get; } = Fill(color);
        public Pen OuterGlow { get; } = Stroke(Color.FromArgb(18, color.R, color.G, color.B), 24);
        public Pen MiddleGlow { get; } = Stroke(Color.FromArgb(28, color.R, color.G, color.B), 15);
        public Pen InnerGlow { get; } = Stroke(Color.FromArgb(45, color.R, color.G, color.B), 8);
        public Pen Fragment { get; } = Stroke(Color.FromArgb(240, color.R, color.G, color.B), 1.35);
    }
}
