import SwiftUI

/// Browsing and disclosure state survive navigation and language changes.
@MainActor
final class KeyboardSoundPresentationState: ObservableObject {
    @Published var category: KeyboardSoundCategory
    @Published var query = ""
    @Published var keyboardExpanded = false
    @Published var extraKeysExpanded = false
    @Published var sourceExpanded = false

    init(category: KeyboardSoundCategory = .recorded) {
        self.category = category
    }
}

struct KeyboardSoundSpaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: KeyboardSoundPresentationState
    @FocusState private var practiceFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var previewFocused: Bool

    private static let presetOrder = Dictionary(uniqueKeysWithValues: [
        "rainy75", "whiteFox", "unicomp", "technicsYellow", "laneAlps", "macbookPro", "topre", "oreo", "panda", "purple", "red", "blue", "brown", "black",
        "streetBeat", "mahjongTiles", "hermes", "woodDesk", "mahjong"
    ].enumerated().map { ($0.element, $0.offset) })

    init(model: AppModel, presentation: KeyboardSoundPresentationState) {
        self.model = model
        self.presentation = presentation
    }

    private var canPreview: Bool { model.isEnabled && !model.monitor.secureInputActive }
    private var previewUnavailableReason: String? {
        if !model.isEnabled { return L("已暂停 · 点击右上角继续") }
        if model.monitor.secureInputActive { return L("键盘反馈已暂停 · 安全输入") }
        return nil
    }

    private var styles: [KeyboardSoundStyle] {
        let terms = presentation.query.split(whereSeparator: \.isWhitespace).map(String.init)
        return KeyboardSoundStyle.allCases.filter { style in
            guard style.category == presentation.category else { return false }
            guard !terms.isEmpty else { return true }
            let searchable = ([style.title, style.subtitle, style.rawValue] + style.characterTags).joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }.sorted {
            let first = Self.presetOrder[$0.rawValue, default: Int.max]
            let second = Self.presetOrder[$1.rawValue, default: Int.max]
            if first != second { return first < second }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            currentSound
            catalog
        }
    }

    private var currentSound: some View {
        let style = model.keyboardSoundStyle
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: style.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 54, height: 54)
                    .foregroundStyle(Palette.accent)
                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("当前音色"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Text(style.title)
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.35)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(style.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                previewButton
            }
            if let reason = previewUnavailableReason {
                Label(reason, systemImage: "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("keyboard-sound-preview-status")
            }
            Divider().overlay(Palette.line.opacity(0.60)).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    volume.frame(minWidth: 350)
                    if model.canChooseKeyboardSoundQuality {
                        Rectangle().fill(Palette.line.opacity(0.6)).frame(width: 1, height: 22)
                            .accessibilityHidden(true)
                        qualityControl
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    volume
                    if model.canChooseKeyboardSoundQuality { qualityControl }
                }
            }
            practice
            optionalTools
        }
        .padding(20)
        .cardStyle()
    }

    private var previewButton: some View {
        Button { model.previewSound() } label: {
            Label(L("试听"), systemImage: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canPreview ? Palette.onAccent : Palette.muted)
                .padding(.horizontal, 15)
                .frame(minHeight: 34)
                .background(canPreview ? Palette.accent : Palette.raisedSurface,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.onAccent.opacity(previewFocused ? 0.8 : 0), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardSoundPresetButtonStyle())
        .focused($previewFocused)
        .disabled(!canPreview)
        .accessibilityLabel(L("试听当前音效"))
        .accessibilityIdentifier("keyboard-sound-preview")
        .help(previewUnavailableReason ?? L("同一段短打字 · 不计入统计"))
    }

    private var qualityControl: some View {
        HStack(spacing: 2) {
            Picker(L("录音版本"), selection: $model.keyboardSoundQuality) {
                ForEach(KeyboardSoundQuality.allCases) { quality in Text(quality.title).tag(quality) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 165)
            .accessibilityIdentifier("keyboard-sound-quality")
            InfoHelpButton(title: "录音版本", message: "原音保留录音原貌；Hi-Fi 减少低频杂音和尾部底噪。切换时可试听同一段按键。", identifier: "keyboard-sound-quality-help")
        }
    }

    private var optionalTools: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Palette.line.opacity(0.60)).accessibilityHidden(true)
            DisclosureGroup(isExpanded: $presentation.keyboardExpanded) {
                practiceKeyboard.padding(.top, 6).padding(.bottom, 14)
            } label: {
                Label(L("屏幕键盘"), systemImage: "keyboard")
            }
            .accessibilityIdentifier("sound-screen-keyboard")
            Divider().overlay(Palette.line.opacity(0.45)).accessibilityHidden(true)
            DisclosureGroup(isExpanded: $presentation.sourceExpanded) {
                source.padding(.top, 6).padding(.bottom, 10)
            } label: {
                Label(L("声音细节"), systemImage: "info.circle")
            }
            .accessibilityIdentifier("sound-recording-details")
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .font(.system(size: 12))
        .foregroundStyle(Palette.muted)
    }

    private var catalog: some View {
        let visibleStyles = styles
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(L("音色"))
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    InfoHelpButton(title: "选择音色", message: "点击音色选用并试听。可按名称、轴体或材质搜索。", identifier: "sound-catalog-help")
                }
                Spacer()
                if !visibleStyles.contains(model.keyboardSoundStyle) {
                    Button {
                        presentation.category = model.keyboardSoundStyle.category
                        presentation.query = ""
                    } label: {
                        Label(L("显示当前音色"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("sound-category-current")
                }
            }
            HStack(spacing: 12) {
                Picker(L("音色分类"), selection: $presentation.category) {
                    ForEach(KeyboardSoundCategory.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 225)
                .labelsHidden()
                .accessibilityIdentifier("sound-category")
                Spacer(minLength: 0)
                soundSearch.frame(maxWidth: 260)
            }
            if visibleStyles.isEmpty {
                ContentUnavailableView {
                    Label(L("没有匹配的音色"), systemImage: "magnifyingglass")
                } actions: {
                    Button(L("清除搜索")) { presentation.query = "" }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .cardStyle()
                .accessibilityIdentifier("sound-catalog-empty")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], spacing: 8) {
                    ForEach(visibleStyles) { style in
                        KeyboardSoundPresetCard(style: style, selected: model.keyboardSoundStyle == style, canPreview: canPreview) {
                            if model.keyboardSoundStyle != style { model.keyboardSoundStyle = style }
                            if canPreview { model.previewSound() }
                        }
                    }
                }
                .accessibilityIdentifier("sound-catalog")
            }
        }
    }

    private var soundSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            TextField(L("搜索音色"), text: $presentation.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("sound-catalog-search")
            if !presentation.query.isEmpty {
                Button {
                    presentation.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 26, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .accessibilityLabel(L("清除搜索"))
                .help(L("清除搜索"))
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minHeight: 32)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Palette.accent.opacity(0.75) : Palette.line, lineWidth: searchFocused ? 1.2 : 0.7)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { searchFocused = true })
        .onExitCommand { if searchFocused { presentation.query = "" } }
    }

    private var volume: some View {
        let percent = ControlScale.keyboardVolume.displayValue(for: model.keyboardVolume)
            .formatted(.percent.precision(.fractionLength(0...2)).locale(AppLocalization.locale))
        return HStack(spacing: 12) {
            HStack(spacing: 2) {
                Label(L("音量"), systemImage: model.keyboardVolume > 0 ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                InfoHelpButton(title: "音量", message: "音量从 0% 到 100% 均匀调节，不同音色已做音量平衡。右侧按钮恢复推荐音量（6.25%）。调到 0% 只会静音，按键仍会统计。", identifier: "sound-volume-help")
            }
            Slider(value: volumePosition, in: ControlScale.keyboardVolume.displayRange)
                .accessibilityLabel(L("音效音量"))
                .accessibilityValue(Text(percent))
                .accessibilityIdentifier("keyboard-sound-volume")
            Text(percent)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(width: 60, alignment: .trailing)
            Button {
                model.keyboardVolume = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .disabled(abs(model.keyboardVolume - 1) < 0.0001)
            .help(L("恢复推荐音量（6.25%）"))
            .accessibilityLabel(L("恢复推荐音量（6.25%）"))
            .accessibilityIdentifier("keyboard-sound-volume-reset")
        }
    }

    private var volumePosition: Binding<Double> {
        Binding {
            ControlScale.keyboardVolume.displayValue(for: model.keyboardVolume)
        } set: { position in
            model.keyboardVolume = ControlScale.keyboardVolume.storedValue(for: position)
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(L("试打"))
                        .font(.system(size: 12, weight: .medium))
                    InfoHelpButton(title: "试打", message: "在输入框打字，试听字母、空格、回车等按键的声音。实体键盘输入会正常计入统计；点击下方屏幕键盘只试听，不计入统计。", identifier: "sound-practice-help")
                }
                HStack(spacing: 4) {
                    TextField(L("在这里打字试听"), text: $model.practiceText,
                              prompt: Text(L("在这里打字试听")).foregroundStyle(Palette.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($practiceFocused)
                        .accessibilityIdentifier("practice-input")
                    Button {
                        model.practiceText = ""
                        practiceFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .frame(width: 30, height: 30)
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
                .frame(minHeight: 42)
                .background(Palette.raisedSurface.opacity(practiceFocused ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(practiceFocused ? Palette.accent.opacity(0.75) : Palette.line,
                                      lineWidth: practiceFocused ? 1.2 : 0.7)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { practiceFocused = true })
                KeyboardSoundOutputMeter(audio: model.keyboardAudio, enabled: canPreview)
                    .frame(width: 44)
                    .padding(.leading, 4)
            }
        }
    }

    private var practiceKeyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyboardView(pressed: model.pressedKeys, counts: [:], heatmap: false, action: model.previewKey)
                .frame(height: 133)
                .disabled(!canPreview)
                .help(L("点击试听 · 不计入统计"))
            DisclosureGroup(L("更多按键"), isExpanded: $presentation.extraKeysExpanded) { extraKeys.padding(.top, 8) }
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
            Text(model.keyboardSoundStyle.sourceLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(model.keyboardSoundStyle.sourceDescription)
                .font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .background(selected ? Palette.accent.opacity(0.09) : Palette.raisedSurface,
                                in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text((style.category == .recorded ? Array(style.characterTags.prefix(1)) : style.characterTags).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "play.fill")
                    .font(.system(size: selected ? 14 : 10, weight: .semibold))
                    .foregroundStyle(selected || hovered ? Palette.accent : Palette.muted)
                    .opacity(indicatorOpacity)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
            .background(selected ? Palette.accent.opacity(0.07) : hovered ? Palette.raisedSurface : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, lineWidth: focused ? 1.4 : 0.8)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KeyboardSoundPresetButtonStyle())
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Lf("%@ 音效", style.title))
        .accessibilityValue(selected ? L("已选择") : L("未选择"))
        .accessibilityHint(Text("\(style.sourceLabel). \(style.subtitle)"))
        .accessibilityIdentifier("keyboard-preset-\(style.rawValue)")
        .help(L(canPreview ? "试听并选用" : "选用音色，暂不试听"))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: selected)
    }

    private var borderColor: Color {
        if focused { return Palette.accent }
        if selected { return Palette.accent.opacity(0.55) }
        return Palette.line
    }

    private var indicatorOpacity: Double {
        if selected { return 1 }
        guard canPreview else { return 0 }
        return hovered ? 1 : 0.64
    }
}

private struct KeyboardSoundPresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct KeyboardSoundOutputMeter: View {
    @ObservedObject var audio: KeyboardSoundEngine
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(Palette.accent)
                    .frame(width: geometry.size.width * min(1, max(0, audio.outputLevel)))
            }
        }.frame(height: 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: audio.outputLevel)
            .accessibilityLabel(L("击键反馈"))
            .accessibilityValue(L(!enabled ? "已暂停" : audio.outputLevel > 0.02 ? "正在发声" : "安静"))
    }
}
