import SwiftUI
import AppKit

struct MusicSpaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                MusicPlayerCard(model: model, audio: model.audio)
                practice
                InputRhythmCard(model: model, audio: model.audio)
                keyboard
            }
            VStack(spacing: 12) {
                MixCard(model: model, audio: model.audio)
                MusicLibraryCard(model: model)
            }.frame(width: 225)
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(L("大键 DJ")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("高亮大键可试听 · 不计入统计")).font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            KeyboardView(pressed: model.pressedKeys, counts: [:], heatmap: false, performanceOnly: true, action: model.previewKey)
                .frame(height: 112).disabled(!model.isEnabled)
            HStack(spacing: 5) {
                Circle().fill(model.soundingHeldKeys.isEmpty ? Palette.line : Palette.coral).frame(width: 5, height: 5)
                Text(model.soundingHeldKeys.isEmpty ? (model.audio.isInteractiveBuiltIn ? L("空格轻推 · 退格回拨 · Shift 按住展开") : L("仅大键控制原曲强弱")) : L("大键正在带动音乐"))
                Spacer()
                if let key = model.lastKey {
                    Text("\(KeyLayout.label(for: key).uppercased())  ·  \(L(model.lastNote))")
                }
            }.font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(15).cardStyle()
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("试打")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.practiceText = "" } label: {
                    Text(L("清空")).font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
            }
            TextField(L("正常打字，再试试空格、退格、Tab 和 Shift。"), text: $model.practiceText)
                .textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("practice-input")
        }.padding(14).cardStyle()
    }
}

private struct MusicPlayerCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: SoundEngine
    @State private var seeking = false
    @State private var seekPosition = 0.0

    var body: some View {
        HStack(spacing: 16) {
            AlbumArtwork(trackID: audio.currentTrack.id, playing: audio.isMusicPlaying)
                .frame(width: 90, height: 124)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Circle().fill(audio.isMusicPlaying ? Palette.coral : .white.opacity(0.3)).frame(width: 5, height: 5)
                    Text(!model.isEnabled ? L("全部暂停中 · 右上角继续") : audio.isMusicLoading ? L("正在加载") : audio.isMusicPlaying ? L("正在播放") : L("随时开始"))
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6)
                    Spacer()
                    Image(systemName: audio.currentTrack.isGenerative ? "sparkles" : "repeat").font(.system(size: 11))
                        .help(audio.currentTrack.isGenerative ? L("本机准备完整乐句，输入推动后续变奏") : L("歌曲会自动循环播放"))
                }.foregroundStyle(.white.opacity(0.6))
                Text(audio.currentTrack.displayTitle).font(.system(size: 25, weight: .medium, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.white)
                Text(audio.musicStatusMessage.map(L) ?? audio.currentTrack.displaySubtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                HStack(spacing: 12) {
                    Button { model.toggleMusicPlayback() } label: {
                        Image(systemName: audio.isMusicPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                            .foregroundStyle(Palette.forest).background(Palette.mint, in: Circle())
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!model.isEnabled || audio.isMusicLoading)
                        .accessibilityLabel(audio.isMusicPlaying ? L("暂停音乐") : L("播放音乐"))
                    Button { nextTrack() } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 13)).frame(width: 25, height: 30)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.75)).accessibilityLabel(L("下一首音乐"))
                    Spacer(minLength: 0)
                }.padding(.top, 3)
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { seeking ? seekPosition : audio.musicProgress }, set: {
                        seekPosition = $0
                        if !seeking { model.seekMusic(to: $0 * audio.musicDuration) }
                    }), in: 0...1) { editing in
                        if editing { seekPosition = audio.musicProgress; seeking = true }
                        else { model.seekMusic(to: seekPosition * audio.musicDuration); seeking = false }
                    }.controlSize(.mini).tint(Palette.mint).accessibilityLabel(L("歌曲进度"))
                        .disabled(audio.currentTrack.isGenerative)
                    HStack {
                        Text(clockText((seeking ? seekPosition * audio.musicDuration : audio.musicCurrentTime)))
                        Spacer()
                        Text(audio.currentTrack.isGenerative ? L("音乐持续") : clockText(audio.musicDuration))
                    }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.forest, in: RoundedRectangle(cornerRadius: 18))
    }
    private func nextTrack() {
        let tracks = model.musicTracks
        guard !tracks.isEmpty else { return }
        let index = tracks.firstIndex(where: { $0.id == model.selectedMusicID }) ?? 0
        model.selectMusic(id: tracks[(index + 1) % tracks.count].id)
    }
    private func clockText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct AlbumArtwork: View {
    let trackID: String
    let playing: Bool
    var small = false
    private var warm: Bool { trackID != "soft-current" }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: warm ? [Color(red: 0.91, green: 0.66, blue: 0.54), Color(red: 0.63, green: 0.39, blue: 0.52)] : [Color(red: 0.61, green: 0.72, blue: 0.81), Color(red: 0.36, green: 0.40, blue: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.20)).frame(width: geo.size.width * 0.70).offset(x: geo.size.width * 0.26, y: -geo.size.height * 0.17)
                VStack(spacing: geo.size.width * 0.045) {
                    HStack(spacing: geo.size.width * 0.035) {
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: geo.size.width * 0.06)
                                .fill(index == 1 ? Palette.forest.opacity(0.85) : .white.opacity(0.88))
                                .frame(width: geo.size.width * 0.185, height: geo.size.width * (index == 1 ? 0.33 : 0.40))
                                .offset(y: index == 1 ? geo.size.width * -0.07 : 0)
                        }
                    }
                    RoundedRectangle(cornerRadius: geo.size.width * 0.05).fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * 0.63, height: geo.size.width * 0.13)
                }.rotationEffect(.degrees(-12)).offset(y: small ? 0 : -4)
            }.clipShape(RoundedRectangle(cornerRadius: small ? 7 : 11))
        }.accessibilityHidden(true)
    }
}

private struct InputRhythmCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: SoundEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(L("击键反馈")).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || model.feedbackPulses.isEmpty)) { timeline in
                Canvas { context, size in
                    let centerY = size.height * 0.50
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: centerY))
                    baseline.addLine(to: CGPoint(x: size.width, y: centerY))
                    context.stroke(baseline, with: .color(Palette.line), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    for pulse in model.feedbackPulses {
                        let age = max(0, timeline.date.timeIntervalSince(pulse.time))
                        guard age < 6 else { continue }
                        let x = size.width * (1 - age / 6)
                        let height = (13 + Double(pulse.lane) * 4) * pulse.strength
                        let fade = min(1, max(0, 1 - age / 6))
                        let pop = exp(-age * 6)
                        let rect = CGRect(x: min(size.width - 5, x) - 2, y: centerY - height / 2, width: 4, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color((pulse.lane == 3 ? Palette.coral : Palette.accent).opacity(fade)))
                        if !reduceMotion && pop > 0.02 {
                            let diameter = 7 + (1 - pop) * 34
                            let ring = CGRect(x: x - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
                            context.stroke(Path(ellipseIn: ring), with: .color(Palette.coral.opacity(pop * 0.5)), lineWidth: 1.3)
                        }
                    }
                }
            }.frame(height: 42).clipped()
                .accessibilityLabel(L("最近六秒的演奏与试听轨迹"))
            HStack(spacing: 5) {
                Circle().fill(audio.isMusicPlaying ? Palette.accent : Palette.line).frame(width: 4, height: 4)
                Text(L("小键安静输入，大键带动音乐。"))
                Spacer()
                if !audio.isMusicPlaying {
                    Text(L("已暂停"))
                } else {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.line)
                            Capsule().fill(Palette.coral).frame(width: geometry.size.width * min(1, max(0, audio.interactionLevel)))
                        }
                    }.frame(width: 30, height: 3)
                        .accessibilityLabel(L("音乐展开程度"))
                        .accessibilityValue("\(Int(audio.interactionLevel * 100))%")
                }
            }.font(.system(size: 8)).foregroundStyle(Palette.muted)
        }.padding(14).cardStyle()
    }
}

private struct MixCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: SoundEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mixSlider(L("音乐"), subtitle: L("整首音乐的音量"), icon: "music.note", value: $model.musicVolume, level: audio.musicOutputLevel, color: Palette.accent)
            mixSlider(L("按键影响"), subtitle: L("越高，整首音乐的变化越明显"), icon: "waveform.path", value: $model.hitVolume, level: audio.interactionLevel, color: Palette.coral, showsLevel: false)
            DisclosureGroup(L("更多设置")) {
                VStack(alignment: .leading, spacing: 16) {
                    if audio.isInteractiveBuiltIn {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L("响应方式")).font(.system(size: 11, weight: .medium))
                            ForEach(HitSound.allCases) { sound in
                                Button { model.hitSound = sound; model.previewKey(49) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: sound == .softTap ? "waveform.path" : sound == .wood ? "sun.max" : "waveform")
                                            .font(.system(size: 15)).frame(width: 22)
                                        Text(sound.title).font(.system(size: 11, weight: .medium))
                                        Spacer(minLength: 2)
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Palette.accent).opacity(model.hitSound == sound ? 1 : 0)
                                    }.padding(.horizontal, 10).padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.hitSound == sound ? Palette.accent.opacity(0.08) : Palette.background,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityValue(model.hitSound == sound ? L("已选择") : L("未选择"))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(L("回落时长")).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(model.decay < 0.33 ? L("短") : model.decay > 0.7 ? L("长") : L("适中"))
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Slider(value: $model.decay, in: 0...1).controlSize(.small).accessibilityLabel(L("响应回落"))
                    }
                }.foregroundStyle(Palette.ink).padding(.top, 12)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(15).cardStyle()
    }
    private func mixSlider(_ title: String, subtitle: String, icon: String, value: Binding<Double>, level: Double, color: Color, showsLevel: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Slider(value: value, in: 0...1).tint(color).controlSize(.small)
                .accessibilityLabel(showsLevel ? Lf("%@音量", title) : L("互动强度"))
                .help(subtitle)
            if showsLevel {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.line.opacity(0.5))
                        Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, level * 9)))
                    }
                }.frame(height: 3)
                    .accessibilityLabel(Lf("%@输出电平", title))
                    .accessibilityValue(level > 0.0005 ? L("正在发声") : L("安静"))
            }
        }
    }
}

private struct MusicLibraryCard: View {
    @ObservedObject var model: AppModel
    @State private var showLibrary = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(L("音乐库")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showLibrary = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .accessibilityLabel(L("管理音乐库"))
            }
            ForEach(model.musicTracks.prefix(4)) { track in
                Button { model.selectMusic(id: track.id) } label: {
                    HStack(spacing: 9) {
                        AlbumArtwork(trackID: track.id, playing: false, small: true).frame(width: 32, height: 35)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Text(track.isGenerative ? L("本机 AI · 实验") : (track.isBuiltIn ? L("原创 · 整曲互动") : L("本机 · 动态响应"))).font(.system(size: 8)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        if model.selectedMusicID == track.id {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.accent)
                        }
                    }.padding(.vertical, 5).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(Lf("%@，%@", track.displayTitle, track.isBuiltIn ? L("内置原创") : L("本机音乐")))
                    .accessibilityValue(model.selectedMusicID == track.id ? L("已选择") : L("未选择"))
                    .contextMenu {
                        if !track.isBuiltIn { Button(L("从音乐库移除"), role: .destructive) { model.removeImportedMusic(id: track.id) } }
                    }
            }
            if model.musicTracks.count > 4 {
                Button { showLibrary = true } label: {
                    Text(Lf("全部音乐 · %d 首", model.musicTracks.count)).font(.system(size: 10))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            Button { model.importMusic() } label: {
                Text(model.music.isImporting ? L("正在加入音乐…") : L("＋ 加入自己的歌")).font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(model.music.isImporting)
                .accessibilityLabel(model.music.isImporting ? L("正在导入本地音乐") : L("导入本地音乐"))
        }.padding(15).cardStyle()
            .sheet(isPresented: $showLibrary) { MusicLibrarySheet(model: model) }
    }
}
