import AVFoundation
import Foundation

protocol MusicPlayback: AnyObject {
    var duration:TimeInterval{get}
    var currentTime:TimeInterval{get set}
    var isPlaying:Bool{get}
    var volume:Float{get set}
    var failureMessage:String?{get}
    var statusMessage:String?{get}
    var interactionSnapshot:InteractionSnapshot{get}
    func prepare()->Bool
    func play()->Bool
    func pause()
    func stop()
    func measuredRMS()->Double
    func configureInteraction(track:MusicTrack)throws
    func activateAudio()throws
    func deactivateAudio()
    func setPerformance(volume:Double,sound:HitSound,decay:Double)
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int)
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int,decision:ContentChangePolicy.Decision)
    func release(key:UInt32,heldCount:Int)
    func releaseInteraction()
}
extension MusicPlayback {
    var failureMessage:String?{nil}
    var statusMessage:String?{nil}
    var interactionSnapshot:InteractionSnapshot{InteractionSnapshot()}
    func configureInteraction(track:MusicTrack)throws{}
    func activateAudio()throws{}
    func deactivateAudio(){}
    func setPerformance(volume:Double,sound:HitSound,decay:Double){}
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int){}
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int,decision:ContentChangePolicy.Decision){perform(key:key,note:note,velocity:velocity,richness:richness,heldCount:heldCount)}
    func release(key:UInt32,heldCount:Int){}
    func releaseInteraction(){}
}

/// Built-in songs use the complete-signal gesture graph. Imported recordings
/// retain the streaming native decoder and receive dynamics only.
final class NativeMusicPlayback:NSObject,MusicPlayback,AVAudioPlayerDelegate {
    private var player:AVAudioPlayer?
    private var graph:MusicPerformanceGraph?
    private let url:URL
    private let errorLock=NSLock()
    private var storedFailure:String?
    private var gain:Float=0.35
    private var depth=0.45,decay=0.5
    private var activity=0.0,level=0.0
    private var held=0
    private var importedAttacks:UInt64=0
    private var importedKeys=Set<UInt32>(),importedHoldKeys=Set<UInt32>()
    private var timer:Timer?
    private var active=false
    init(url:URL)throws{
        self.url=url;player=try AVAudioPlayer(contentsOf:url);super.init()
        player?.numberOfLoops = -1;player?.isMeteringEnabled=true;player?.delegate=self
    }
    deinit{timer?.invalidate();graph?.stop();player?.stop()}
    var duration:Double{graph?.duration ?? player?.duration ?? 0}
    var currentTime:Double{get{graph?.currentTime ?? player?.currentTime ?? 0}set{if let graph{graph.currentTime=newValue}else{player?.currentTime=newValue}}}
    var isPlaying:Bool{graph?.isPlaying ?? player?.isPlaying ?? false}
    var volume:Float{get{gain}set{gain=newValue;graph?.musicGain=newValue;updateImportedGain()}}
    var effectiveMusicGain:Float{graph?.musicGain ?? player?.volume ?? gain}
    var failureMessage:String?{errorLock.lock();defer{errorLock.unlock()};return graph?.failureMessage ?? storedFailure}
    var interactionSnapshot:InteractionSnapshot{
        if let graph{return graph.snapshot}
        return InteractionSnapshot(level:level*depth,performedRMS:0,outputRMS:measuredRMS(),voices:0,buffers:0,nonSilentBuffers:0,attacks:importedAttacks)
    }
    func configureInteraction(track:MusicTrack)throws{
        guard track.isBuiltIn,MusicLibrary.builtInTracks.contains(where:{$0.id==track.id}) else{return}
        let rich=url.deletingLastPathComponent().appendingPathComponent("keywoo-\(track.id)-rich.wav")
        graph=try MusicPerformanceGraph(baseURL:url,richURL:rich)
        graph?.musicGain=gain;player?.stop();player=nil
    }
    func prepare()->Bool{graph != nil || player?.prepareToPlay()==true}
    func activateAudio()throws{
        active=true
        if let graph{try graph.activate()}
        else if timer==nil{
            let t=Timer(timeInterval:0.01,repeats:true){[weak self] _ in self?.advanceImportedEffect()}
            RunLoop.main.add(t,forMode:.common);timer=t
        }
    }
    func deactivateAudio(){active=false;releaseInteraction();level=0;updateImportedGain();graph?.deactivate();timer?.invalidate();timer=nil}
    func play()->Bool{
        let started:Bool
        if let graph{started=graph.play()}else{started=player?.play() ?? false}
        if started{errorLock.lock();storedFailure=nil;errorLock.unlock()};return started
    }
    func pause(){if let graph{graph.pause()}else{player?.pause();releaseInteraction();level=0;updateImportedGain()}}
    func stop(){active=false;graph?.stop();player?.stop();timer?.invalidate();timer=nil}
    func setPerformance(volume:Double,sound:HitSound,decay:Double){
        depth=min(1,max(0,volume));self.decay=decay
        graph?.setPerformanceVolume(depth);graph?.setSound(sound);graph?.setDecay(decay);updateImportedGain()
    }
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int){
        guard isPlaying else{return}
        if let graph{graph.noteOn(key:key,note:note ?? 60,velocity:velocity,richness:richness,decay:decay,heldCount:heldCount)}
        else{activity=1;held=heldCount;importedAttacks &+= 1}
    }
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int,decision:ContentChangePolicy.Decision){
        guard isPlaying,decision.feedbackWeight>0,decision.action != .none else{return}
        if let graph{graph.noteOn(key:key,note:note ?? 60,velocity:velocity,richness:richness,decay:decay,heldCount:heldCount,feedbackWeight:decision.feedbackWeight,action:decision.action,duration:decision.duration)}
        else{
            guard importedKeys.insert(key).inserted else{return}
            if decision.action == .hold{importedHoldKeys.insert(key)}
            activity=max(activity,decision.feedbackWeight);held=importedHoldKeys.count;importedAttacks &+= 1
        }
    }
    func release(key:UInt32,heldCount:Int){if let graph{graph.noteOff(key:key,heldCount:heldCount)}else{importedKeys.remove(key);importedHoldKeys.remove(key);held=importedHoldKeys.count}}
    func releaseInteraction(){graph?.releaseAll();activity=0;held=0;importedKeys.removeAll(keepingCapacity:true);importedHoldKeys.removeAll(keepingCapacity:true)}
    private func advanceImportedEffect(){
        guard active else{return}
        activity *= exp(-0.01/(0.20+min(1,max(0,decay))*1.2))
        let target=max(activity,held>0 ? 0.52:0)
        level += (target-level)*(1-exp(-0.01/(target>level ? 0.025:0.12+min(1,max(0,decay))*0.8)))
        updateImportedGain()
    }
    private func updateImportedGain(){player?.volume=gain*Float(1-depth*0.35*(1-level))}
    func measuredRMS()->Double{
        if let graph{return graph.measuredMusicRMS}
        guard let player,player.isPlaying,player.volume>0 else{return 0}
        player.updateMeters();let channels=max(1,player.numberOfChannels)
        var energy=0.0
        for channel in 0..<channels{energy += pow(10,Double(player.averagePower(forChannel:channel))/10)}
        return sqrt(energy/Double(channels))*Double(player.volume)
    }
    func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?){errorLock.lock();storedFailure=error?.localizedDescription ?? "音频文件解码失败。";errorLock.unlock();DispatchQueue.main.async{[weak self] in self?.player?.stop()}}
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool){guard !flag else{return};errorLock.lock();storedFailure="音频设备或文件无法继续播放。";errorLock.unlock()}
}
