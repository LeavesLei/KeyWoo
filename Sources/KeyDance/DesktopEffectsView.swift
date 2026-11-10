import SwiftUI

@MainActor
final class EffectsPresentationState: ObservableObject {
    @Published var detailsExpanded = false
}

/// Effects have one home. Selection is an explicit activation action; passive
/// preference bindings elsewhere do not start an effect or resume the app.
struct DesktopEffectsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: EffectsPresentationState

    private var canPreview: Bool { model.isEnabled && !model.monitor.secureInputActive }
    private var status: String {
        if !model.rhythmEnabled { return L("选择样式即可开启") }
        if !model.isEnabled { return L("已暂停，继续后显示") }
        if model.monitor.secureInputActive { return L("安全输入中，键盘反馈暂停") }
        return L("已开启 · 打字时显示")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 146), spacing: 12), count: 4), spacing: 12) {
                ForEach(RhythmVisualStyle.allCases) { style in
                    styleCard(style)
                }
            }
            controls
        }
    }

    private func styleCard(_ style: RhythmVisualStyle) -> some View {
        let selected = model.rhythmStyle == style
        return Button { model.activateRhythmStyle(style) } label: {
            VStack(spacing: 13) {
                EffectThumbnail(style: style)
                    .frame(height: 94)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text(style.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Palette.accent : Palette.line)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .foregroundStyle(selected ? Palette.accent : Palette.ink)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Palette.accent.opacity(0.8) : Palette.line.opacity(0.6), lineWidth: selected ? 1.5 : 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsActionRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(style.title)
        .accessibilityValue(L(selected ? "已选择" : "未选择"))
        .accessibilityHint(L(canPreview ? "选择并演示此特效" : "选好样式，继续后显示"))
        .accessibilityIdentifier("rhythm-style-\(style.rawValue)")
        .help(L(canPreview ? "选择并演示此特效" : "选好样式，继续后显示"))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statusLabel; Spacer(minLength: 8); effectActions }
                VStack(alignment: .leading, spacing: 12) { statusLabel; effectActions }
            }
            Divider().overlay(Palette.line.opacity(0.5))
            sliderRow("动画幅度", value: intensityPosition, range: ControlScale.rhythmIntensity.displayRange,
                      percent: intensityPosition.wrappedValue, identifier: "rhythm-intensity",
                      explanation: "只改变画面起伏，不影响声音或音量。")
            sliderRow("特效透明度", value: $model.rhythmOpacity, range: AppModel.rhythmOpacityRange,
                      percent: model.rhythmOpacity, identifier: "rhythm-opacity",
                      explanation: "数值越低越淡，100% 保持原始亮度。")

            if model.rhythmStyle == .edgeGlow {
                Divider().overlay(Palette.line.opacity(0.5))
                if #available(macOS 14.2, *) {
                    HStack(spacing: 4) {
                        Toggle(L("跟随电脑声音"), isOn: $model.rhythmFollowsAudio)
                            .font(.system(size: 13))
                            .accessibilityIdentifier("rhythm-follow-audio")
                        InfoHelpButton(title: "跟随电脑声音", message: "低音推动柔光，中音带动流动，高音点亮细节；打字效果会自然叠加。首次开启需允许系统音频录制，声音只在本机即时分析，不保存录音。", identifier: "rhythm-follow-audio-help")
                        Spacer(minLength: 0)
                    }
                    if model.rhythmFollowsAudio && model.rhythmEnabled { audioStatus }
                } else {
                    Text(L("跟随电脑声音需要 macOS 14.2 或更新版本。"))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            DisclosureGroup(L("更多选项"), isExpanded: $presentation.detailsExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 4) {
                        Toggle(L("闪光效果"), isOn: $model.rhythmFlashes)
                            .accessibilityIdentifier("rhythm-flashes")
                        InfoHelpButton(title: "闪光效果", message: "能量蓄满时出现流光，空格和回车带有短暂亮光。关闭后保留蓄能和弹动；系统开启“减少动态效果”时也会减弱动画。", identifier: "rhythm-flashes-help")
                        Spacer(minLength: 0)
                    }
                    if model.rhythmStyle != .edgeGlow {
                        HStack(spacing: 4) {
                            Toggle(L("不挡鼠标"), isOn: $model.rhythmClickThrough)
                                .accessibilityIdentifier("rhythm-click-through")
                            InfoHelpButton(title: "不挡鼠标", message: "开启后，鼠标可以直接点到动画后面的窗口。想移动动画时，先关闭此选项，再拖动动画；也可点击“重置位置”恢复默认位置。", identifier: "rhythm-click-through-help")
                            Spacer(minLength: 8)
                            Button(L("重置位置")) { model.resetRhythmPosition() }
                                .help(L("恢复默认位置并允许拖动动画。"))
                                .accessibilityIdentifier("rhythm-reset-position")
                        }
                    }
                }
                .font(.system(size: 13)).padding(.top, 8).padding(.bottom, 6)
            }
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("effects-more-options")
        }
        .padding(22)
        .cardStyle()
    }

    private var statusLabel: some View {
        HStack(spacing: 9) {
            Circle().fill(model.rhythmEnabled && canPreview ? Palette.accent : Palette.muted.opacity(0.5))
                .frame(width: 6, height: 6).accessibilityHidden(true)
            Text(status).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            InfoHelpButton(title: "桌面特效", message: "点击样式会开启并播放一段无声演示，不增加按键统计。平时由打字点亮，停手后渐隐；底部泛光始终允许鼠标穿过。", identifier: "rhythm-help")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects-status")
    }

    private var effectActions: some View {
        HStack(spacing: 14) {
            Button { model.previewRhythm() } label: {
                Label(L(model.rhythmEnabled ? "演示" : "开启并演示"), systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!canPreview)
            .help(L(canPreview ? "仅演示画面，不播放声音、不计入统计。" : model.isEnabled ? "安全输入期间不可演示" : "继续后可演示"))
            .accessibilityIdentifier("rhythm-preview")
            Toggle(L("启用特效"), isOn: $model.rhythmEnabled)
                .toggleStyle(.switch).labelsHidden()
                .accessibilityIdentifier("rhythm-enabled")
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Double,
                           identifier: String, explanation: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text(L(title)).font(.system(size: 13))
                InfoHelpButton(title: title, message: explanation, identifier: identifier + "-help")
            }.frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(L(title))
                .accessibilityValue(Text(percent.formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.locale))))
                .accessibilityIdentifier(identifier)
            Text(percent.formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.locale)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var intensityPosition: Binding<Double> {
        Binding { ControlScale.rhythmIntensity.displayValue(for: model.rhythmIntensity) }
        set: { model.rhythmIntensity = ControlScale.rhythmIntensity.storedValue(for: $0) }
    }

    @ViewBuilder private var audioStatus: some View {
        switch model.systemAudioRhythm.state {
        case .stopped:
            Text(L(model.isEnabled ? "正在等待电脑声音" : "继续运行后，将跟随电脑声音。"))
                .font(.caption).foregroundStyle(Palette.muted)
        case .starting:
            Text(L("正在连接电脑声音…")).font(.caption).foregroundStyle(Palette.muted)
        case .running:
            Text(L("已连接电脑声音 · 没有声音时自然淡出")).font(.caption).foregroundStyle(Palette.muted)
        case .failed:
            HStack(spacing: 10) {
                Text(L("暂时无法读取电脑声音，请检查系统音频录制权限。"))
                    .font(.caption).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button(L("重试")) { model.systemAudioRhythm.retry() }
                    .accessibilityIdentifier("rhythm-audio-retry")
            }
        }
    }
}

private struct EffectThumbnail: View {
    let style: RhythmVisualStyle
    private let glow = Color(red: 0.99, green: 0.65, blue: 0.55)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.12, green: 0.115, blue: 0.12))
                switch style {
                case .energy:
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(0..<9) { index in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(glow.opacity(0.5 + Double(index % 3) * 0.2))
                                .frame(width: 8, height: CGFloat([18, 27, 42, 33, 55, 39, 48, 28, 20][index]))
                        }
                    }
                case .pulse:
                    ForEach(0..<3) { index in
                        Circle().stroke(glow.opacity(0.8 - Double(index) * 0.24), lineWidth: 2)
                            .frame(width: CGFloat(24 + index * 22), height: CGFloat(24 + index * 22))
                    }
                    Circle().fill(glow).frame(width: 9, height: 9)
                case .burst:
                    ForEach(Array(["A", "S", "D"].enumerated()), id: \.offset) { index, key in
                        Text(key).font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(glow)
                            .frame(width: 29, height: 31)
                            .background(glow.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                            .rotationEffect(.degrees(Double(index - 1) * 12))
                            .offset(x: CGFloat(index - 1) * 34, y: index == 1 ? -12 : 10)
                    }
                case .edgeGlow:
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    Ellipse().fill(glow.opacity(0.65))
                        .frame(width: geometry.size.width * 0.65, height: 17)
                        .blur(radius: 12).offset(y: 28)
                    Capsule().fill(glow)
                        .frame(width: geometry.size.width * 0.48, height: 2).offset(y: 32)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
