import SwiftUI

/// Full library management, including imported tracks outside the compact sidebar preview.
struct MusicLibrarySheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var errorMessage: String? {
        model.musicSelectionError ?? model.music.errorMessage ?? model.audio.musicErrorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("音乐库")).font(.system(size: 21, weight: .semibold))
                Text(Lf("%d 首音乐 · 选择一首，陪你继续打字", model.musicTracks.count))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(22)

            if let errorMessage {
                Label(L(errorMessage), systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22).padding(.bottom, 14)
                    .accessibilityIdentifier("music-library-error")
            }

            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.musicTracks) { track in
                        trackRow(track)
                    }
                }.padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("music-library-list")
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.importMusic() } label: {
                        Label(model.music.isImporting ? L("正在导入…") : L("导入本地音乐"), systemImage: "plus")
                    }.disabled(model.music.isImporting)
                        .accessibilityIdentifier("music-library-import")
                    if model.music.isImporting {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(L("正在导入音乐"))
                    }
                    Spacer()
                    Button(L("完成")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Text(L("移除曲目只删除应用内副本，原文件不受影响。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(20)
        }
        .frame(width: 520, height: 460)
        .foregroundStyle(Palette.ink)
        .background(Palette.background)
    }

    private func trackRow(_ track: MusicTrack) -> some View {
        let selected = model.selectedMusicID == track.id
        return HStack(spacing: 0) {
            Button { model.selectMusic(id: track.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: track.isBuiltIn ? "waveform" : "music.note")
                        .font(.system(size: 17)).foregroundStyle(Palette.accent)
                        .frame(width: 36, height: 40)
                        .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.displayTitle).font(.system(size: 13, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(track.isBuiltIn ? L("内置原创") : L("本机音乐")) · \(durationText(track.duration))")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17)).foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }.padding(.vertical, 11).padding(.leading, 12).padding(.trailing, 10)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(track.displayTitle)
                .accessibilityLabel(Lf("%@，%@", track.displayTitle, track.isBuiltIn ? L("内置原创") : L("本机音乐")))
                .accessibilityValue(selected ? L("已选择") : L("未选择"))
                .accessibilityHint(L("选择此音乐，保持当前播放或暂停状态"))

            if !track.isBuiltIn {
                Button(role: .destructive) { model.removeImportedMusic(id: track.id) } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .frame(width: 30, height: 30)
                }.buttonStyle(.borderless).foregroundStyle(Palette.muted)
                    .disabled(model.music.isImporting)
                    .help(L("移除本机副本，原文件不受影响"))
                    .accessibilityLabel(Lf("移除 %@ 的本机副本", track.displayTitle))
                    .padding(.trailing, 10)
            }
        }
        .background(selected ? Palette.accent.opacity(0.08) : Palette.surface.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return L("时长未知") }
        let duration = Int(seconds)
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }
}
