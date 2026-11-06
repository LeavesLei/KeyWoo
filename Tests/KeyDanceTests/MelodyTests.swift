import AVFoundation
import Foundation
import Testing
@testable import KeyDance

private final class TestMusicPlayer: MusicPlayback {
    var duration: TimeInterval = 100
    var currentTime: TimeInterval = 0 { didSet { seekCount += 1 } }
    var isPlaying = false
    var volume: Float = 0.35
    var prepareSucceeds = true
    var playSucceeds = true
    var playCount = 0; var pauseCount = 0; var stopCount = 0; var seekCount = 0
    var failureMessage: String?
    var performed:[(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double)]=[]
    var released:[UInt32]=[]
    var decisions:[ContentChangePolicy.Decision]=[]
    var interactionReleases=0
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int){performed.append((key,note,velocity,richness))}
    func perform(key:UInt32,note:UInt8?,velocity:UInt8,richness:Double,heldCount:Int,decision:ContentChangePolicy.Decision){decisions.append(decision);perform(key:key,note:note,velocity:velocity,richness:richness,heldCount:heldCount)}
    func release(key:UInt32,heldCount:Int){released.append(key)}
    func releaseInteraction(){interactionReleases += 1}
    func prepare() -> Bool { prepareSucceeds }
    func play() -> Bool { playCount += 1; isPlaying = playSucceeds; if playSucceeds { failureMessage=nil }; return playSucceeds }
    func pause() { pauseCount += 1; isPlaying = false }
    func stop() { stopCount += 1; isPlaying = false }
    func measuredRMS() -> Double { isPlaying ? 0.035 : 0 }
}

struct KeyWooAudioTests {
    @Test @MainActor func generativeMusicHasNoFixedDurationAndReceivesContentDecisionsForItsSingleStream() {
        let player = TestMusicPlayer()
        player.duration = 0
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let stream = MusicTrack(id: "local-ai", title: "AI", subtitle: "local", url: URL(string: "keywoo-ai://local"), isBuiltIn: true)
        #expect(engine.selectTrack(stream, autoplay: false))
        engine.start()
        #expect(engine.currentTrack.isGenerative && engine.isInteractiveBuiltIn)
        #expect(engine.musicDuration == 0 && player.playCount == 1)
        _ = engine.noteOn(keyCode: 36, timestamp: 0)
        _ = engine.noteOn(keyCode: 36, timestamp: 0.1)
        #expect(player.performed.count == 1)
        #expect(player.decisions.first?.shouldChangeContent == true)
        #expect(player.playCount == 1 && player.seekCount == 0)
        engine.stop()
    }

    @Test @MainActor func ordinaryKeysDoNotPerformAndBigKeyContentCuesRemainRateLimited() {
        let player = TestMusicPlayer()
        player.duration = 0
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let stream = MusicTrack(id: "local-ai", title: "AI", subtitle: "local", url: URL(string: "keywoo-ai://local"), isBuiltIn: true)
        #expect(engine.selectTrack(stream, autoplay: false))
        engine.start()
        for key in UInt16(0)..<6 {
            _ = engine.noteOn(keyCode: key, timestamp: Double(key) * 0.1)
            engine.noteOff(keyCode: key)
        }
        #expect(player.performed.isEmpty)
        #expect(engine.heldKeyCount == 0)
        _ = engine.noteOn(keyCode: 36, timestamp: 1.0)
        engine.noteOff(keyCode: 36)
        #expect(player.decisions.last?.shouldChangeContent == true)
        _ = engine.noteOn(keyCode: 36, timestamp: 1.01)
        engine.noteOff(keyCode: 36)
        #expect(player.decisions.last?.shouldChangeContent == false)
        _ = engine.noteOn(keyCode: 36, timestamp: 5.0)
        #expect(player.decisions.last?.shouldChangeContent == true)
        #expect(player.performed.count == 3)
        #expect(player.playCount == 1 && player.seekCount == 0)
        engine.stop()
    }

    @Test @MainActor func silentLettersStillTeachCadenceToTheNextBigKey() throws {
        let slowPlayer = TestMusicPlayer(), fastPlayer = TestMusicPlayer()
        let slow = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in slowPlayer })
        let fast = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in fastPlayer })
        #expect(slow.selectTrack(track(), autoplay: false))
        #expect(fast.selectTrack(track(), autoplay: false))
        slow.start(); fast.start()
        defer { slow.stop(); fast.stop() }
        for index in 0..<20 {
            _ = fast.noteOn(keyCode: 0, timestamp: Double(index) * 0.05)
            fast.noteOff(keyCode: 0)
        }
        #expect(fastPlayer.performed.isEmpty)
        _ = slow.noteOn(keyCode: 49, timestamp: 1)
        _ = fast.noteOn(keyCode: 49, timestamp: 1)
        #expect(slowPlayer.performed.count == 1 && fastPlayer.performed.count == 1)
        let idleDecision = try #require(slowPlayer.decisions.last)
        let fastDecision = try #require(fastPlayer.decisions.last)
        #expect(fastDecision.duration < idleDecision.duration)
        #expect(fastDecision.feedbackWeight < idleDecision.feedbackWeight)
    }

    @Test @MainActor func anEmptyStaticRecordingIsStillRejected() {
        let player = TestMusicPlayer()
        player.duration = 0
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        #expect(!engine.selectTrack(track(), autoplay: false))
        #expect(engine.musicErrorMessage != nil)
    }

    private let rate = 16_000.0
    private func rms(_ samples:[Float],_ start:Double,_ end:Double) -> Double {
        let a=max(0,Int(start*rate)*2); let b=min(samples.count,Int(end*rate)*2)
        guard b>a else { return 0 }
        return (samples[a..<b].reduce(0.0) { $0+Double($1*$1) }/Double(b-a)).squareRoot()
    }
    private func track(_ name:String="test") -> KeyDance.MusicTrack {
        KeyDance.MusicTrack(id:name,title:name,subtitle:"test",url:URL(fileURLWithPath:"/private/tmp/\(name).wav"))
    }

    @Test @MainActor func wholeMusicGesturesReadTheActualClockWithoutCreatingIndependentNotes() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        var track=MusicLibrary.builtInTracks[0];track.url=URL(fileURLWithPath:"/private/tmp/arrangement.wav")
        #expect(engine.selectTrack(track,autoplay:false));engine.start(resumeMusic:false)
        player.currentTime=0.2
        _=engine.noteOn(keyCode:49,timestamp:0);engine.noteOff(keyCode:49)
        #expect(engine.currentHarmony=="Dm9")
        player.currentTime=4.1
        _=engine.noteOn(keyCode:36,timestamp:0.5)
        #expect(engine.currentHarmony=="G13")
        #expect(player.performed.count==2)
        #expect(player.performed.allSatisfy { $0.note == nil })
        #expect(player.playCount==0 && !player.isPlaying)
        #expect(engine.heldKeyCount==1)
        engine.stop()
    }

    @Test @MainActor func repeatedPhysicalKeysDoNotCreateNewPerformedNotesAndPreviewHasSeparateOwnership() async throws {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false));engine.start(resumeMusic:false)
        for i in 0..<30{_=engine.noteOn(keyCode:49,timestamp:Double(i)*0.03)}
        #expect(player.performed.count==1)
        _=engine.trigger(keyCode:36)
        #expect(player.performed.count==2 && engine.heldKeyCount==1)
        // Parallel tests can delay the one-shot task's initial MainActor turn.
        // Wait for its actual release instead of assuming when its sleep began.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while player.released.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.released.count==1 && player.released[0]>65_535)
        #expect(engine.heldKeyCount==1)
        engine.noteOff(keyCode:49)
        #expect(player.released.last==49 && engine.heldKeyCount==0)
        engine.stop()
    }

    @Test func legacyMelodyDirectorDevelopsAPhraseAndKeepsNearbyNotes() {
        let harmony=MusicInteraction.harmony(trackID:"after-hours",time:0)
        var slow=MelodyDirector(),fast=MelodyDirector()
        let sparse=(0..<20).map{slow.next(harmony:harmony,timestamp:Double($0)*0.9).note}
        let dense=(0..<120).map{fast.next(harmony:harmony,timestamp:Double($0)*0.07)}
        #expect(Set(sparse).count>=3)
        #expect(dense.allSatisfy{harmony.notes.contains($0.note)})
        let unchanged=zip(dense,dense.dropFirst()).filter{$0.note==$1.note}.count
        #expect(unchanged>80)
        #expect(zip(dense,dense.dropFirst()).allSatisfy{abs($0.note-$1.note)<=4})
        #expect(dense.last!.velocity<dense.first!.velocity)
        #expect(dense.last!.richness>dense.first!.richness)
    }

    @Test @MainActor func importedMusicNeverReceivesAGuessedMelody() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track("imported"),autoplay:false));engine.start(resumeMusic:false)
        _=engine.noteOn(keyCode:49)
        #expect(!engine.isInteractiveBuiltIn && engine.currentHarmony=="原曲动态")
        #expect(player.performed.count==1 && player.performed[0].note==nil)
        engine.stop()
    }

    @Test @MainActor func typingNeverSeeksPausesRestartsOrSkipsBackgroundMusic() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false))
        engine.start(resumeMusic:true)
        player.currentTime=37.25
        let baseline=(player.playCount,player.pauseCount,player.seekCount)
        for i in 0..<200 {
            let key=UInt16(i%50)
            _=engine.noteOn(keyCode:key,timestamp:Double(i)*0.06)
            engine.noteOff(keyCode:key)
        }
        engine.releaseAll()
        #expect(!player.performed.isEmpty && player.performed.count < 200)
        #expect(player.currentTime==37.25)
        #expect(player.playCount==baseline.0)
        #expect(player.pauseCount==baseline.1)
        #expect(player.seekCount==baseline.2)
        #expect(player.isPlaying)
        engine.stop()
    }

    @Test @MainActor func musicPauseIsIndependentFromKeyboardFeedback() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false)); engine.start()
        player.currentTime=12
        engine.pauseMusic()
        let count=player.playCount
        _=engine.noteOn(keyCode:49); engine.noteOff(keyCode:49); _=engine.trigger(keyCode:36)
        #expect(!player.isPlaying)
        #expect(player.currentTime==12)
        #expect(player.playCount==count)
        #expect(engine.isEnabled)
        engine.stop()
    }

    @Test @MainActor func masterPauseAndResumePreservePositionAndUserIntent() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false)); engine.start()
        player.currentTime=44
        engine.stop()
        #expect(!player.isPlaying)
        #expect(engine.noteOn(keyCode:49)=="—")
        engine.start(resumeMusic:false)
        #expect(!player.isPlaying)
        #expect(player.currentTime==44)
        engine.playMusic()
        #expect(player.isPlaying)
        #expect(player.currentTime==44)
        engine.stop()
    }

    @Test @MainActor func invalidImportOrFailedPlaybackKeepsCurrentTrackAndTimeline() {
        let good=TestMusicPlayer(); let bad=TestMusicPlayer(); bad.playSucceeds=false
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{ url in
            if url.lastPathComponent=="decode-error.wav" { throw NSError(domain:"test",code:1) }
            return url.lastPathComponent=="play-error.wav" ? bad:good
        })
        #expect(engine.selectTrack(track("good"),autoplay:false)); engine.start()
        good.currentTime=23
        #expect(!engine.selectTrack(track("decode-error")))
        #expect(engine.currentTrack.id=="good")
        #expect(good.currentTime==23 && good.isPlaying)
        #expect(!engine.selectTrack(track("play-error")))
        #expect(engine.currentTrack.id=="good")
        #expect(good.currentTime==23 && good.isPlaying)
        #expect(good.stopCount==0)
        engine.stop()
    }

    @Test @MainActor func selectingWhileMasterOffAndSeekingDoNotStartPlayback() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:true))
        #expect(player.playCount==0)
        engine.seekMusic(to:250)
        #expect(player.currentTime<player.duration)
        #expect(player.currentTime>99)
        #expect(player.playCount==0)
        engine.seekMusic(to: -3)
        #expect(player.currentTime==0)
        engine.seekMusic(to:.nan)
        #expect(player.currentTime==0)
    }

    @Test @MainActor func successfulPlaybackRetryClearsThePreviousError() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false)); engine.start(resumeMusic:false)
        player.playSucceeds=false
        engine.playMusic()
        #expect(engine.musicErrorMessage != nil)
        player.playSucceeds=true
        engine.playMusic()
        #expect(engine.musicErrorMessage == nil)
        #expect(engine.isMusicPlaying)
        engine.stop()
    }

    @Test @MainActor func separateVolumeAndHitChangesDoNotAlterMusicTransport() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        #expect(engine.selectTrack(track(),autoplay:false)); engine.start()
        engine.musicVolume=0.21
        let count=player.playCount
        engine.hitVolume=0.9; engine.hitSound = .softTap; engine.decay=0.8
        #expect(abs(player.volume-0.21)<0.0001)
        #expect(player.playCount==count)
        #expect(player.isPlaying)
        engine.stop()
    }

    @Test @MainActor func musicHeadroomAppliesOnSelectionAndLiveFaderChanges() {
        let player=TestMusicPlayer()
        let engine=SoundEngine(audioDeviceEnabled:false,musicFactory:{_ in player})
        engine.musicVolume=1
        #expect(engine.selectTrack(track(),autoplay:false))
        #expect(player.volume>0.67 && player.volume<0.68)
        engine.musicVolume=0.48
        #expect(player.volume==Float(0.48), "The user-approved background level must remain unchanged.")
        engine.musicVolume=0.5
        #expect(player.volume==0.5)
        var previous=player.volume
        for step in 51...100 {
            engine.musicVolume=Double(step)/100
            #expect(player.volume>previous && player.volume<0.68)
            previous=player.volume
        }
        #expect(player.playCount==0 && player.seekCount==0)
    }

    @Test func quietHitSamplesRemainBitIdenticalAndTheCeilingHasNoHardCorner() {
        let quietSamples:[Float]=[-0.20,-0.1,-0.001,-0.0,0,0.001,0.1,0.20]
        for sample in quietSamples {
            #expect(AudioMixSafety.limitHit(sample).bitPattern==sample.bitPattern)
        }
        let delta:Float=0.0001
        let below=(AudioMixSafety.limitHit(0.2)-AudioMixSafety.limitHit(0.2-delta))/delta
        let above=(AudioMixSafety.limitHit(0.2+delta)-AudioMixSafety.limitHit(0.2))/delta
        #expect(abs(below-above)<0.005, "A continuous slope avoids a hard-clipping corner.")
        #expect(AudioMixSafety.limitHit(4)<0.281)
        #expect(AudioMixSafety.limitHit(-4) > -0.281)
    }

    @Test func fullScaleImportedMusicAndSimultaneousKeysCannotOverloadTheMix() {
        var events=(0..<12).map { OfflineSoundRenderer.Event(time:0.1,keyCode:UInt16($0),action:.keyDown) }
        events += (0..<12).map { .init(time:1.5,keyCode:UInt16($0),action:.keyUp) }
        let musicGain=Float(AudioMixSafety.musicGain(for:1))
        for style in SoundStyle.allCases {
            let output=OfflineSoundRenderer.renderPerformance(events:events,style:style,decay:1,volume:1,duration:2,sampleRate:rate)
            #expect(output.attackCount==12)
            #expect(output.maximumVoices<=13)
            #expect(rms(output.samples,0.1,0.12)>0.005)
            #expect(output.samples.allSatisfy { sample in
                sample.isFinite && abs(sample)<=0.280001 && abs(musicGain+sample)<0.96 && abs(-musicGain+sample)<0.96
            }, "Both polarities of a full-scale song must retain headroom even with twelve simultaneous hits.")
        }
    }

    // Historical standalone-renderer fixtures accept explicit synthesis events.
    // They do not specify which physical keys the current app routes to music.
    @Test func legacyRendererEveryExplicitDownCreatesOneImmediateAttack() {
        var events:[OfflineSoundRenderer.Event]=[]
        for i in 0..<100 {
            let time=0.123+Double(i)*0.043
            events.append(.init(time:time,keyCode:UInt16(i%20),action:.keyDown))
            events.append(.init(time:time+0.025,keyCode:UInt16(i%20),action:.keyUp))
        }
        let output=OfflineSoundRenderer.renderPerformance(events:events,duration:5.2,sampleRate:rate)
        #expect(output.attackCount==100)
        #expect(output.maximumVoices<=13)
        #expect(rms(output.samples,0,0.123)==0)
        #expect(rms(output.samples,0.123,0.133)>0.003)
        #expect(rms(output.samples,5,5.2)==0)
    }

    @Test func holdingKeySustainsTextureWithoutGeneratingExtraBeats() {
        for style in SoundStyle.allCases {
            let events=[OfflineSoundRenderer.Event(time:0.1,keyCode:0,action:.keyDown),.init(time:6.1,keyCode:0,action:.keyUp)]
            let output=OfflineSoundRenderer.renderPerformance(events:events,style:style,duration:6.6,sampleRate:rate)
            #expect(output.attackCount==1)
            #expect(rms(output.samples,5,6)>0.001)
            #expect(rms(output.samples,6.4,6.6)==0)
            let a=rms(output.samples,4,4.1); let b=rms(output.samples,4.1,4.2)
            #expect(a/b>0.5 && a/b<2, "A held texture must not turn into periodic percussion bursts.")
        }
    }

    @Test func autoRepeatDoesNotRetriggerOrChangeHeldSound() {
        let base=[OfflineSoundRenderer.Event(time:0,keyCode:0,action:.keyDown),.init(time:4,keyCode:0,action:.keyUp)]
        var repeated=base
        for i in 1..<75 { repeated.append(.init(time:Double(i)*0.05,keyCode:0,action:.keyDown)) }
        let a=OfflineSoundRenderer.renderPerformance(events:base,duration:4.5,sampleRate:rate)
        let b=OfflineSoundRenderer.renderPerformance(events:repeated,duration:4.5,sampleRate:rate)
        #expect(a.samples==b.samples)
        #expect(b.attackCount==1)
    }

    @Test func quickTapIsAudibleEvenWhenDownAndUpShareTimestamp() {
        for style in SoundStyle.allCases {
            let samples=OfflineSoundRenderer.render(events:[.init(time:0.1,keyCode:0,action:.keyDown),.init(time:0.1,keyCode:0,action:.keyUp)],style:style,duration:1,sampleRate:rate)
            #expect(rms(samples,0.1,0.15)>0.003)
            #expect(rms(samples,0.85,1)==0)
        }
    }

    @Test func rapidTypingRemainsBoundedAndReleaseAllSilencesEverything() {
        var events=(0..<150).map { OfflineSoundRenderer.Event(time:Double($0)*0.012,keyCode:UInt16($0%100),action:.strike) }
        events.append(.init(time:0,keyCode:125,action:.keyDown))
        events.append(.init(time:2,keyCode:0,action:.releaseAll))
        for style in SoundStyle.allCases {
            let output=OfflineSoundRenderer.renderPerformance(events:events,style:style,decay:1,volume:1,duration:2.5,sampleRate:rate)
            #expect(output.attackCount==151)
            #expect(output.maximumVoices<=13)
            #expect(output.samples.allSatisfy { $0.isFinite })
            #expect((output.samples.map { abs($0) }.max() ?? 1)<0.281)
            #expect(rms(output.samples,2.03,2.5)==0)
        }
    }

    @Test func builtInMusicFilesAreRealFullLengthStereoLoops() throws {
        for track in MusicLibrary.builtInTracks {
            let url=try #require(MusicLibrary.url(for:track))
            let file=try AVAudioFile(forReading:url)
            let format=file.processingFormat
            #expect(format.channelCount==2)
            let seconds=Double(file.length)/format.sampleRate
            #expect(seconds>80 && seconds<110)
            #expect(abs(seconds-track.duration)<0.01)
            let head=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096))
            try file.read(into:head,frameCount:4096)
            let first=head.floatChannelData![0][0]
            file.framePosition=file.length-4096
            let tail=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096))
            try file.read(into:tail,frameCount:4096)
            let last=tail.floatChannelData![0][4095]
            #expect(abs(first-last)<0.0001)
            #expect((0..<4096).contains { abs(head.floatChannelData![0][$0])>0.001 })
            #expect((0..<4096).contains { abs(tail.floatChannelData![0][$0])>0.001 })
        }
    }
}
