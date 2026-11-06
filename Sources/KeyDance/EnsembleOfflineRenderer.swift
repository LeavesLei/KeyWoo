import Foundation

enum EnsembleOfflineRenderer {
    enum Action {case down,up,reset,pause,resume}
    struct Event {let time:Double;let keyCode:UInt16;let action:Action}
    struct NoteTrace:Codable {let time:Double;let playhead:Double;let harmony:String;let note:Int;let velocity:UInt8;let richness:Double}
    struct Output {let samples:[Float];let notes:[NoteTrace];let finalPlayhead:Double;let maximumLevel:Double;let sampleRate:Double}
    static func render(track:MusicTrack,events:[Event],duration:Double,musicVolume:Double=0.48,performanceVolume:Double=0.45,sound:HitSound = .softTap,decay:Double=0.5,mutedLead:Bool=false)throws->Output{
        guard let base=MusicLibrary.url(for:track) else{throw NSError(domain:"KeyWooOffline",code:1)}
        let rich=base.deletingLastPathComponent().appendingPathComponent("keywoo-\(track.id)-rich.wav")
        let graph=try MusicPerformanceGraph(baseURL:base,richURL:rich)
        graph.musicGain=Float(AudioMixSafety.musicGain(for:musicVolume));graph.setPerformanceVolume(performanceVolume);graph.setSound(sound);graph.setDecay(decay)
        graph.leadMutedForVerification=mutedLead
        try graph.beginOffline();defer{graph.stop()}
        let rate=44_100.0,total=Int(duration*rate)
        let ordered=events.enumerated().sorted{$0.element.time == $1.element.time ? $0.offset<$1.offset:$0.element.time<$1.element.time}.map(\.element)
        var index=0,frame=0,held=Set<UInt16>(),director=MelodyDirector(),trace:[NoteTrace]=[],samples:[Float]=[],maximumLevel=0.0
        samples.reserveCapacity(total*2)
        while frame<total{
            while index<ordered.count && Int(ordered[index].time*rate)<=frame{
                let event=ordered[index]
                switch event.action{
                case .down:
                    if held.insert(event.keyCode).inserted{
                        let position=graph.currentTime,harmony=MusicInteraction.harmony(trackID:track.id,time:position)
                        let gesture=director.next(harmony:harmony,timestamp:event.time)
                        graph.noteOn(key:UInt32(event.keyCode),note:UInt8(gesture.note),velocity:gesture.velocity,richness:gesture.richness,decay:decay,heldCount:held.count)
                        trace.append(.init(time:event.time,playhead:position,harmony:harmony.name,note:gesture.note,velocity:gesture.velocity,richness:gesture.richness))
                    }
                case .up:
                    if held.remove(event.keyCode) != nil{graph.noteOff(key:UInt32(event.keyCode),heldCount:held.count)}
                case .reset:held.removeAll();director.reset();graph.releaseAll()
                case .pause:graph.pause()
                case .resume:_=graph.play()
                }
                index += 1
            }
            let next=index<ordered.count ? Int(ordered[index].time*rate):total
            let count=min(128,total-frame,max(1,next-frame))
            samples += try graph.renderOffline(frames:count)
            maximumLevel=max(maximumLevel,graph.snapshot.level)
            frame += count
        }
        return Output(samples:samples,notes:trace,finalPlayhead:graph.currentTime,maximumLevel:maximumLevel,sampleRate:rate)
    }
}
