namespace KeyWoo.Core;

public readonly record struct MixerSnapshot(long Attacks,long Releases,long Dropped,int ActiveVoices,float Peak);
/// Bounded command queue and 24 preallocated voices. Read never opens files,
/// decodes, awaits the UI, or allocates sample arrays. WASAPI pulls continuously.
public sealed class SampleMixer {
    public const int VoiceLimit=24,QueueLimit=256;
    public const float MaximumVolume = 16f;
    private readonly CommandQueue<Command> commands=new(QueueLimit);
    private readonly Voice[] voices=new Voice[VoiceLimit];
    private readonly SamplePack[] styles;
    private readonly bool normalize;
    private readonly Dictionary<int,Held> held=[]; // physical hook thread only
    private int epoch=1,variant,enabled=1;
    private long serial,attacks,releases,dropped;
    private float volume=.5f,smoothed=.5f,peak;
    private int currentStyle;
    private readonly record struct Held(int Variant,int Epoch,int Style);
    private readonly record struct Command(SampleClip? Clip,bool Down,int Key,int Epoch,bool Preview);
    private struct Voice { public SampleClip? Clip; public int Cursor,Delay,Fade,Epoch,Key; public bool Down,Preview; public long Serial,Start; public float Gain; }
    private long position;
    public SampleMixer(SampleBank bank,bool normalizationEnabled=true) {
        normalize=normalizationEnabled;
        styles=bank.Presets.Select(preset=>bank.Packs[preset.Id]).ToArray();
        currentStyle=Array.FindIndex(styles,style=>style.Id==SampleBank.DefaultPreset);
    }
    public string Style { get=>styles[Volatile.Read(ref currentStyle)].Id; set { int index=Array.FindIndex(styles,style=>style.Id==value); if(index<0) return; if(Interlocked.Exchange(ref currentStyle,index)!=index) Reset(); } }
    public float Volume {
        get => Volatile.Read(ref volume);
        set => Volatile.Write(ref volume, float.IsFinite(value) ? Math.Clamp(value, 0, MaximumVolume) : 0);
    }
    public bool Enabled { get=>Volatile.Read(ref enabled)!=0; set { if(Interlocked.Exchange(ref enabled,value?1:0)!=(value?1:0)) Reset(); } }
    public void Reset()=>Interlocked.Increment(ref epoch);
    public void Physical(PhysicalKey key,bool down) {
        if(down) {
            var state=new Held(Interlocked.Increment(ref variant),Volatile.Read(ref epoch),Volatile.Read(ref currentStyle)); held[key.Id]=state;
            Submit(styles[state.Style].Get(key.MacCode,true,state.Variant),true,key.Id,state.Epoch,false);
        } else if(held.Remove(key.Id,out var state)) Submit(styles[state.Style].Get(key.MacCode,false,state.Variant),false,key.Id,state.Epoch,false);
    }
    public void Preview(int macCode,bool down,int token) {
        int style=Volatile.Read(ref currentStyle),generation=Volatile.Read(ref epoch);
        Submit(styles[style].Get(macCode,down,token),down,macCode,generation,true);
    }
    private void Submit(SampleClip? clip,bool down,int key,int generation,bool preview) {
        if(!Enabled) return;
        if(!commands.TryEnqueue(new(clip,down,key,generation,preview)))Interlocked.Increment(ref dropped);
    }
    private void Add(Command command) {
        if(command.Down) Interlocked.Increment(ref attacks);else Interlocked.Increment(ref releases);
        if(command.Clip is null) return;
        int slot=-1,active=0,delay=0;long oldest=long.MaxValue;
        for(int i=0;i<voices.Length;i++) {
            ref var v=ref voices[i];if(v.Clip is null){if(slot<0)slot=i;continue;}active++;
            if(!command.Down&&v.Down&&v.Key==command.Key&&v.Preview==command.Preview)
                delay=Math.Max(delay,Math.Max(0,(command.Preview?3360:576)-(int)(position-v.Start)));
        }
        if(slot<0) for(int i=0;i<voices.Length;i++) if(voices[i].Serial<oldest){oldest=voices[i].Serial;slot=i;}
        voices[slot]=new Voice{Clip=command.Clip,Cursor=0,Delay=delay,Fade=-1,Epoch=command.Epoch,Key=command.Key,Down=command.Down,Preview=command.Preview,Serial=++serial,Start=position,Gain=(normalize?command.Clip.NormalizationGain:1)/MathF.Sqrt(1+.08f*Math.Max(0,active-8))};
    }
    public void Read(Span<float> output) {
        output.Clear();float top=0;int budget=QueueLimit;
        for(int frame=0;frame<output.Length/2;frame++,position++) {
            if((frame&63)==0) {
                int generation=Volatile.Read(ref epoch);
                for(int i=0;i<voices.Length;i++) if(voices[i].Clip is not null&&voices[i].Epoch!=generation&&voices[i].Fade<0) {
                    if(voices[i].Delay>0)voices[i].Clip=null;else voices[i].Fade=240;
                }
                while(budget>0&&commands.TryDequeue(out var command)) {
                    budget--;
                    // A UI reset can advance the epoch after this 64-frame
                    // block began. The dequeued press may already belong to
                    // that new epoch; do not discard it using the stale one.
                    if(command.Epoch==Volatile.Read(ref epoch)&&Enabled)Add(command);
                }
            }
            float l=0,r=0;
            for(int i=0;i<voices.Length;i++) {
                ref var v=ref voices[i]; if(v.Clip is null)continue;
                if(v.Delay>0){v.Delay--;continue;}
                float gain=v.Gain*(v.Fade>=0?v.Fade/240f:1);
                l+=v.Clip.Samples[v.Cursor*2]*gain;r+=v.Clip.Samples[v.Cursor*2+1]*gain;
                v.Cursor++;if(v.Fade>=0)v.Fade--;
                if(v.Cursor>=v.Clip.Frames||v.Fade==0)v.Clip=null;
            }
            smoothed+=(Volume-smoothed)*.004158f;
            l=Limit(l*Math.Min(1,smoothed))*Math.Max(1,smoothed);r=Limit(r*Math.Min(1,smoothed))*Math.Max(1,smoothed);
            if(smoothed>2){l=BoostLimit(l);r=BoostLimit(r);}
            if(!Enabled||Volume==0)l=r=0;
            output[frame*2]=l;output[frame*2+1]=r;top=Math.Max(top,Math.Max(Math.Abs(l),Math.Abs(r)));
        }
        Volatile.Write(ref peak,top);
    }
    public MixerSnapshot Snapshot=>new(Interlocked.Read(ref attacks),Interlocked.Read(ref releases),Interlocked.Read(ref dropped),voices.Count(v=>v.Clip is not null),Volatile.Read(ref peak));
    private static float BoostLimit(float value)=>Math.Abs(value)<=.84f?value:MathF.CopySign(.84f+.14f*MathF.Tanh((Math.Abs(value)-.84f)/.14f),value);
    private static float Limit(float value)=>Math.Abs(value)<=.25f?value:MathF.CopySign(.25f+.17f*MathF.Tanh((Math.Abs(value)-.25f)/.17f),value);
}
