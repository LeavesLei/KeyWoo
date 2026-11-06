namespace KeyWoo.Core;

public readonly record struct RoutingDecision(bool Count, bool SoundDown, bool SoundUp, bool Suppress, KeyInjection[] Inject) {
    public static RoutingDecision Pass => new(false,false,false,false,[]);
}

/// Owned by the hook's dedicated message thread. No files, UI or audio-device calls.
public sealed class InputRouter {
    private readonly Dictionary<int,int> physical = [];
    // Startup state is reported by Windows as virtual keys, without a hardware
    // scan code. Adopt the physical identity on its next edge, never invent a
    // down/count/remap for a press that predates our hook.
    private readonly HashSet<int> seededVisible = [];
    private readonly HashSet<int> quarantined = [];
    private readonly Dictionary<int, InputRule> active = [];
    private readonly Dictionary<int,int> targetOwners = [];
    private readonly HashSet<int> counted = [];
    private InputRule[] rules = [];
    public bool Enabled { get; private set; } = true;
    public bool MappingEnabled { get; private set; }
    public int HeldCount => physical.Count+seededVisible.Count;
    public int MappedHeldCount => active.Count;
    // Suppressed sources never reached Windows: B→C cannot retain A→B's B.
    private bool ForwardedPhysicalHolds(int key) => seededVisible.Contains(key)||physical.Any(p=>p.Value==key&&!active.ContainsKey(p.Key)&&!quarantined.Contains(p.Key));
    public void SeedVisibleKeys(IEnumerable<int> keys) {
        // Used only at hook startup or after SuspendSession, not inside a hook
        // callback and not on ordinary profile changes. Existing intercepted
        // sources must never acquire a fictitious visible owner.
        foreach(int key in keys) if(key>0&&key<=255&&!KeyboardKeys.IsDownOnly(key)&&!physical.ContainsValue(key))seededVisible.Add(key);
    }
    public KeyInjection[] Configure(bool enabled, bool mappingEnabled, IEnumerable<InputRule> next) {
        var releases = ReleaseMappings();
        Enabled=enabled; MappingEnabled=mappingEnabled;
        rules=next.Where(r=>r.Source>0&&r.Source<=255&&r.Target>0&&r.Target<=255)
            .DistinctBy(r=>(r.Source,r.Modifiers)).ToArray();
        return releases;
    }
    public KeyInjection[] ReleaseMappings() {
        var result = targetOwners.Keys.Where(k=>!ForwardedPhysicalHolds(k)).Select(k=>new KeyInjection(k,false)).ToArray();
        foreach(var key in active.Keys) quarantined.Add(key);
        active.Clear(); targetOwners.Clear();
        return result;
    }
    public KeyInjection[] InjectionFailed(int forwardedSource) {
        var releases=ReleaseMappings(); MappingEnabled=false;
        // This source's original down will be forwarded after SendInput fails;
        // its matching real up must therefore also pass through.
        quarantined.Remove(forwardedSource);
        return releases;
    }
    public KeyInjection[] SuspendSession() {
        var releases=ReleaseMappings(); physical.Clear(); counted.Clear(); quarantined.Clear(); seededVisible.Clear(); Enabled=false;
        return releases;
    }
    public RoutingDecision Process(KeyPacket packet) {
        if(packet.Injected) return RoutingDecision.Pass;
        if(!KeyboardKeys.IsDownOnly(packet.Key.VirtualKey))return ProcessEdge(packet);
        // Pause has no physical release on Windows. Close the mapping and sound
        // lifetime on the same hook callback, retaining the original suppression.
        if(!packet.Down)return RoutingDecision.Pass;
        var down=ProcessEdge(packet);
        var up=ProcessEdge(packet with { Down=false });
        return down with { SoundUp=up.SoundUp, Inject=up.Inject.Length==0?down.Inject:[..down.Inject,..up.Inject] };
    }
    private RoutingDecision ProcessEdge(KeyPacket packet) {
        int key=packet.Key.VirtualKey, id=packet.Key.Id;
        bool predatesHook=seededVisible.Remove(key);
        bool first=packet.Down ? physical.TryAdd(id,key) : physical.Remove(id);
        if(predatesHook)first=false;
        bool soundUp=!packet.Down && counted.Remove(id);
        if(quarantined.Contains(id)) {
            if(!packet.Down) quarantined.Remove(id);
            return new(false,false,soundUp,true,[]);
        }
        bool count=Enabled && packet.Down && first;
        if(count) counted.Add(id);
        if(!packet.Down && active.Remove(id,out var previous)) {
            if(IsHold(previous)) {
                int remaining=targetOwners[previous.Target]-1;
                if(remaining==0) targetOwners.Remove(previous.Target); else targetOwners[previous.Target]=remaining;
                return new(false,false,soundUp,true,remaining==0&&!ForwardedPhysicalHolds(previous.Target)?[new(previous.Target,false)]:[]);
            }
            return new(false,false,soundUp,true,[]);
        }
        // Preserve a synthetic hold when the same real target key is released.
        if(!packet.Down && targetOwners.ContainsKey(key)) return new(false,false,soundUp,true,[]);
        if(!Enabled || !MappingEnabled || !packet.Down) return new(count,count,soundUp,false,[]);
        if(active.TryGetValue(id,out var heldRule)) {
            return new(false,false,false,true,IsHold(heldRule)&&!KeyboardKeys.IsModifier(heldRule.Target)?[new(heldRule.Target,true)]:[]);
        }
        if(!first) return new(false,false,false,false,[]);
        KeyModifiers modifiers=KeyModifiers.None;
        foreach(int seeded in seededVisible)modifiers|=KeyboardKeys.Modifier(seeded);
        foreach(var pressed in physical) if(pressed.Key!=id&&!active.ContainsKey(pressed.Key)&&!quarantined.Contains(pressed.Key)) modifiers|=KeyboardKeys.Modifier(pressed.Value);
        foreach(int heldTarget in targetOwners.Keys) modifiers|=KeyboardKeys.Modifier(heldTarget);
        var rule=rules.FirstOrDefault(r=>r.Source==key && r.Modifiers==modifiers)
            ?? rules.FirstOrDefault(r=>r.Source==key && r.Modifiers==KeyModifiers.None);
        if(rule is null || (rule.Source==rule.Target && rule.Modifiers==rule.TargetModifiers)) return new(count,count,false,false,[]);
        active[id]=rule;
        if(IsHold(rule)) {
            int owners=targetOwners.GetValueOrDefault(rule.Target); targetOwners[rule.Target]=owners+1;
            return new(count,count,false,true,owners==0&&!ForwardedPhysicalHolds(rule.Target)?[new(rule.Target,true)]:[]);
        }
        return new(count,count,false,true,Shortcut(rule,id));
    }
    private static bool IsHold(InputRule rule) => rule.Modifiers==KeyModifiers.None && rule.TargetModifiers==KeyModifiers.None && !KeyboardKeys.IsOneShot(rule.Target);
    private KeyInjection[] Shortcut(InputRule rule,int sourceId) {
        var result=new List<KeyInjection>();
        // SendInput does not reset physical modifiers. Temporarily release those
        // not requested by this shortcut, then restore their exact left/right keys.
        var effective=physical.Where(p=>p.Key!=sourceId&&!active.ContainsKey(p.Key)&&!quarantined.Contains(p.Key)).Select(p=>p.Value).Concat(seededVisible).Concat(targetOwners.Keys).ToHashSet();
        var restore=effective.Where(k=>KeyboardKeys.IsModifier(k)&&!rule.TargetModifiers.HasFlag(KeyboardKeys.Modifier(k))).ToArray();
        foreach(int k in restore) result.Add(new(k,false));
        var added=new List<int>();
        foreach(var (modifier,k) in KeyboardKeys.CanonicalModifiers) {
            if(rule.TargetModifiers.HasFlag(modifier) && !effective.Any(p=>KeyboardKeys.Modifier(p)==modifier)) { result.Add(new(k,true)); added.Add(k); }
        }
        result.Add(new(rule.Target,true)); if(!effective.Contains(rule.Target)) result.Add(new(rule.Target,false));
        for(int i=added.Count-1;i>=0;i--) result.Add(new(added[i],false));
        foreach(int k in restore) result.Add(new(k,true));
        return result.ToArray();
    }
    public static InputRule[] MediaShortcuts => [
        new(0x4A,KeyModifiers.Control|KeyModifiers.Alt,0xB1),new(0x4B,KeyModifiers.Control|KeyModifiers.Alt,0xB3),
        new(0x4C,KeyModifiers.Control|KeyModifiers.Alt,0xB0),new(0x55,KeyModifiers.Control|KeyModifiers.Alt,0xAE),
        new(0x49,KeyModifiers.Control|KeyModifiers.Alt,0xAF),new(0x4D,KeyModifiers.Control|KeyModifiers.Alt,0xAD)
    ];
}
