import SwiftUI

struct RhythmSettingsCard: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(L("桌面律动")).font(.system(size: 14, weight: .semibold))
                    InfoHelpButton(title: "桌面律动", message: "选择随按键变化的桌面动画。演示只播放画面，不发声，也不计入统计。", identifier: "rhythm-help")
                }
                Spacer(minLength: 8)
                Button(L("演示")) { model.previewRhythm() }
                    .buttonStyle(.bordered)
                    .disabled(!model.isEnabled || model.monitor.secureInputActive)
                    .help(L("仅演示画面，不播放声音、不计入统计。"))
                    .accessibilityIdentifier("rhythm-preview")
                Toggle(L("桌面律动"), isOn: $model.rhythmEnabled)
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityIdentifier("rhythm-enabled")
            }
            if model.rhythmEnabled || !compact {
                Divider()
                HStack(spacing: 12) {
                    Text(L("样式")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    Picker(L("显示样式"), selection: $model.rhythmStyle) {
                        ForEach(RhythmVisualStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: 320)
                    .accessibilityIdentifier("rhythm-style")
                }
                if model.rhythmStyle == .burst {
                    Text(L("最近的按键会化成发光字符。空格将它们打成碎光，回车轻轻收束，旧字符会自行淡出。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.rhythmStyle == .edgeGlow {
                    Text(L("光沿鼠标所在显示器的下缘亮起，停手后渐隐。鼠标可以直接穿过。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if #available(macOS 14.2, *) {
                        HStack(spacing: 2) {
                            Toggle(L("跟随电脑声音"), isOn: $model.rhythmFollowsAudio)
                                .font(.system(size: 12))
                                .accessibilityIdentifier("rhythm-follow-audio")
                            InfoHelpButton(title: "跟随电脑声音", message: "低音推动柔光，中音带动流动，高音点亮细节；打字效果会自然叠加。首次开启需允许系统音频录制，声音只在本机即时分析，不保存录音。", identifier: "rhythm-follow-audio-help")
                            Spacer()
                        }
                        if model.rhythmFollowsAudio { audioStatus }
                    } else {
                        Text(L("跟随电脑声音需要 macOS 14.2 或更新版本。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 2) {
                        Text(L("动画幅度")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        InfoHelpButton(title: "动画幅度", message: "动画幅度从 25% 到 100% 均匀调节。数值越高，打字时的起伏越明显；不会改变声音或音量。", identifier: "rhythm-intensity-help")
                    }
                    VStack(spacing: 1) {
                        Slider(value: intensityPosition, in: ControlScale.rhythmIntensity.displayRange, step: ControlScale.displayStep)
                            .accessibilityLabel(L("动画幅度"))
                            .accessibilityValue(Text(intensityPercent))
                            .accessibilityIdentifier("rhythm-intensity")
                        ControlScaleLabels(values: [0.25, 0.5, 0.75, 1])
                    }
                    Text(intensityPercent)
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Palette.muted).frame(width: 60, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 2) {
                        Text(L("特效透明度")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        InfoHelpButton(title: "特效透明度", message: "所有律动样式共用。25% 最淡，100% 保持原始亮度。", identifier: "rhythm-opacity-help")
                    }
                    Slider(value: $model.rhythmOpacity, in: AppModel.rhythmOpacityRange, step: 0.01)
                        .accessibilityLabel(L("特效透明度"))
                        .accessibilityValue(Text(model.rhythmOpacity.formatted(.percent.precision(.fractionLength(0)))))
                        .accessibilityIdentifier("rhythm-opacity")
                    Text(model.rhythmOpacity.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Palette.muted).frame(width: 40, alignment: .trailing)
                }
                HStack {
                    HStack(spacing: 2) {
                        Toggle(L("闪光效果"), isOn: $model.rhythmFlashes)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("rhythm-flashes")
                        InfoHelpButton(title: "闪光效果", message: "能量蓄满时出现流光，空格和回车带有短暂亮光。关闭后保留蓄能和弹动；系统开启“减少动态效果”时也会减弱动画。", identifier: "rhythm-flashes-help")
                    }
                    Spacer()
                }
                if model.rhythmStyle != .edgeGlow {
                    HStack {
                        HStack(spacing: 2) {
                            Toggle(L("不挡鼠标"), isOn: $model.rhythmClickThrough)
                                .font(.system(size: 12))
                                .accessibilityIdentifier("rhythm-click-through")
                            InfoHelpButton(title: "不挡鼠标", message: "开启后，鼠标可以直接点到动画后面的窗口。想移动动画时，先关闭此选项，再拖动动画；也可点击“重置位置”恢复默认位置。", identifier: "rhythm-click-through-help")
                        }
                        Spacer()
                        Button(L("重置位置")) { model.resetRhythmPosition() }
                            .buttonStyle(.plain).font(.system(size: 12))
                            .foregroundStyle(Palette.accent)
                            .accessibilityIdentifier("rhythm-reset-position")
                    }
                }
                if !model.isEnabled {
                    Text(L("继续运行后，律动悬浮窗会重新出现。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(18)
        .cardStyle()
    }

    private var intensityPosition: Binding<Double> {
        Binding {
            ControlScale.rhythmIntensity.displayValue(for: model.rhythmIntensity)
        } set: { position in
            model.rhythmIntensity = ControlScale.rhythmIntensity.storedValue(for: position)
        }
    }

    private var intensityPercent: String {
        ControlScale.rhythmIntensity.displayValue(for: model.rhythmIntensity)
            .formatted(.percent.precision(.fractionLength(0...2)).locale(AppLocalization.locale))
    }

    @ViewBuilder private var audioStatus: some View {
        switch model.systemAudioRhythm.state {
        case .stopped:
            Text(L("继续运行后，将跟随电脑声音。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        case .starting:
            Text(L("正在连接电脑声音…"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        case .running:
            Text(L("已连接电脑声音 · 没有声音时自然淡出"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        case .failed:
            HStack {
                Text(L("暂时无法读取电脑声音，请检查系统音频录制权限。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("重试")) { model.systemAudioRhythm.retry() }
                    .buttonStyle(.bordered).font(.system(size: 11))
                    .accessibilityIdentifier("rhythm-audio-retry")
            }
        }
    }
}

/// Quiet scale labels share the slider's linear positions, including ranges
/// whose first displayed value is above zero.
struct ControlScaleLabels: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let lower = values.first ?? 0
            let span = max(0.001, (values.last ?? 1) - lower)
            ForEach(values.indices, id: \.self) { index in
                let fraction = (values[index] - lower) / span
                Text(values[index].formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.locale)))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 40, alignment: index == 0 ? .leading : index == values.count - 1 ? .trailing : .center)
                    .position(x: min(max(20, geometry.size.width * fraction), max(20, geometry.size.width - 20)), y: 6)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
