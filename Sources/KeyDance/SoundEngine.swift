import AVFoundation
import Combine
import Foundation

/// Music-fader headroom and the retained v2 percussion-renderer ceiling.
/// The interactive graph additionally limits the complete combined output.
enum AudioMixSafety {
    static func musicGain(for level: Double) -> Double {
        guard level.isFinite else { return 0 }
        let value = min(1, max(0, level))
        return value <= 0.5 ? value : 0.5 + 0.18 * tanh((value - 0.5) / 0.18)
    }

    @inline(__always) static func limitHit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > 0.20 else { return sample }
        let limited = Float(0.20 - 0.08 * expm1(-Double(magnitude - 0.20) / 0.08))
        return sample < 0 ? -limited : limited
    }
}

enum HitSound: String, CaseIterable, Identifiable {
    case softTap, wood, lowDrum
    var id: String { rawValue }
    var title: String {
        switch self { case .softTap: return L("柔和推盘"); case .wood: return L("通透扫频"); case .lowDrum: return L("弹性律动") }
    }
    var subtitle: String {
        switch self {
        case .softTap: return L("大键轻推整段音乐，动作随输入节奏收放")
        case .wood: return L("用大键打开整曲明暗，长按 Shift 保持展开")
        case .lowDrum: return L("跟随你的敲击速度，轻巧切分与回弹")
        }
    }
    var symbol: String {
        switch self { case .softTap: return "hand.tap"; case .wood: return "circle.dotted"; case .lowDrum: return "circle.circle" }
    }
}

/// Compatibility for saved v1/v2 preferences. Current live cases select
/// sampled musical instruments; the legacy offline renderer is kept for QA.
enum SoundStyle: String, CaseIterable, Identifiable {
    case felt, glass, pulse
    var id: String { rawValue }
    var hitSound: HitSound { switch self { case .felt: return .wood; case .glass: return .softTap; case .pulse: return .lowDrum } }
    init(_ hit: HitSound) { switch hit { case .wood: self = .felt; case .softTap: self = .glass; case .lowDrum: self = .pulse } }
    var title: String { hitSound.title }
    var subtitle: String { hitSound.subtitle }
    var symbol: String { hitSound.symbol }
}

private struct HitMeter {
    var rms: Double = 0
    var voices = 0
    var maximumVoices = 0
    var buffers: UInt64 = 0
    var nonSilentBuffers: UInt64 = 0
    var attacks: UInt64 = 0
}

/// Immediate percussion only. Twelve short transient voices and one quiet
/// continuous hold texture are bounded independently from the music player.
/// No timers generate attacks; every attack has a physical or preview event.
private final class HitRenderState: @unchecked Sendable {
    private let sampleRate: Double
    private let holdAttackSmoothing: Float
    private let holdReleaseSmoothing: Float
    private let volumeSmoothing: Float
    private let table: [Float]
    private let lock = NSLock()
    private let meterLock = NSLock()
    private var queue = Array(repeating: Command(), count: 128)
    private var read = 0; private var write = 0; private var queued = 0
    private var desiredVolume: Float = 0.50
    private var volumeTarget: Float = 0.50
    private var volume: Float = 0
    private var voices = Array(repeating: Voice(), count: 12)
    private var hold = Hold()
    private var published = HitMeter()
    private var meterState = HitMeter()
    private struct Voice {
        var active = false
        var sound = HitSound.wood
        var age = 0
        var remaining = 0
        var total = 0
        var phase: Double = 0
        var overtonePhase: Double = 0
        var step: Double = 0
        var bend: Double = 0
        var bendStep: Double = 1
        var envelope: Float = 0
        var envelopeStep: Float = 1
        var random: UInt32 = 0x9e3779b9
        var noise: Float = 0
        var transient: Float = 1
        var transientStep: Float = 1
        var forcedRelease = 0
        var releaseTotal = 1
    }
    private struct Hold {
        var active = false
        var sound = HitSound.wood
        var phase: Double = 0
        var phase2: Double = 0
        var step: Double = 0
        var age = 0
        var amplitude: Float = 0
        var target: Float = 0
        var released = false
        var forcedReleaseRemaining = 0
        var forcedReleaseTotal = 1
        var random: UInt32 = 0x673ac902
        var noise: Float = 0
    }
    private struct Command {
        var kind = 0 // 1 hit, 2 begin hold, 3 end hold, 4 release all
        var voice = Voice()
        var sound = HitSound.wood
    }
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        holdAttackSmoothing = Float(1-exp(-1/(sampleRate*0.035)))
        holdReleaseSmoothing = Float(1-exp(-1/(sampleRate*0.012)))
        volumeSmoothing = Float(1-exp(-1/(sampleRate*0.008)))
        table = (0..<4096).map { Float(sin(Double($0) * 2 * .pi / 4096)) }
    }
    func setVolume(_ value: Double) { lock.lock(); desiredVolume = Float(min(1,max(0,value))); lock.unlock() }
    func hit(sound: HitSound, gain: Float, decay: Double, seed: UInt32) {
        let d = min(1,max(0,decay))
        let tau: Double
        let frequency: Double
        switch sound {
        case .softTap: tau = 0.020 + d * 0.020; frequency = 310
        case .wood: tau = 0.028 + d * 0.034; frequency = 395
        case .lowDrum: tau = 0.065 + d * 0.065; frequency = 60
        }
        var voice = Voice()
        voice.active = true; voice.sound = sound
        voice.remaining = Int(sampleRate * tau * 6); voice.total = voice.remaining
        voice.step = frequency / sampleRate
        voice.bend = sound == .lowDrum ? voice.step * 1.15 : voice.step * 0.05
        voice.bendStep = exp(-1 / (sampleRate * (sound == .lowDrum ? 0.022 : 0.006)))
        voice.envelope = gain
        voice.envelopeStep = Float(exp(-1 / (sampleRate * tau)))
        voice.transientStep = Float(exp(-1 / (sampleRate * 0.009)))
        voice.random = 0x9e3779b9 &+ seed &* 1_103_515_245
        enqueue(Command(kind:1,voice:voice,sound:sound))
    }
    func beginHold(sound: HitSound) { enqueue(Command(kind:2,sound:sound)) }
    func endHold() { enqueue(Command(kind:3)) }
    func releaseAll() { enqueue(Command(kind:4),clear:true) }
    private func enqueue(_ command: Command, clear: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if clear { read = write; queued = 0 }
        if queued == queue.count { read = (read+1)%queue.count; queued -= 1 }
        queue[write] = command; write = (write+1)%queue.count; queued += 1
    }
    func meter() -> HitMeter { meterLock.lock(); defer { meterLock.unlock() }; return published }
    @inline(__always) private func sine(_ phase: Double) -> Float {
        let p = (phase-floor(phase))*4096; let i = Int(p); let t = Float(p-Double(i))
        return table[i&4095]*(1-t)+table[(i+1)&4095]*t
    }
    @inline(__always) private func random(_ seed: inout UInt32) -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed)/Float(UInt32.max)*2-1
    }
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if lock.try() {
            volumeTarget = desiredVolume
            while queued > 0 {
                let command = queue[read]
                switch command.kind {
                case 1:
                    let slot = voices.firstIndex(where: { !$0.active }) ?? voices.indices.min(by: { voices[$0].envelope < voices[$1].envelope }) ?? 0
                    voices[slot] = command.voice; meterState.attacks &+= 1
                case 2:
                    if !hold.active || hold.released {
                        hold = Hold(); hold.active = true; hold.sound = command.sound
                        hold.step = (command.sound == .lowDrum ? 65.406 : command.sound == .wood ? 164.814 : 130.813)/sampleRate
                    }
                case 3: hold.released = true; hold.target = 0
                case 4:
                    for i in voices.indices where voices[i].active {
                        voices[i].forcedRelease = Int(sampleRate*0.018); voices[i].releaseTotal = voices[i].forcedRelease
                    }
                    hold.released = true; hold.target = 0
                    hold.forcedReleaseRemaining = Int(sampleRate*0.018); hold.forcedReleaseTotal = hold.forcedReleaseRemaining
                default: break
                }
                read=(read+1)%queue.count; queued -= 1
            }
            lock.unlock()
        }
        left.update(repeating:0,count:frames); right.update(repeating:0,count:frames)
        for index in voices.indices where voices[index].active {
            var voice = voices[index]
            for frame in 0..<min(frames,voice.remaining) {
                if voice.forcedRelease == 1 { voice.active = false; break }
                let t = min(1,Float(voice.age)/Float(sampleRate*0.0018))
                let attack = t*t*(3-2*t)
                let n = random(&voice.random)
                voice.noise += (n-voice.noise)*(voice.sound == .softTap ? 0.12 : 0.20)
                let signal: Float
                switch voice.sound {
                case .softTap: signal = voice.noise*0.62 + sine(voice.phase)*0.30
                case .wood: signal = sine(voice.phase)*0.70 + sine(voice.overtonePhase)*voice.transient*0.16 + voice.noise*voice.transient*0.22
                case .lowDrum: signal = sine(voice.phase)*0.96 + voice.noise*voice.transient*0.08
                }
                let release = voice.forcedRelease > 0 ? Float(voice.forcedRelease)/Float(voice.releaseTotal) : min(1,Float(voice.remaining)/Float(sampleRate*0.008))
                let sample = signal*voice.envelope*attack*release
                left[frame] += sample*0.7071068; right[frame] += sample*0.7071068
                voice.phase += voice.step+voice.bend; voice.phase -= floor(voice.phase)
                voice.overtonePhase += (voice.step+voice.bend)*2.37; voice.overtonePhase -= floor(voice.overtonePhase)
                voice.bend *= voice.bendStep; voice.envelope *= voice.envelopeStep; voice.transient *= voice.transientStep
                voice.remaining -= 1; voice.age += 1
                if voice.forcedRelease > 0 { voice.forcedRelease -= 1 }
            }
            if voice.remaining <= 0 { voice.active = false }
            voices[index] = voice
        }
        var energy = 0.0
        for frame in 0..<frames {
            if hold.active {
                if !hold.released && hold.age >= Int(sampleRate*0.12) { hold.target = 0.050 }
                hold.amplitude += (hold.target-hold.amplitude)*(hold.released ? holdReleaseSmoothing : holdAttackSmoothing)
                hold.noise += (random(&hold.random)-hold.noise)*0.015
                let release = hold.forcedReleaseRemaining>0 ? Float(hold.forcedReleaseRemaining)/Float(hold.forcedReleaseTotal):1
                let texture = (sine(hold.phase)*0.76 + sine(hold.phase2)*0.16 + hold.noise*0.12)*hold.amplitude*release
                left[frame] += texture*0.7071068; right[frame] += texture*0.7071068
                hold.phase += hold.step; hold.phase -= floor(hold.phase)
                hold.phase2 += hold.step*1.0017; hold.phase2 -= floor(hold.phase2)
                hold.age += 1
                if hold.forcedReleaseRemaining>0 {
                    hold.forcedReleaseRemaining -= 1
                    if hold.forcedReleaseRemaining==0 { hold.active=false }
                }
                if hold.released && hold.amplitude < 0.00001 { hold.active = false }
            }
            volume += (volumeTarget-volume)*volumeSmoothing
            let l=left[frame]*volume; let r=right[frame]*volume
            left[frame]=AudioMixSafety.limitHit(l/(1+abs(l)*0.6))
            right[frame]=AudioMixSafety.limitHit(r/(1+abs(r)*0.6))
            energy += Double(left[frame]*left[frame]+right[frame]*right[frame])
        }
        meterState.rms=sqrt(energy/Double(max(1,frames*2)))
        var liveVoices = hold.active ? 1 : 0
        for voice in voices where voice.active { liveVoices += 1 }
        meterState.voices=liveVoices
        meterState.maximumVoices=max(meterState.maximumVoices,meterState.voices)
        meterState.buffers &+= 1
        if meterState.rms>0.00001 { meterState.nonSilentBuffers &+= 1 }
        if meterLock.try() { published=meterState; meterLock.unlock() }
    }
}

@MainActor
final class SoundEngine: ObservableObject {
    @Published var errorMessage:String?
    @Published private(set) var outputLevel=0.0
    @Published private(set) var activeVoiceCount=0
    @Published private(set) var heldKeyCount=0
    private(set) var renderedBufferCount:UInt64=0
    private(set) var nonSilentBufferCount:UInt64=0
    private(set) var renderedAttackCount:UInt64=0
    @Published private(set) var currentTrack=MusicLibrary.builtInTracks[0]
    @Published private(set) var isMusicPlaying=false
    @Published private(set) var isMusicLoading=false
    @Published private(set) var musicCurrentTime:TimeInterval=0
    @Published private(set) var musicDuration:TimeInterval=MusicLibrary.builtInTracks[0].duration
    @Published private(set) var musicProgress=0.0
    @Published private(set) var musicOutputLevel=0.0
    @Published private(set) var musicErrorMessage:String?
    @Published private(set) var musicStatusMessage:String?
    @Published private(set) var interactionLevel=0.0
    @Published private(set) var currentHarmony="Dm9"
    @Published private(set) var isInteractiveBuiltIn=true
    var hitVolume=0.45 {didSet{updatePerformance()}}
    var musicVolume=0.48 {didSet{musicPlayer?.volume=Float(AudioMixSafety.musicGain(for:musicVolume))}}
    var hitSound=HitSound.softTap {didSet{if oldValue != hitSound{releaseAll();updatePerformance()}}}
    var decay=0.5 {didSet{updatePerformance()}}
    var harmonyEnabled=true
    var volume:Double{get{hitVolume}set{hitVolume=newValue}}
    var style:SoundStyle{get{SoundStyle(hitSound)}set{hitSound=newValue.hitSound}}
    private(set) var isEnabled=false
    private var held=Set<UInt16>()
    private var observedPhysical=Set<UInt16>()
    private var director=MelodyDirector()
    private var previewDirector=MelodyDirector()
    private var contentPolicy=ContentChangePolicy()
    private var timer:Timer?
    private var previewTask:Task<Void,Never>?
    private var oneShotTasks:[UInt32:Task<Void,Never>]=[:]
    private var previewSerial:UInt32=65_536
    private var musicPlayer:MusicPlayback?
    private let musicFactory:(URL)throws->MusicPlayback
    private let audioDeviceEnabled:Bool
    init(audioDeviceEnabled:Bool=true,musicFactory:@escaping(URL)throws->MusicPlayback={try MusicPlaybackFactory.make(url:$0)}){self.audioDeviceEnabled=audioDeviceEnabled;self.musicFactory=musicFactory}
    deinit{timer?.invalidate();musicPlayer?.stop()}
    private func updatePerformance(){musicPlayer?.setPerformance(volume:hitVolume,sound:hitSound,decay:decay)}
    func start(resumeMusic:Bool=true){
        isEnabled=true
        if musicPlayer==nil{_ = selectTrack(currentTrack,autoplay:false)}
        if audioDeviceEnabled{do{try musicPlayer?.activateAudio();errorMessage=nil}catch{errorMessage=Lf("互动声音启动失败：%@", L(error.localizedDescription))}}
        if resumeMusic{playMusic()}else{pauseMusic()}
        if timer==nil{let t=Timer(timeInterval:0.20,repeats:true){[weak self] _ in Task{@MainActor [weak self] in self?.refreshMeters()}};RunLoop.main.add(t,forMode:.common);timer=t}
    }
    private func refreshMeters(){
        let snapshot=musicPlayer?.interactionSnapshot ?? InteractionSnapshot()
        if abs(outputLevel-snapshot.performedRMS)>0.0001{outputLevel=snapshot.performedRMS}
        if activeVoiceCount != snapshot.voices{activeVoiceCount=snapshot.voices}
        if abs(interactionLevel-snapshot.level)>0.002{interactionLevel=snapshot.level}
        renderedBufferCount=snapshot.buffers;nonSilentBufferCount=snapshot.nonSilentBuffers;renderedAttackCount=snapshot.attacks
        refreshTransport()
    }
    private func refreshHarmony(){
        let value=currentTrack.isGenerative ? L("AI 乐句"):(isInteractiveBuiltIn ? MusicInteraction.harmony(trackID:currentTrack.id,time:musicPlayer?.currentTime ?? 0).name:L("原曲动态"))
        if currentHarmony != value{currentHarmony=value}
    }
    private func refreshTransport(){
        let playing=musicPlayer?.isPlaying ?? false,time=musicPlayer?.currentTime ?? 0,level=musicPlayer?.measuredRMS() ?? 0
        let progress=musicDuration>0 ? min(1,max(0,time/musicDuration)):0
        if isMusicPlaying != playing{isMusicPlaying=playing}
        if abs(musicCurrentTime-time)>0.01{musicCurrentTime=time}
        if abs(musicProgress-progress)>0.0001{musicProgress=progress}
        if abs(musicOutputLevel-level)>0.0001{musicOutputLevel=level}
        if let failure=musicPlayer?.failureMessage{let message=Lf("音乐播放中断：%@", L(failure));if musicErrorMessage != message{musicErrorMessage=message}}
        if musicStatusMessage != musicPlayer?.statusMessage { musicStatusMessage = musicPlayer?.statusMessage }
        refreshHarmony()
    }
    @discardableResult func selectTrack(_ track:MusicTrack,autoplay:Bool=true)->Bool{
        guard let url=MusicLibrary.url(for:track) else{musicErrorMessage=L("找不到这首音乐，请重新选择文件。");return false}
        isMusicLoading=true;defer{isMusicLoading=false}
        do{
            let next=try musicFactory(url)
            try next.configureInteraction(track:track)
            guard next.duration.isFinite,(next.duration>0 || track.isGenerative),next.prepare() else{throw NSError(domain:"KeyWooMusic",code:1,userInfo:[NSLocalizedDescriptionKey:L("文件没有可播放的音频。")])}
            next.volume=Float(AudioMixSafety.musicGain(for:musicVolume));next.setPerformance(volume:hitVolume,sound:hitSound,decay:decay)
            if isEnabled && audioDeviceEnabled{try next.activateAudio()}
            if autoplay && isEnabled && !next.play(){throw NSError(domain:"KeyWooMusic",code:2,userInfo:[NSLocalizedDescriptionKey:L("播放器无法开始播放。")])}
            releaseAll()
            let old=musicPlayer;musicPlayer=next;old?.stop()
            var chosen=track;chosen.duration=next.duration;currentTrack=chosen;musicDuration=next.duration
            isInteractiveBuiltIn=track.isGenerative || (track.isBuiltIn && MusicLibrary.builtInTracks.contains{$0.id==track.id})
            musicErrorMessage=nil;refreshTransport();return true
        }catch{musicErrorMessage=Lf("无法打开音乐：%@", L(error.localizedDescription));return false}
    }
    @discardableResult func loadMusic(url:URL,title:String?=nil,autoplay:Bool=true)->Bool{selectTrack(MusicTrack(id:"local:"+url.standardizedFileURL.path,title:title ?? url.deletingPathExtension().lastPathComponent,subtitle:L("本地音乐"),url:url),autoplay:autoplay)}
    func playMusic(){guard isEnabled else{return};if musicPlayer==nil && !selectTrack(currentTrack,autoplay:false){return};if musicPlayer?.isPlaying==true || musicPlayer?.play()==true{musicErrorMessage=nil}else{musicErrorMessage=L("音乐暂时无法播放，请检查音频输出。")};refreshTransport()}
    func pauseMusic(){musicPlayer?.pause();refreshTransport()}
    func toggleMusic(){isMusicPlaying ? pauseMusic():playMusic()}
    func seekMusic(to time:TimeInterval){guard time.isFinite,let player=musicPlayer else{return};releaseAll();player.currentTime=min(max(0,time),max(0,player.duration-0.001));refreshTransport()}
    private func perform(key:UInt32,timestamp:Double,decision:ContentChangePolicy.Decision,preview:Bool=false)->String{
        let gesture:(note:Int,velocity:UInt8,richness:Double)
        if !currentTrack.isGenerative || decision.shouldChangeContent {
            // AI has no fixed-song chord timeline. Use a compact melodic cue
            // palette; keys without a cue do not silently advance the phrase.
            let harmony=currentTrack.isGenerative ? MusicalHarmony(name:L("AI 乐句"),notes:[60,62,64,67,69,72],bar:0):MusicInteraction.harmony(trackID:currentTrack.id,time:musicPlayer?.currentTime ?? 0)
            gesture=preview ? previewDirector.next(harmony:harmony,timestamp:timestamp):director.next(harmony:harmony,timestamp:timestamp)
        }else{gesture=(64,62,0.30)}
        refreshHarmony()
        // Only an explicit wide-key gesture reaches playback. Ordinary typing
        // informs the cadence policy without touching the music or held state.
        musicPlayer?.perform(key:key,note:currentTrack.isGenerative && decision.shouldChangeContent ? UInt8(gesture.note):nil,velocity:gesture.velocity,richness:gesture.richness,heldCount:held.count,decision:decision)
        guard musicPlayer?.isPlaying == true else { return L("等待播放") }
        if currentTrack.isGenerative && decision.shouldChangeContent { return L("换句") }
        switch decision.action {
        case .none:return L("仅统计")
        case .push:return L("推盘")
        case .pull:return L("回拨")
        case .sweep:return L("扫频")
        case .lift:return L("抬起")
        case .hold:return L("展开")
        }
    }
    @discardableResult func noteOn(keyCode:UInt16,timestamp:TimeInterval=ProcessInfo.processInfo.systemUptime)->String{
        guard isEnabled else{return "—"}
        guard observedPhysical.insert(keyCode).inserted else{return currentHarmony}
        let decision=contentPolicy.receive(keyCode:keyCode,timestamp:timestamp)
        guard KeyGestureRole.isPerformanceKey(keyCode),decision.feedbackWeight>0 else{return L("仅统计")}
        cancelPreview();held.insert(keyCode)
        heldKeyCount=held.count
        return perform(key:UInt32(keyCode),timestamp:timestamp,decision:decision)
    }
    func noteOff(keyCode:UInt16){observedPhysical.remove(keyCode);guard held.remove(keyCode) != nil else{return};heldKeyCount=held.count;musicPlayer?.release(key:UInt32(keyCode),heldCount:held.count)}
    @discardableResult func trigger(keyCode:UInt16,timestamp:TimeInterval=ProcessInfo.processInfo.systemUptime)->String{
        guard isEnabled else{return "—"}
        guard KeyGestureRole.isPerformanceKey(keyCode) else{return L("仅大键响应")}
        previewSerial &+= 1;let key=previewSerial
        let label=perform(key:key,timestamp:timestamp,decision:.preview(keyCode:keyCode),preview:true)
        oneShotTasks[key]=Task{@MainActor [weak self] in try? await Task.sleep(nanoseconds:120_000_000);guard !Task.isCancelled,let self else{return};self.musicPlayer?.release(key:key,heldCount:self.held.count);self.oneShotTasks[key]=nil}
        return label
    }
    func cancelPreview(){previewTask?.cancel();previewTask=nil;for (key,task) in oneShotTasks{task.cancel();musicPlayer?.release(key:key,heldCount:held.count)};oneShotTasks.removeAll();previewDirector.reset()}
    func releaseAll(){cancelPreview();for task in oneShotTasks.values{task.cancel()};oneShotTasks.removeAll();held.removeAll(keepingCapacity:true);observedPhysical.removeAll(keepingCapacity:true);if heldKeyCount != 0{heldKeyCount=0};musicPlayer?.releaseInteraction();director.reset();contentPolicy.reset()}
    func stop(){isEnabled=false;pauseMusic();releaseAll();musicPlayer?.deactivateAudio();if outputLevel != 0{outputLevel=0};if interactionLevel != 0{interactionLevel=0}}
    func preview(){guard isEnabled else{return};cancelPreview();previewTask=Task{@MainActor [weak self] in for (code,gap):(UInt16,Double) in [(49,0.32),(48,0.38),(51,0.55),(36,0.48),(56,0.36)]{guard !Task.isCancelled,let self else{return};_ = self.trigger(keyCode:code);try? await Task.sleep(nanoseconds:UInt64(gap*1_000_000_000))};self?.previewTask=nil}}
}

/// Historical v2 percussion fixtures only. Live interaction now uses
/// MusicPerformanceGraph, tested by EnsembleOfflineRenderer.
enum OfflineSoundRenderer {
    enum Action { case strike,keyDown,keyUp,releaseAll }
    struct Event { let time:Double; let keyCode:UInt16; var action:Action = .strike }
    struct Output { let samples:[Float]; let maximumVoices:Int; let nonSilentBuffers:UInt64; let attackCount:UInt64 }
    static func render(events:[Event],style:SoundStyle = .felt,decay:Double = 0.5,volume:Double = 0.5,duration:Double,sampleRate:Double = 44_100) -> [Float] {
        renderPerformance(events:events,style:style,decay:decay,volume:volume,duration:duration,sampleRate:sampleRate).samples
    }
    static func renderPerformance(events:[Event],style:SoundStyle = .felt,decay:Double = 0.5,volume:Double = 0.5,duration:Double,sampleRate:Double = 44_100) -> Output {
        let state=HitRenderState(sampleRate:sampleRate); state.setVolume(volume)
        let ordered=events.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset<$1.offset:$0.element.time<$1.element.time }.map(\.element)
        var output=Array(repeating:Float(0),count:max(0,Int(duration*sampleRate))*2)
        var l=Array(repeating:Float(0),count:128); var r=l
        var held=Set<UInt16>(); var eventIndex=0; var frame=0; var attacks:UInt32=0
        var last:Double?; var interval=0.2
        func fire(_ time:Double) {
            if let last { let delta=max(0.008,min(1,time-last)); interval=delta>0.6 ? 0.2:interval*0.7+delta*0.3 }
            last=time; attacks &+= 1
            let density=min(1,max(0,(0.16-interval)/0.12))
            state.hit(sound:style.hitSound,gain:Float(0.55-density*0.19),decay:decay,seed:attacks)
        }
        while frame<output.count/2 {
            while eventIndex<ordered.count && Int(ordered[eventIndex].time*sampleRate)<=frame {
                let event=ordered[eventIndex]
                switch event.action {
                case .strike: fire(event.time)
                case .keyDown:
                    if held.insert(event.keyCode).inserted { fire(event.time); if held.count==1 { state.beginHold(sound:style.hitSound) } }
                case .keyUp: if held.remove(event.keyCode) != nil && held.isEmpty { state.endHold() }
                case .releaseAll: held.removeAll(); state.releaseAll(); last=nil; interval=0.2
                }
                eventIndex += 1
            }
            let next=eventIndex<ordered.count ? Int(ordered[eventIndex].time*sampleRate):output.count/2
            let count=min(128,output.count/2-frame,max(1,next-frame))
            l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in state.render(frames:count,left:a.baseAddress!,right:b.baseAddress!) } }
            for i in 0..<count { output[(frame+i)*2]=l[i]; output[(frame+i)*2+1]=r[i] }
            frame += count
        }
        let meter=state.meter()
        return Output(samples:output,maximumVoices:meter.maximumVoices,nonSilentBuffers:meter.nonSilentBuffers,attackCount:meter.attacks)
    }
    static func writeWAV(to url:URL,samples:[Float],sampleRate:Double = 44_100) throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:2)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(samples.count/2))!; buffer.frameLength=buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i]=samples[i*2]; buffer.floatChannelData![1][i]=samples[i*2+1] }
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:sampleRate,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
        let file=try AVAudioFile(forWriting:url,settings:settings); try file.write(from:buffer)
    }
    @discardableResult static func writeDemos(to directory:URL) throws -> [URL] {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let times=[0.2,0.5,0.72,0.94,1.38,1.55,1.73,2.0,2.5,2.65,2.9,3.3]
        let events=times.enumerated().map { Event(time:$0.element,keyCode:UInt16($0.offset)) }
        var urls:[URL]=[]
        for style in SoundStyle.allCases {
            let url=directory.appendingPathComponent("keywoo-\(style.hitSound.rawValue).wav")
            try writeWAV(to:url,samples:render(events:events,style:style,duration:4.5)); urls.append(url)
            let held=directory.appendingPathComponent("keywoo-held-\(style.hitSound.rawValue).wav")
            try writeWAV(to:held,samples:render(events:[.init(time:0.2,keyCode:0,action:.keyDown),.init(time:6.2,keyCode:0,action:.keyUp)],style:style,duration:7)); urls.append(held)
        }
        return urls
    }
}
