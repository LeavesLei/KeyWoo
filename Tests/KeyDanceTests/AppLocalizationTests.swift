import Foundation
import SwiftUI
import Testing
@testable import KeyDance

struct AppLocalizationTests {
    @Test func savedOptionsKeepStableRawValuesAndSystemAppearanceRemainsAutomatic() {
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppExperienceMode.music.rawValue == "music")
        #expect(AppExperienceMode.keyboardSounds.rawValue == "keyboardSounds")
        #expect(AppAppearance.system.preferredColorScheme == nil)
        #expect(AppAppearance.light.preferredColorScheme == .light)
        #expect(AppAppearance.dark.preferredColorScheme == .dark)
    }

    @Test func systemUsesTheFirstSupportedPreferenceAndExplicitSelectionWins() {
        #expect(AppLocalization.resolvedLanguage(.system, preferredLanguages: ["fr-FR", "zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(AppLocalization.resolvedLanguage(.system, preferredLanguages: ["en-GB", "zh-Hans"]) == .english)
        #expect(AppLocalization.resolvedLanguage(.system, preferredLanguages: ["zh-Hant-TW"]) == .simplifiedChinese)
        #expect(AppLocalization.resolvedLanguage(.system, preferredLanguages: []) == .english)
        #expect(AppLocalization.resolvedLanguage(.simplifiedChinese, preferredLanguages: ["en-US"]) == .simplifiedChinese)
    }

    @Test func englishInterfaceDictionaryDoesNotLeakChineseOrLoseFormatArguments() {
        let placeholders = try! NSRegularExpression(pattern: "%[@difu]")
        func arguments(_ value: String) -> [String] {
            let ns = value as NSString
            return placeholders.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        for (key, english) in AppLocalization.translations {
            #expect(!english.isEmpty)
            // Common punctuation such as the middle dot may belong to Unicode
            // script extensions; check actual CJK ideographs, not shared marks.
            let hasIdeograph = english.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
            }
            #expect(!hasIdeograph, "Untranslated English entry: \(key)")
            #expect(arguments(key) == arguments(english), "Format arguments changed: \(key)")
        }
        #expect(AppLocalization.localized("全部暂停", language: .english) == "Pause all")
        #expect(AppLocalization.localized("音乐模式", language: .english) == "Music")
        #expect(AppLocalization.localized("键盘音效", language: .english) == "Keyboard sounds")
        #expect(AppLocalization.localized("红轴", language: .english) == "Red switch")
    }

    @Test func translatedLabelsCanReturnToChineseWhileUnknownTextAndPathsStayUntouched() {
        #expect(AppLocalization.localized("Pause all", language: .simplifiedChinese) == "全部暂停")
        #expect(AppLocalization.localized("当前仅在 KeyWoo 内生效", language: .simplifiedChinese) == "当前仅在 键舞 内生效")
        let filename = "/tmp/KeyWoo/我的录音.wav"
        #expect(AppLocalization.localized(filename, language: .simplifiedChinese) == filename)
        #expect(AppLocalization.localized(filename, language: .english) == filename)
        #expect(AppLocalization.localized("My own song", language: .english) == "My own song")
    }

    @Test func errorTranslationPreservesUsefulDetailsAcrossLanguageChanges() {
        let source = "导入失败：找不到这份音频文件。请确认文件已下载到本机。"
        let english = AppLocalization.localized(source, language: .english)
        #expect(english == "Import failed: This audio file could not be found. Make sure it has been downloaded to this Mac.")
        #expect(AppLocalization.localized(english, language: .simplifiedChinese) == source)
        #expect(AppLocalization.localized("本机生成通信中断（32）。", language: .english) == "Local generation communication failed (32).")
        #expect(AppLocalization.localized("Local generation communication failed (32).", language: .simplifiedChinese) == "本机生成通信中断（32）。")
        let pathError = "导入失败：/tmp/KeyWoo/我的录音.wav"
        #expect(AppLocalization.localized(pathError, language: .english) == "Import failed: /tmp/KeyWoo/我的录音.wav")
    }

    @Test @MainActor func everySoundPresetExplainsItsSourceInEnglishWithoutTranslatingAuthorNames() {
        let previous = AppLocalization.language
        defer { AppLocalization.language = previous }
        AppLocalization.language = .english
        for style in KeyboardSoundStyle.allCases {
            for field in [style.title, style.subtitle, style.sourceLabel, style.sourceTitle, style.sourceDescription] {
                let hasIdeograph = field.unicodeScalars.contains {
                    (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                }
                #expect(!field.isEmpty && !hasIdeograph, "Untranslated sound metadata: \(style.rawValue): \(field)")
            }
        }
        #expect(KeyboardSoundStyle.panda.sourceTitle == "Thomas Lai / kbsim")
        #expect(KeyboardSoundStyle.red.sourceTitle == "Hải Nguyễn / Mechvibes")
        #expect(KeyboardSoundStyle.mahjong.sourceLabel != KeyboardSoundStyle.red.sourceLabel)
        #expect(KeyboardSoundStyle.mahjong.sourceDescription.contains("not a recording"))
        #expect(Lf("%d 款录音音色", 8) == "8 recorded sounds")
    }

    @Test @MainActor func runtimeLanguageFormattingAndBrandSwitchWithoutChangingPreferences() {
        let previous = AppLocalization.language
        defer { AppLocalization.language = previous }
        AppLocalization.language = .english
        #expect(AppLocalization.appName == "KeyWoo")
        #expect(AppLocalization.locale.identifier == "en")
        let imported = MusicTrack(id: "user-track", title: "全部暂停", subtitle: "本机音乐")
        #expect(imported.displayTitle == "全部暂停", "A user's title must not be translated even when it matches a dictionary key.")
        #expect(imported.displaySubtitle == "Local music")
        let builtIn = MusicTrack(id: "local-ai", title: "AI · 乐句共奏", subtitle: "音乐持续", isBuiltIn: true)
        #expect(builtIn.displayTitle == "AI · Phrase Sessions")
        #expect(Lf("本次敲击 %d 次", 42) == "Session: 42 key presses")
        #expect(Lf("打开 %@", AppLocalization.appName) == "Open KeyWoo")
        AppLocalization.language = .simplifiedChinese
        #expect(AppLocalization.appName == "键舞")
        #expect(Lf("打开 %@", AppLocalization.appName) == "打开 键舞")
    }
}
