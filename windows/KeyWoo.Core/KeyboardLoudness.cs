namespace KeyWoo.Core;

/// Matches the macOS keyboard-contact calibration. K weighting is measurement
/// only: playback keeps the original PCM, stereo image and relative key levels.
/// This transient measure is not a programme LUFS meter.
public static class KeyboardLoudness {
    public readonly record struct Measurement(double Energy, double Peak, double TransientRms);
    public readonly record struct Profile(double MeasuredRms, double SourcePeak, float Gain);
    public const double TargetRms=.015, MaximumGain=4, PeakHeadroom=.90;
    private static readonly int[] Ordinary=[0,1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,
        17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,38,40,41,43,45,46,47];
    private static readonly (int Key,double Weight)[] CalibrationKeys=Ordinary.Select(key=>(key,.64/Ordinary.Length))
        .Concat([(49,.12),(36,.08),(51,.08),(48,.04),(56,.04)]).ToArray();
    private struct Filter(double b0,double b1,double b2,double a1,double a2) {
        private double x1,x2,y1,y2;
        public double Apply(double x) {
            double y=b0*x+b1*x1+b2*x2-a1*y1-a2*y2;
            x2=x1;x1=x;y2=y1;y1=y;return y;
        }
        public static Filter Shelf=>new(1.53512485958697,-2.69169618940638,1.19839281085285,-1.69065929318241,.73248077421585);
        public static Filter Highpass=>new(1,-2,1,-1.99004745483398,.99007225036621);
    }
    public static Measurement Measure(ReadOnlySpan<float> samples,int channels=2) {
        if(channels is not (1 or 2)||samples.Length==0||samples.Length%channels!=0)return default;
        Filter[] shelves=[Filter.Shelf,Filter.Shelf],highpasses=[Filter.Highpass,Filter.Highpass];
        const int window=2400;
        var ring=new double[window];double sum=0,maximum=0,total=0,peak=0;
        int frames=samples.Length/channels;
        for(int frame=0;frame<frames+window;frame++) {
            double power=0;
            for(int channel=0;channel<channels;channel++) {
                double x=frame<frames?samples[frame*channels+channel]:0;
                if(!double.IsFinite(x))return default;
                peak=Math.Max(peak,Math.Abs(x));
                double weighted=highpasses[channel].Apply(shelves[channel].Apply(x));
                power+=weighted*weighted/channels;
            }
            sum+=power-ring[frame%window];ring[frame%window]=power;
            maximum=Math.Max(maximum,sum);total+=power;
        }
        return new(total/9600,peak,Math.Sqrt(maximum/window));
    }
    public static Profile FromMeasurement(double energy,double peak) {
        if(!double.IsFinite(energy)||energy<=1e-16||!double.IsFinite(peak)||peak<=1e-8)return new(0,0,1);
        double rms=Math.Sqrt(energy);
        return new(rms,peak,(float)Math.Max(.05,Math.Min(MaximumGain,Math.Min(TargetRms/rms,PeakHeadroom/peak))));
    }
    internal static Profile Calibrate(SamplePack pack) {
        var measured=new Dictionary<SampleClip,Measurement>();double energy=0,peak=0;
        foreach(var (key,weight) in CalibrationKeys) {
            var pair=pack.Keys.GetValueOrDefault(key,pack.Fallback);
            int variants=Math.Max(pair.Down.Length,pair.Up.Length);
            for(int variant=0;variant<variants;variant++)foreach(bool down in new[]{true,false}) {
                var clip=pack.Get(key,down,variant);if(clip is null)continue;
                if(!measured.TryGetValue(clip,out var value)){value=Measure(clip.Samples);measured[clip]=value;}
                energy+=value.Energy*weight/variants;
            }
        }
        // Rare keys share the gain and contribute only to peak protection.
        foreach(var clip in pack.Clips)foreach(float sample in clip.Samples)peak=Math.Max(peak,Math.Abs(sample));
        return FromMeasurement(energy,peak);
    }
}
