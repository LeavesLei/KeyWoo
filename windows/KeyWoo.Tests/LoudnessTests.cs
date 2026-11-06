using KeyWoo.Core;
using Xunit;
namespace KeyWoo.Tests;

public sealed class LoudnessTests {
    private static readonly Lazy<SampleBank> Bank=new(()=>new(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds")));
    [Fact] public void MeasurementIsStableUnderPaddingStereoAndLinearScaling() {
        float[] click=Enumerable.Range(0,4800).Select(i=>(float)(.12*Math.Exp(-i/800.0)*Math.Sin(i*2*Math.PI*1200/48000))).ToArray();
        var original=KeyboardLoudness.Measure(click,1);
        var padded=KeyboardLoudness.Measure([..click,..new float[9600]],1);
        var stereo=KeyboardLoudness.Measure(click.SelectMany(v=>new[]{v,v}).ToArray());
        var boosted=KeyboardLoudness.Measure(click.Select(v=>v*2).ToArray(),1);
        Assert.InRange(Math.Abs(padded.Energy-original.Energy),0,1e-12);
        Assert.InRange(Math.Abs(stereo.Energy-original.Energy),0,1e-12);
        Assert.InRange(Math.Abs(boosted.Energy/original.Energy-4),0,1e-10);
        Assert.Equal(original.Peak*2,boosted.Peak);
        Assert.True(KeyboardLoudness.Measure([..click,..click,..click],1).Energy>original.Energy);
        foreach(double value in new[]{double.NaN,double.PositiveInfinity,-1,0})Assert.Equal(1,KeyboardLoudness.FromMeasurement(value,.2).Gain);
    }
    [Fact] public void PresetGainPreservesLargeKeysReleaseStereoAndOnsets() {
        foreach(var preset in Bank.Value.Presets) {
            var raw=new SampleMixer(Bank.Value,false){Style=preset.Id,Volume=.05f};
            var normalized=new SampleMixer(Bank.Value){Style=preset.Id,Volume=.05f};
            raw.Read(new float[10000]);normalized.Read(new float[10000]);
            float gain=Bank.Value.Packs[preset.Id].Loudness.Gain;
            Assert.InRange(gain,.05f,4f);
            foreach(var key in new[]{new PhysicalKey(0x41,0x1E),new(0x41,0x1E),new(0x20,0x39),new(13,28),new(8,14),new(9,15),new(0xA0,42)}) {
                foreach(bool down in new[]{true,false}) {
                    raw.Physical(key,down);normalized.Physical(key,down);
                    var before=new float[2048];var after=new float[2048];raw.Read(before);normalized.Read(after);
                    for(int i=0;i<before.Length;i++)Assert.InRange(Math.Abs(after[i]-before[i]*gain),0,2e-7);
                    Assert.Equal(Array.FindIndex(before,v=>v!=0),Array.FindIndex(after,v=>v!=0));
                }
            }
            Assert.Equal(raw.Snapshot.Attacks,normalized.Snapshot.Attacks);
            Assert.Equal(0,normalized.Snapshot.Dropped);
        }
    }
    [Fact] public void ASeparateTypingPassageHasMuchLessPresetLevelVariation() {
        var before=new List<double>();var after=new List<double>();
        foreach(var preset in Bank.Value.Presets)foreach(bool normalize in new[]{false,true}) {
            var mixer=new SampleMixer(Bank.Value,normalize){Style=preset.Id,Volume=1};
            mixer.Read(new float[10000]);var pcm=new List<float>();
            foreach(int code in new[]{14,0,35,49,31,4,49,51,36,48,56,45}) {
                mixer.Preview(code,true,0);var down=new float[5760];mixer.Read(down);pcm.AddRange(down);
                mixer.Preview(code,false,0);var up=new float[9600];mixer.Read(up);pcm.AddRange(up);
            }
            var tail=new float[48000];mixer.Read(tail);pcm.AddRange(tail);
            double db=10*Math.Log10(KeyboardLoudness.Measure(pcm.ToArray()).Energy);
            (normalize?after:before).Add(db);
        }
        double beforeSpread=before.Max()-before.Min(),afterSpread=after.Max()-after.Min();
        Assert.True(afterSpread<beforeSpread*.4,$"Spread {beforeSpread:F3} -> {afterSpread:F3} dB");
        Assert.True(afterSpread<4.5,$"Normalized spread {afterSpread:F3} dB");
    }
}
