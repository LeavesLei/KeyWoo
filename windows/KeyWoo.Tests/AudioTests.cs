using System.Security.Cryptography;
using KeyWoo.Core;
using Xunit;
namespace KeyWoo.Tests;
public sealed class AudioTests {
    private static readonly Lazy<SampleBank> Bank=new(()=>new(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds")));
    private static readonly PhysicalKey A=new(0x41,0x1E);
    [Fact] public void EveryPresetHasDistinctActualPcm(){var hashes=new HashSet<string>();foreach(var preset in Bank.Value.Presets){var mixer=new SampleMixer(Bank.Value){Style=preset.Id,Volume=1};mixer.Physical(A,true);var pcm=new float[24000];mixer.Read(pcm);Assert.Contains(pcm,v=>Math.Abs(v)>.00001);Assert.All(pcm,v=>Assert.True(float.IsFinite(v)));byte[] bytes=new byte[pcm.Length*4];Buffer.BlockCopy(pcm,0,bytes,0,bytes.Length);Assert.True(hashes.Add(Convert.ToHexString(SHA256.HashData(bytes))),preset.Id);}Assert.Equal(Bank.Value.Packs.Count,hashes.Count);Assert.True(hashes.Count>=20);}
    [Fact] public void ManifestCatalogPreservesDefaultAndSeparatesSynthesizedSounds() {
        var bank=Bank.Value;
        Assert.Equal(SampleBank.DefaultPreset,new SampleMixer(bank).Style);
        Assert.Equal("topre",bank.Presets.First().Id);
        Assert.Equal(SoundCategory.RecordedKeyboard,bank.Presets.Single(p=>p.Id=="panda").Category);
        Assert.Equal(SoundCategory.RecordedKeyboard,bank.Presets.Single(p=>p.Id=="macbookPro").Category);
        Assert.Equal(SoundCategory.Synthesized,bank.Presets.Single(p=>p.Id=="typewriter").Category);
        foreach(string id in new[]{"hermes","mahjongTiles","woodDesk"}) {
            var foley=bank.Presets.Single(p=>p.Id==id);
            Assert.Equal(SoundCategory.RecordedFoley,foley.Category);
            Assert.NotNull(foley.TitleZh);
        }
        Assert.Equal(bank.Packs.Keys.Order(),bank.Presets.Select(p=>p.Id).Order());
    }
    [Fact] public void SameMixerActuallyChangesStyleAndStopsOldRelease(){var m=new SampleMixer(Bank.Value){Style="blue"};m.Physical(A,true);var first=new float[12000];m.Read(first);m.Style="mahjong";m.Physical(A,false);m.Read(new float[24000]);Assert.Equal(0,m.Snapshot.Releases);m.Physical(A,true);var second=new float[12000];m.Read(second);Assert.False(first.SequenceEqual(second));}
    [Fact] public void PauseIsExactlySilentAndResumeDoesNotReplayQueuedKeys(){var m=new SampleMixer(Bank.Value);m.Physical(A,true);m.Enabled=false;var pcm=new float[96000];m.Read(pcm);Assert.All(pcm,v=>Assert.Equal(0,v));m.Enabled=true;m.Read(pcm);Assert.All(pcm,v=>Assert.Equal(0,v));}
    [Theory]
    [InlineData(4f)]
    [InlineData(SampleMixer.MaximumVolume)]
    public void RapidInputKeepsBoundedVoicesAndPeakAtBoostedVolumes(float volume) {
        var mixer = new SampleMixer(Bank.Value) { Volume = volume };
        for (int i = 0; i < 2000; i++) mixer.Physical(new(65 + i % 26, 30 + i % 26), true);
        var pcm = new float[48000];
        mixer.Read(pcm);
        Assert.True(mixer.Snapshot.Dropped > 0);
        Assert.InRange(mixer.Snapshot.ActiveVoices, 0, SampleMixer.VoiceLimit);
        Assert.All(pcm, value => Assert.InRange(Math.Abs(value), 0, .980001f));
    }

    [Fact]
    public void MaximumGainRaisesQuietRecordedSoundAndClampsOversizedValues() {
        float[] Render(float gain) {
            var mixer = new SampleMixer(Bank.Value) { Style = "woodDesk", Volume = gain };
            mixer.Read(new float[4800]); // Settle the gain before triggering the same take.
            mixer.Physical(A, true);
            var pcm = new float[12000];
            mixer.Read(pcm);
            return pcm;
        }

        var standard = Render(4);
        var maximum = Render(SampleMixer.MaximumVolume);
        Assert.True(maximum.Average(value => value * value) > standard.Average(value => value * value));
        Assert.Equal(maximum, Render(32));
        Assert.All(maximum, value => Assert.InRange(Math.Abs(value), 0, .980001f));
    }
    [Fact] public void ReleaseUsesSameRecordedVariant(){var pack=Bank.Value.Packs["panda"];Assert.Same(pack.Get(0,false,0),pack.Get(0,false,4));Assert.NotSame(pack.Get(0,true,0),pack.Get(0,true,1));}
    [Fact] public void ZeroVolumeIsSilentFromTheFirstSample(){var m=new SampleMixer(Bank.Value){Volume=0};m.Physical(A,true);var pcm=new float[2400];m.Read(pcm);Assert.All(pcm,v=>Assert.Equal(0,v));}
    [Fact] public void InvalidAndTruncatedWaveRejected(){Assert.Throws<InvalidDataException>(()=>SampleBank.DecodeWave([1,2,3]));var bytes=File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds","blue","samples.wav"));Assert.Throws<InvalidDataException>(()=>SampleBank.DecodeWave(bytes[..50]));}
    [Fact] public void SynthesizedSourceSamplesMatchExportedNativeCache(){var clip=Bank.Value.Packs["bubble"].Get(0,true,0)!;Assert.True(clip.Frames>0);Assert.All(clip.Samples,v=>Assert.True(float.IsFinite(v)));Assert.True(clip.Samples.Max(v=>Math.Abs(v))>.001f);}
}
