import SwiftUI

struct KeyboardSoundSpaceView: View {
    @ObservedObject var model: AppModel
    @State private var category: KeyboardSoundCategory

    init(model: AppModel) {
        self.model = model
        _category = State(initialValue: model.keyboardSoundStyle.category)
    }

    private var canPreview: Bool { model.isEnabled && !model.monitor.secureInputActive }
    private var previewUnavailableReason: String? {
        if !model.isEnabled { return L("已暂停 · 点击右上角继续") }
        if model.monitor.secureInputActive { return L("键盘反馈已暂停 · 安全输入") }
        return nil
    }

    private var styles: [KeyboardSoundStyle] {
        let order = ["macbookPro", "topre", "oreo", "panda", "purple", "red", "blue", "brown", "black",
                     "mahjongTiles", "hermes", "woodDesk", "mahjong"]
        return KeyboardSoundStyle.allCases.filter { $0.category == category }.sorted {
            let first = order.firstIndex(of: $0.rawValue) ?? order.count
            let second = order.firstIndex(of: $1.rawValue) ?? order.count
            return first == second ? $0.rawValue < $1.rawValue : first < second
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            currentSound
            catalog
            practice
            DisclosureGroup(L("声音来源")) {
                source.padding(.top, 12)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 2)
            RhythmSettingsCard(model: model, compact: true)
        }
    }

    private var currentSound: some View {
        let style = model.keyboardSoundStyle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: style.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Palette.accent)
                    .background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.title)
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.35)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(style.sourceLabel) · \(style.subtitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button { model.previewSound() } label: {
                    Label(L(canPreview ? "试听" : "已暂停"), systemImage: canPreview ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 34)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .opacity(canPreview ? 1 : 0.48)
                .accessibilityLabel(L("试听当前音效"))
                .accessibilityIdentifier("keyboard-sound-preview")
                .help(previewUnavailableReason ?? L("同一段短打字 · 不计入统计"))
            }
            if let reason = previewUnavailableReason {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("keyboard-sound-preview-status")
            }
            Divider()
            volume
        }
        .padding(18)
        .cardStyle()
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                HStack(spacing: 4) {
                    Text(L("音色"))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    InfoHelpButton(title: "选择音色", message: "点击任意音色即可选用，并播放一小段试听。暂停时仍可切换音色，继续运行后生效。录音来源可在下方查看。", identifier: "sound-catalog-help")
                }
                Spacer()
                if category != model.keyboardSoundStyle.category {
                    Button {
                        category = model.keyboardSoundStyle.category
                    } label: {
                        Label(L("当前音色"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .help(L("回到当前音色所在分类"))
                    .accessibilityLabel(L("回到当前音色所在分类"))
                    .accessibilityIdentifier("sound-category-current")
                }
                Picker(L("音色分类"), selection: $category) {
                    ForEach(KeyboardSoundCategory.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 225)
                .labelsHidden()
                .accessibilityIdentifier("sound-category")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 8)], spacing: 8) {
                ForEach(styles) { style in
                    KeyboardSoundPresetCard(style: style, selected: model.keyboardSoundStyle == style, canPreview: canPreview) {
                        model.keyboardSoundStyle = style
                        if canPreview { model.previewSound() }
                    }
                }
            }
        }
    }

    private var volume: some View {
        let percent = model.keyboardVolume.formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.locale))
        return HStack(spacing: 12) {
            HStack(spacing: 2) {
                Label(L("音量"), systemImage: model.keyboardVolume > 0 ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                InfoHelpButton(title: "音量", message: "不同音色已做音量平衡。100% 为标准音量，最高可调到 1600%；右侧重置按钮可恢复到 100%。调到 0 只会静音，按键仍会统计。", identifier: "sound-volume-help")
            }
            Slider(value: volumePosition, in: 0...1)
                .accessibilityLabel(L("音效音量"))
                .accessibilityValue(Text(percent))
                .accessibilityIdentifier("keyboard-sound-volume")
            Text(percent)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(width: 52, alignment: .trailing)
            Button {
                model.keyboardVolume = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(minHeight: 28)
                    .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .disabled(abs(model.keyboardVolume - 1) < 0.0001)
            .help(L("恢复到 100% 音量"))
            .accessibilityLabel(L("恢复到 100% 音量"))
            .accessibilityIdentifier("keyboard-sound-volume-reset")
        }
    }

    private var volumePosition: Binding<Double> {
        // Reserve most of the slider for precise adjustments through 400%.
        let standardMaximum = 4.0
        let boostStart = 0.75
        let boostRange = KeyboardSoundEngine.maximumVolume - standardMaximum
        return Binding {
            let volume = model.keyboardVolume
            return volume <= standardMaximum
                ? boostStart * volume / standardMaximum
                : boostStart + (1 - boostStart) * (volume - standardMaximum) / boostRange
        } set: { position in
            model.keyboardVolume = position <= boostStart
                ? standardMaximum * position / boostStart
                : standardMaximum + boostRange * (position - boostStart) / (1 - boostStart)
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 4) {
                    Text(L("试打"))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    InfoHelpButton(title: "试打", message: "在输入框打字，试听字母、空格、回车等按键的声音。实体键盘输入会正常计入统计；点击下方屏幕键盘只试听，不计入统计。", identifier: "sound-practice-help")
                }
                Spacer()
                if !canPreview {
                    Text(L("已暂停")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                KeyboardSoundOutputMeter(audio: model.keyboardAudio, enabled: canPreview)
                    .frame(width: 56)
            }
            HStack(spacing: 4) {
                TextField(L("在这里打字试听"), text: $model.practiceText,
                          prompt: Text(L("在这里打字试听")).foregroundStyle(Palette.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .accessibilityIdentifier("practice-input")
                Button { model.practiceText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .disabled(model.practiceText.isEmpty)
                .opacity(model.practiceText.isEmpty ? 0.35 : 1)
                .accessibilityLabel(L("清空"))
                .help(L("清空"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(minHeight: 38)
            .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.line, lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            DisclosureGroup(L("屏幕键盘")) {
                practiceKeyboard.padding(.top, 12)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
        }
        .padding(18)
        .cardStyle()
    }

    private var practiceKeyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyboardView(pressed: model.pressedKeys, counts: [:], heatmap: false, action: model.previewKey)
                .frame(height: 133)
                .disabled(!canPreview)
                .help(L("点击试听 · 不计入统计"))
            DisclosureGroup(L("更多按键")) { extraKeys.padding(.top, 8) }
                .disclosureGroupStyle(FullRowDisclosureStyle())
        }
    }

    private var extraKeys: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(KeyLayout.extra) { key in
                let pressed = model.pressedKeys.contains(key.code)
                Button { model.previewKey(key.code) } label: {
                    Text(key.label)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(pressed ? Palette.keyInk : Palette.ink)
                        .background(pressed ? Palette.mint : Palette.raisedSurface,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .accessibilityLabel(Lf("%@ 键，点击试听", key.label))
            }
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(model.keyboardSoundStyle.title)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(L(model.keyboardSoundStyle.sourceLabel)).font(.system(size: 10))
            }
            Text(L(model.keyboardSoundStyle.sourceDescription))
                .font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let value = model.keyboardSoundStyle.sourceURL, let url = URL(string: value) {
                Link(destination: url) {
                    Label(model.keyboardSoundStyle.sourceTitle, systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }.tint(Palette.accent)
                    .accessibilityLabel(Lf("查看 %@ 的原始来源", model.keyboardSoundStyle.sourceTitle))
            } else {
                Text(L(model.keyboardSoundStyle.sourceTitle)).font(.system(size: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyboardSoundPresetCard: View {
    let style: KeyboardSoundStyle
    let selected: Bool
    let canPreview: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: style.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 19)
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                Text(style.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .opacity(selected || (hovered && canPreview) ? 1 : 0)
                    .frame(width: 12)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
            .background(selected ? Palette.accent.opacity(0.09) : hovered ? Palette.raisedSurface : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Palette.accent.opacity(0.65) : Palette.line, lineWidth: selected ? 1 : 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(Lf("%@ 音效", L(style.title)))
            .accessibilityValue(selected ? L("已选择") : L("未选择"))
            .accessibilityHint(Text("\(style.sourceLabel). \(style.subtitle). \(L(canPreview ? "试听并选用" : "选用音色，暂不试听"))"))
            .accessibilityIdentifier("keyboard-preset-\(style.rawValue)")
            .help(L(canPreview ? "试听并选用" : "选用音色，暂不试听"))
            .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

private struct KeyboardSoundOutputMeter: View {
    @ObservedObject var audio: KeyboardSoundEngine
    let enabled: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(Palette.accent)
                    .frame(width: geometry.size.width * min(1, max(0, audio.outputLevel)))
            }
        }.frame(height: 4)
            .animation(.easeOut(duration: 0.10), value: audio.outputLevel)
            .accessibilityLabel(L("击键反馈"))
            .accessibilityValue(L(!enabled ? "已暂停" : audio.outputLevel > 0.02 ? "正在发声" : "安静"))
    }
}
