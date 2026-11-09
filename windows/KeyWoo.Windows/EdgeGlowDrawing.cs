using System.Windows;
using System.Windows.Media;
using KeyWoo.Core;

namespace KeyWoo.Windows;

/// <summary>A bounded typing envelope shared by both bottom-edge light layers.</summary>
internal sealed class EdgeGlowDynamics {
    internal readonly record struct Pulse(double Time, double Impact, double Strength, double Charge, double Lane, bool Space, bool Return);
    private readonly List<Pulse> pulses = new(24);
    private readonly Queue<double> characters = new(8);
    private double? lastHit, lastCharge;
    private double meterTarget, meterCarry, charge;
    private double hold = .28;
    internal IReadOnlyList<Pulse> Pulses => pulses;

    internal double Energy(double time) {
        if (lastHit is not double last) return 0;
        double elapsed = Math.Max(0, time - last);
        double held = Math.Min(elapsed, hold);
        double value = meterTarget + (meterCarry - meterTarget) * Math.Exp(-held / .10);
        if (elapsed <= hold) return Math.Clamp(value, 0, 1);
        double tail = elapsed - hold;
        return Math.Clamp(value * Math.Exp(-tail / .10) + meterTarget * .85 / .75 *
            (Math.Exp(-tail / .85) - Math.Exp(-tail / .10)), 0, 1);
    }

    internal void Press(PhysicalKey key, double time) {
        if (!double.IsFinite(time)) return;
        time = Math.Max(lastHit ?? time, time);
        bool space = key.VirtualKey == 0x20, enter = key.VirtualKey == 0x0d;
        bool modifier = KeyboardKeys.IsModifier(key.VirtualKey) || key.VirtualKey == 0x14;
        bool navigation = KeyboardKeys.IsOneShot(key.VirtualKey) || key.VirtualKey is 0x09 or 0x1b or >= 0x21 and <= 0x28;
        bool character = !space && !enter && !modifier && !navigation && key.VirtualKey is not (0x08 or 0x2e);
        double impact = space ? 1 : enter ? .74 : modifier ? .27 : navigation ? .34 : key.VirtualKey is 0x08 or 0x2e ? .42 : .24;
        double previousCharge = charge * Math.Exp(-Math.Max(0, time - (lastCharge ?? time)) / .6);
        double spent = space || enter ? previousCharge : 0;
        if (character) {
            while (characters.TryPeek(out var oldest) && time - oldest > .6) characters.Dequeue();
            charge = Math.Min(1, previousCharge + .08 + Math.Min(1, characters.Count / 6.0) * .16);
            if (characters.Count == 8) characters.Dequeue();
            characters.Enqueue(time);
            lastCharge = time;
        } else if (space || enter) { charge = 0; lastCharge = time; }
        meterCarry = Energy(time);
        double previousTarget = meterTarget * Math.Exp(-Math.Max(0, time - (lastHit ?? time) - hold) / .85);
        double increment = space || enter ? .10 + .08 * spent : character ? .08 : .05;
        meterTarget = Math.Min(1, previousTarget + increment);
        hold = meterTarget >= .98 && meterCarry >= .72 ? 1.4 : .28;
        lastHit = time;
        pulses.RemoveAll(pulse => time - pulse.Time > 1.35);
        if (pulses.Count == 24) pulses.RemoveAt(0);
        double lane = KeyLane(key);
        pulses.Add(new(time, impact, impact * (1 + (space || enter ? spent * .85 : Math.Min(1, characters.Count / 11.0) * .24)), spent, lane, space, enter));
    }

    private static double KeyLane(PhysicalKey key) {
        // Hardware positions remain stable across keyboard layouts and input languages.
        int code = key.MacCode;
        int[][] rows = [ [50,18,19,20,21,23,22,26,28,25,29,27,24,51], [48,12,13,14,15,17,16,32,34,31,35,33,30,42],
            [57,0,1,2,3,5,4,38,40,37,41,39,36], [56,6,7,8,9,11,45,46,43,47,44,60] ];
        foreach (var row in rows) {
            int index = Array.IndexOf(row, code);
            if (index >= 0) return (index + .5) / row.Length;
        }
        return .5;
    }

    internal void Reset() { pulses.Clear(); characters.Clear(); lastHit = lastCharge = null; meterTarget = meterCarry = charge = 0; hold = .28; }
    internal bool IsVisible(double time) => Energy(time) > .001 || pulses.Any(pulse => time - pulse.Time < .8);
}

internal static class EdgeGlowDrawing {
    internal static void Draw(DrawingContext context, Size size, EdgeGlowDynamics dynamics, AudioSpectrum spectrum,
                              double time, KeyBurstVisualOptions options) {
        if (size.Width < 24 || size.Height < 36 || !double.IsFinite(time)) return;
        double energy = dynamics.Energy(time), taps = 0, accent = 0;
        var ripples = new List<(double Origin, double Position, double Width, double Light)>(24);
        foreach (var pulse in dynamics.Pulses) {
            double age = Math.Max(0, time - pulse.Time), gain = pulse.Strength / pulse.Impact;
            double duration, reach, width, light, origin;
            if (pulse.Space || pulse.Return) {
                accent += (pulse.Space ? .84 : .61) * gain * Envelope(age, .008, pulse.Space ? .28 : .23);
                origin = 0;
                duration = pulse.Space ? .62 + .10 * pulse.Charge : .49 + .07 * pulse.Charge;
                reach = pulse.Space ? .92 + .08 * pulse.Charge : .64 + .12 * pulse.Charge;
                width = pulse.Space ? .15 : .13;
                light = (pulse.Space ? 1.32 : .90) * gain;
            } else {
                origin = Math.Clamp((pulse.Lane - .5) * 1.35, -.64, .64);
                taps += pulse.Strength * Envelope(age, .006, .10);
                duration = .30; reach = .35; width = .10; light = 1.70 * pulse.Strength;
            }
            if (!options.ReduceMotion && age < duration) {
                double progress = age / duration;
                ripples.Add((origin, reach * progress * (2 - progress), width + .04 * progress,
                    light * Math.Min(1, age / .032) * Math.Pow(1 - progress, 1.1)));
            }
        }
        double tapLevel = Math.Tanh(taps), accentLevel = Math.Tanh(accent);
        double drive = 1 - Math.Exp(-(energy * 1.55 + tapLevel * .85 + accentLevel * 1.05) * options.Intensity);
        context.PushOpacity(Math.Clamp(options.Brightness, 0, 1));
        DrawMusic(context, size, spectrum, time, options, drive, energy);
        if (drive > .001) {
            double movement = options.ReduceMotion ? 0 : 1;
            double phase = time % 24 / 24 * Math.PI * 2;
            double rise = 52 + (drive * 38 + tapLevel * 8 + accentLevel * 28) * movement;
            double spread = .34 + (drive * .12 + accentLevel * .08) * movement;
            Color[] colors = [Color.FromRgb(31,194,250),Color.FromRgb(77,122,255),Color.FromRgb(179,89,250)];
            for (int index = 0; index < 3; index++) {
                double drift = Math.Sin(phase + index * 1.9) * .025 * movement * drive;
                var brush = new RadialGradientBrush { Center = new(.5,.5), GradientOrigin = new(.5,.5), RadiusX = .5, RadiusY = .5 };
                AddStop(brush, colors[index], .66 * drive, 0);
                AddStop(brush, colors[index], .66 * drive * .70, .24);
                AddStop(brush, colors[index], .66 * drive * .22, .63);
                AddStop(brush, colors[index], 0, 1);
                double radius = Math.Min(size.Height + 4, rise * (index == 1 ? 1 : .88));
                context.DrawEllipse(brush, null, new(size.Width * (.20 + index * .30 + drift), size.Height + 8), size.Width * spread, radius);
            }
            var ribbon = new StreamGeometry();
            var tint = new LinearGradientBrush { StartPoint = new(0,0), EndPoint = new(1,0) };
            using (var shape = ribbon.Open()) {
                shape.BeginFigure(new(-16,size.Height+14),true,true);
                for (int index = 0; index <= 56; index++) {
                    double t = index / 56.0, sum = 0;
                    foreach (var ripple in ripples) {
                        double offset = (Math.Abs(t * 2 - 1 - ripple.Origin) - ripple.Position) / ripple.Width;
                        sum += ripple.Light * Math.Exp(-.5 * offset * offset);
                    }
                    double light = 1 - Math.Exp(-sum * options.Intensity);
                    double taper = Math.Pow(Math.Max(0, Math.Sin(Math.PI * t)), .30);
                    double wave = .83 + .17 * Math.Sin(t * Math.PI * 3.4 + phase * movement);
                    double lift = ((5 + (drive * 18 + tapLevel * 6 + accentLevel * 10) * movement) * wave + 38 * light) * taper;
                    shape.LineTo(new(t * (size.Width + 32) - 16, size.Height - lift),true,false);
                    double baseOpacity = drive * (.49 + .08 * taper);
                    double crestOpacity = light * (options.Flashes ? .76 : .58);
                    AddStop(tint, Hsv(.52 + .25 * t, .80 - .38 * light), baseOpacity + (1 - baseOpacity) * crestOpacity, t);
                }
                shape.LineTo(new(size.Width+16,size.Height+14),true,false);
            }
            SoftShape(context, ribbon, tint, 8);
        }
        context.Pop();
    }

    private static double Envelope(double age, double attack, double release) => (1 - Math.Exp(-age / attack)) * Math.Exp(-age / release);

    private static void DrawMusic(DrawingContext context, Size size, AudioSpectrum spectrum, double time,
                                  KeyBurstVisualOptions options, double drive, double energy) {
        var regions = EdgeMusicGeometry.Regions(spectrum,time,options.Intensity,drive,options.ReduceMotion,energy);
        foreach (var region in regions) {
            Color color = Hsv(region.Hue, .74);
            if (region.BodyOpacity > .001) {
                var body = Wave(size,region.CenterX*size.Width,region.RadiusX*size.Width,region.BodyHeight,region);
                var brush = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new(region.CenterX*size.Width,size.Height-region.BodyHeight), EndPoint = new(region.CenterX*size.Width,size.Height+8) };
                AddStop(brush,color,0,0);AddStop(brush,color,region.BodyOpacity,.56);AddStop(brush,color,region.BodyOpacity*.24,1);
                SoftShape(context,body,brush,11);
            }
            if (region.CrestOpacity <= .001) continue;
            double height = Math.Min(size.Height - 12,region.CrestHeight);
            var crest = Wave(size,region.CrestX*size.Width,region.CrestRadiusX*size.Width,height,region);
            double light = region.CrestOpacity * (options.Flashes && !options.ReduceMotion ? 1 : .82);
            var tint = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new(region.CrestX*size.Width,size.Height-height), EndPoint = new(region.CrestX*size.Width,size.Height+9) };
            AddStop(tint,color,light*.40,0);AddStop(tint,color,light,.34);AddStop(tint,color,light*.36,.76);AddStop(tint,color,0,1);
            SoftShape(context,crest,tint,4.5);
        }
    }

    private static StreamGeometry Wave(Size size,double center,double radius,double height,EdgeMusicRegion region) {
        Point Point(double x,double y) => new(center+radius*x,size.Height-height*y);
        var result = new StreamGeometry();
        using var shape = result.Open();
        shape.BeginFigure(Point(-1,0),true,true);
        if (region.Profile == EdgeMusicProfile.Bass) {
            shape.BezierTo(Point(-.78,.02),Point(-.50,.88),Point(-.32,.88),true,false);
            shape.BezierTo(Point(-.14,.88),Point(0,.62),Point(.16,.62),true,false);
            shape.BezierTo(Point(.30,.62),Point(.40,region.Shoulder),Point(.57,region.Shoulder),true,false);
            shape.BezierTo(Point(.74,region.Shoulder),Point(.90,0),Point(1,0),true,false);
        } else {
            shape.BezierTo(Point(-.81,0),Point(-.68,region.Shoulder),Point(-.45,region.Shoulder),true,false);
            shape.BezierTo(Point(-.30,region.Shoulder),Point(-.23,region.Shoulder*.90),Point(-.08,region.Shoulder*.90),true,false);
            shape.BezierTo(Point(.08,region.Shoulder*.90),Point(.13,.91),Point(.29,.91),true,false);
            shape.BezierTo(Point(.58,.91),Point(.69,0),Point(1,0),true,false);
        }
        shape.LineTo(new(center+radius,size.Height+10),true,false);
        shape.LineTo(new(center-radius,size.Height+10),true,false);
        return result;
    }

    // A few translucent strokes soften the vector silhouette without a per-frame bitmap allocation.
    private static void SoftShape(DrawingContext context, Geometry geometry, Brush brush, double radius) {
        foreach (double spread in new[] { 2.0, 1.2, .5 }) {
            context.PushOpacity(.085);
            context.DrawGeometry(brush,new Pen(brush,radius*spread),geometry);
            context.Pop();
        }
        context.PushOpacity(.72);
        context.DrawGeometry(brush,null,geometry);
        context.Pop();
    }
    private static void AddStop(GradientBrush brush,Color color,double opacity,double position) => brush.GradientStops.Add(new(Color.FromArgb((byte)Math.Round(Math.Clamp(opacity,0,1)*255),color.R,color.G,color.B),position));
    private static Color Hsv(double hue,double saturation) {
        double h = (hue-Math.Floor(hue))*6, x = 1-saturation*(1-Math.Abs(h%2-1)), low = 1-saturation;
        var rgb = (int)h switch {0 => (1.0,x,low),1 => (x,1.0,low),2 => (low,1.0,x),3 => (low,x,1.0),4 => (x,low,1.0),_ => (1.0,low,x)};
        return Color.FromRgb((byte)Math.Round(rgb.Item1*255),(byte)Math.Round(rgb.Item2*255),(byte)Math.Round(rgb.Item3*255));
    }
}
