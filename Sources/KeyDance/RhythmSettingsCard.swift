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
                    InfoHelpButton(title: "桌面律动", message: "能量条随打字蓄能，脉冲随按键起跳，键阵爆破让按键发光，并在空格时化成碎光。演示只播放动画，不发声，也不计入统计。", identifier: "rhythm-help")
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
                    .frame(width: 260)
                    .accessibilityIdentifier("rhythm-style")
                }
                if model.rhythmStyle == .burst {
                    Text(L("最近的按键会化成发光字符。空格将它们打成碎光，回车轻轻收束，旧字符会自行淡出。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 2) {
                        Text(L("动画幅度")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        InfoHelpButton(title: "动画幅度", message: "调节动画变化的大小。数值越高，打字时的起伏越明显；不会改变声音或音量。", identifier: "rhythm-intensity-help")
                    }
                    Slider(value: $model.rhythmIntensity, in: 0.4...1.5)
                        .accessibilityLabel(L("动画幅度"))
                        .accessibilityValue(Text(model.rhythmIntensity.formatted(.percent.precision(.fractionLength(0)))))
                        .accessibilityIdentifier("rhythm-intensity")
                    Text(model.rhythmIntensity.formatted(.percent.precision(.fractionLength(0))))
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
                if !model.isEnabled {
                    Text(L("继续运行后，律动悬浮窗会重新出现。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(18)
        .cardStyle()
    }
}
