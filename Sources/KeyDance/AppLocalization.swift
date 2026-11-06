import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("跟随系统"); case .light: return L("浅色"); case .dark: return L("深色") }
    }
    var preferredColorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum AppExperienceMode: String, CaseIterable, Identifiable, Sendable {
    case music, keyboardSounds
    var id: String { rawValue }
    var title: String {
        switch self { case .music: return L("音乐模式"); case .keyboardSounds: return L("键盘音效") }
    }
}

/// UI-only translations. Stable model identifiers and saved data stay unchanged.
/// A lock allows background import errors to use the same selected language.
/// UI invalidation belongs to AppModel.language, so changing language need not
/// recreate the window or discard its statistics filters.
enum AppLocalization {
    private static let lock = NSLock()
    private static var selection: AppLanguage = .simplifiedChinese
    static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selection }
        set { lock.lock(); selection = newValue; lock.unlock() }
    }
    static var locale: Locale {
        Locale(identifier: resolvedLanguage(language).rawValue)
    }
    static var appName: String { resolvedLanguage(language) == .english ? "KeyWoo" : "键舞" }
    static func resolvedLanguage(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard language == .system else { return language }
        for preferred in preferredLanguages.map({ $0.lowercased() }) {
            if preferred.hasPrefix("zh") { return .simplifiedChinese }
            if preferred.hasPrefix("en") { return .english }
        }
        return .english
    }
    static func localized(_ text: String, language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let english = resolvedLanguage(language, preferredLanguages: preferredLanguages) == .english
        if let translated = translations[text] {
            return english ? translated : chineseBrand(text)
        }
        // State may contain a display label produced before a language switch.
        if let original = reverseTranslations[text] { return english ? text : chineseBrand(original) }
        // Translate known error wrappers while retaining the underlying detail.
        // Unknown text (including user track names and paths) is never rewritten.
        for (source, target) in errorWrappers {
            let prefix = english ? source : target
            if text.hasPrefix(prefix) {
                let detail = String(text.dropFirst(prefix.count))
                let translatedDetail = localized(detail, language: language, preferredLanguages: preferredLanguages)
                return (english ? target : source) + translatedDetail
            }
        }
        let runtimePrefix = english ? "本机生成通信中断（" : "Local generation communication failed ("
        let runtimeSuffix = english ? "）。" : ")."
        if text.hasPrefix(runtimePrefix), text.hasSuffix(runtimeSuffix) {
            let number = String(text.dropFirst(runtimePrefix.count).dropLast(runtimeSuffix.count))
            if Int(number) != nil {
                return english ? "Local generation communication failed (\(number))." : "本机生成通信中断（\(number)）。"
            }
        }
        return text
    }
    private static func chineseBrand(_ text: String) -> String {
        text.replacingOccurrences(of: "KeyWoo", with: "键舞")
    }
    private static let errorWrappers: [(String, String)] = [
        ("互动声音启动失败：", "Could not start interactive audio: "),
        ("音乐播放中断：", "Music playback stopped: "),
        ("无法打开音乐：", "Could not open music: "),
        ("导入失败：", "Import failed: "),
        ("未能移除音乐：", "Could not remove music: ")
    ]
    private static let reverseTranslations: [String: String] = {
        var result: [String: String] = [:]
        for key in translations.keys.sorted() where result[translations[key]!] == nil { result[translations[key]!] = key }
        return result
    }()
    static let translations = commonTranslations.merging(FeatureTranslations.english) { _, newer in newer }
    private static let commonTranslations: [String: String] = [
        "音色": "Sounds",
        "统计说明": "About these counts",
        "试打": "Try typing",
        "更多设置": "More options",
        "空间音效": "Spatial sound",
        "耳机空间": "Headphone space",
        "前下方的键盘": "Keyboard in front and below",
        "声音随键位左右分布。": "Sound follows each key’s position.",
        "所有应用": "All apps",
        "仅应用内": "In-app only",
        "本机统计": "On-device counts",
        "开启全局体验": "Enable across apps",
        "输入监控": "Input Monitoring",
        "使用与隐私": "Usage & privacy",
        "悬停查看次数": "Hover for counts",

        "%@ 音效": "%@ sound",
        "击键反馈": "Key feedback",
        "合成拟音 · 非实物录音": "Synthesized foley · No physical recordings",
        "已暂停 · 点击右上角继续": "Paused · Resume at the top right",
        "所有按键都会响应 · 长按不会反复触发": "Every key responds · Holding a key does not repeat",
        "把每次敲击，变成好手感。": "Make every keystroke feel good.",
        "按下与松开，都有细节。": "Details in every press and release.",
        "更多按键": "More keys",
        "最近一分钟 %d 次": "Last minute: %d presses",
        "本次 %d 次": "Session: %d presses",
        "正在输入": "Typing",
        "每一键，都可以试听": "Preview any key",
        "点击试听 · 不计入统计": "Click to preview · Not counted",
        "独立键盘音效": "KEYBOARD SOUNDS",
        "空格、回车与退格带有独立的大键细节。": "Space, Return and Delete have their own big-key details.",
        "等待下一次敲击": "Ready for the next keystroke",
        "纯键盘音效": "Just keyboard sounds",
        "试听不会计入统计。": "Previews are not counted.",
        "试听当前音效": "Preview this sound",
        "试试字母、空格、回车和退格。": "Try letters, Space, Return and Delete.",
        "选择一种声音，享受按下与松开的细节。": "Choose a sound and enjoy the details of each press and release.",
        "静音 · 仍会统计": "Muted · Still counting",
        "音效音量": "Sound volume",
        "全键响应": "Every key responds",
        "只影响本应用，不修改系统设置。": "Applies only to this app. System settings are unchanged.",
        "声音来源": "Sound source",
        "如果授权后仍未生效，请退出并重新打开应用。安全输入启用时，键盘响应与统计暂停。": "If access is granted but not active, quit and reopen the app. Secure Input pauses keyboard responses and statistics.",
        "字母、数字、修饰键和大键都能发出键盘音效；按下与松开各有细节。": "Letters, numbers, modifiers and big keys all make keyboard sounds, with distinct press and release details.",
        "屏幕按键与试听按钮不计入统计；真实长按只计一次。": "On-screen keys and previews are not counted. A real key held down is counted once.",
        "开启系统的「输入监控」权限后，在文档、浏览器和编辑器里也能体验选中的声音。应用内试听无需授权。": "Enable Input Monitoring to hear your chosen sounds in documents, browsers and editors. Trying them inside the app needs no permission.",
        "开启输入监控，在其他应用继续体验按键声音。": "Enable Input Monitoring to hear keyboard sounds in other apps.",
        "当前仅在应用内生效": "Currently works only inside this app",
        "把声音带到每个应用": "Bring sound to every app",
        "把音效音量调至 0，仍会正常统计。": "Set sound volume to 0 to keep counting in silence.",
        "每一键，都有手感。": "A distinct feel for every key.",
        "点击右上角暂停，或在应用窗口内按 ⌘ ⇧ P；声音和统计一起暂停。": "Pause at the top right, or press ⌘ ⇧ P in the app window. Sound and statistics pause together.",
        "独立音量": "Separate volume",
        "红轴、青轴、茶轴与麻将均为合成拟音，不是实物录音。": "Red, blue and brown switches and mahjong tiles use synthesized foley, rather than recordings of physical objects.",
        "让 %@，融入你的日常。": "Make %@ part of your day.",
        "让声音，陪你工作": "Let sound accompany your work",
        "试听与统计": "Previews and statistics",
        "语言与外观": "Language and appearance",
        "这段时间还没有记录。回到声音空间敲几下键盘，就会亮起第一块颜色。": "No activity in this period yet. Return to your sound space and type a few keys to start the heatmap.",
        "键盘音效有自己的音量，与音乐模式分开保存。": "Keyboard sounds have their own volume setting, saved separately from music mode.",
        "KeyWoo-按键统计.csv": "KeyWoo-key-statistics.csv",
        "你的按键，你的节奏。": "Your keys. Your rhythm.",
        "音频文件解码失败。": "The audio file could not be decoded.",
        "音频设备或文件无法继续播放。": "The audio device or file could not continue playback.",
        "无法准备下一乐句。": "The next phrase could not be prepared.",
        "无法继续准备乐句。": "Phrase preparation could not resume.",
        "下一乐句准备超时，当前音乐继续。": "The next phrase took too long to prepare. The current music continues.",
        "音乐继续 · 正在准备下一乐句": "Music continues · Preparing the next phrase",
        "轻触当前音乐 · 词句推动变奏": "Shape the current music · Your input guides variations",
        "本机生成进程已退出。": "The local generation process has exited.",
        "本机生成通信中断（%d）。": "Local generation communication failed (%d).",
        "模型响应头过长。": "The model response header is too long.",
        "模型响应格式不正确。": "The model response has an invalid format.",
        "找不到本机音乐模型运行程序。": "The local music model runtime could not be found.",
        "本机模型尚未启动": "The local model has not started",
        "正在加载本机音乐模型，首次约需半分钟…": "Loading the local music model. The first start takes about half a minute…",
        "AI 已就绪 · 暂停生成": "AI ready · Generation paused",
        "正在缓冲 AI 音乐…": "Buffering AI music…",
        "AI 正在连续创作 · 按键改变后续旋律与乐句": "AI is creating continuously · Keys guide upcoming melodies and phrases",
        "本机模型音频格式不匹配。": "The local model's audio format does not match.",
        "本机模型返回了无效音频帧。": "The local model returned an invalid audio frame.",
        "生成音频无效或缓冲越界。": "Generated audio is invalid or exceeds the buffer.",
        "跟随系统": "System",
        "浅色": "Light",
        "深色": "Dark",
        "音乐模式": "Music",
        "键盘音效": "Keyboard sounds",
        "体验模式": "Experience",
        "语言": "Language",
        "外观": "Appearance",
        "偏好设置": "Preferences",
        "音乐空间": "Music space",
        "按键统计": "Key statistics",
        "KeyWoo": "KeyWoo",
        "键舞": "KeyWoo",
        "音乐": "Music",
        "声音": "Sound",
        "键盘音效 · 所有应用": "Keyboard sounds · All apps",
        "键盘音效 · 仅应用内": "Keyboard sounds · In this app",
        "用同一段短打字，比较不同键盘的质感。": "Compare each keyboard with the same short typing sample.",
        "录音键盘": "Recorded keyboards",
        "%d 款录音音色": "%d recorded sounds",
        "先听 Topre、Oreo 和 Holy Panda，再比较经典轴体。": "Try Topre, Oreo and Holy Panda, then compare the classic switches.",
        "趣味音效": "Playful sounds",
        "声音跟随真实按键。": "Sound follows your key presses.",
        "同一段短打字 · 不计入统计": "Same typing sample · Not counted",
        "当前声音来源": "Sound source",
        "查看 %@ 的原始来源": "View the original source of %@",
        "试听": "Preview",
        "试听并选用": "Preview and select",
        "试听并选用 %@": "Preview and select %@",
        "机械键盘使用公开录音采样；麻将为合成趣味音效。每款预设都有来源说明。": "Keyboard presets use publicly shared recordings; Mahjong is a playful synthesized sound. Each preset includes source details.",
        "字母、数字、修饰键和大键都能发出键盘音效；长按不会重复触发。": "Letters, numbers, modifiers and larger keys all make keyboard sounds. Holding a key does not repeat the sound.",
        "Cherry 红轴 · ABS": "Cherry Red · ABS",
        "Cherry 青轴 · ABS": "Cherry Blue · ABS",
        "Cherry 茶轴 · PBT": "Cherry Brown · PBT",
        "Cherry 黑轴 · PBT": "Cherry Black · PBT",
        "Everglide 水晶紫": "Everglide Crystal Purple",
        "Topre 静电容": "Topre Electro-capacitive",
        "MacBook Pro 键盘": "MacBook Pro Keyboard",
        "Hermes 打字机": "Hermes Typewriter",
        "麻将牌实录": "Mahjong Tiles",
        "木桌轻叩": "Wooden Desk",
        "短行程轻触，带自然回弹": "Light, short-travel taps with a natural return",
        "金属字锤、空格与行尾铃": "Metal typebars, space bar, and margin bell",
        "真实牌面轻碰，大键更扎实": "Real tile taps with firmer accents on large keys",
        "指尖叩木，轻重有别": "Light and firm fingertip taps on wood",
        "从一段 MacBook Pro 打字录音挑选成对的触底与回弹。按键按音色分组，原录音未标键位。": "Paired contacts selected from a MacBook Pro typing recording. Keys are grouped by sound because the source does not label individual keys.",
        "Hermes Precisa 305 实录。空格用原机空格声，回车用原机行尾铃，其余键轮换真实字锤声。": "Recorded from a Hermes Precisa 305. Space plays its space bar, Return plays its margin bell, and other keys alternate real typebar strikes.",
        "从实物录音选取独立短音。大键用另一组真实敲击，松开时静音。": "Individual hits from physical recordings. Large keys use a separate set of hits. Release is silent.",
        "顺滑线性，原始 ABS 键帽录音": "Smooth linear sound, recorded with ABS keycaps",
        "清脆点击，原始 ABS 键帽录音": "Crisp clicks, recorded with ABS keycaps",
        "轻柔段落，原始 PBT 键帽录音": "Gentle tactile sound, recorded with PBT keycaps",
        "低沉扎实，原始 PBT 键帽录音": "Deep and solid, recorded with PBT keycaps",
        "圆润段落，保留键帽与回弹细节": "Rounded tactile sound with keycap and return detail",
        "明亮段落，按键起落清晰": "Bright tactile sound with distinct presses and releases",
        "柔软厚实，静电容键盘录音": "Soft, full-bodied electro-capacitive keyboard recordings",
        "饱满段落，独立按下与松开录音": "Full tactile sound with separate press and release recordings",
        "合成瓷牌碰击，非真实麻将录音": "Synthesized tile taps, not recorded Mahjong tiles",
        "真实录音": "Recorded",
        "合成拟音": "Synthesized",
        "键舞合成音效": "KeyWoo synthesized sounds",
        "五种普通键录音，空格、回车、退格分别采录；其余键复用普通键。": "Five standard-key recordings, plus separate Space, Return and Delete recordings. Other keys reuse the standard-key samples.",
        "原始键位录音，部分键位复用相近声音；可清楚分离的回弹跟随松开，其余保留完整敲击。": "Original key recordings, with some positions reusing related samples. Clear return sounds follow key release; other keys use the complete keystroke recording.",
        "程序合成的瓷牌拟音，不是实物录音。": "Synthesized tile sounds, not a recording of real tiles.",
        "键盘录音资源缺失或损坏，请重新安装应用。": "Keyboard recordings are missing or damaged. Please reinstall the app.",
        "全部暂停": "Pause all",
        "继续": "Resume",
        "暂停音乐": "Pause music",
        "播放音乐": "Play music",
        "试听音乐响应": "Preview music response",
        "试听键盘音效": "Preview keyboard sound",
        "加入本地音乐…": "Import local music…",
        "歌曲": "Tracks",
        "响应方式": "Response style",
        "本次敲击 %d 次": "Session: %d key presses",
        "打开 %@": "Open %@",
        "退出 %@": "Quit %@",
        "关于 %@": "About %@",
        "大键 DJ，跟随你的手": "Big-key DJ, following your hands",
        "键盘上的音乐与触感。": "Music and tactile sound at your fingertips.",
        "让每次敲击，都有喜欢的声音。": "A sound you love, with every keystroke.",
        "本机运行 · 不保存输入文字": "Runs locally · Never saves what you type",
        "大键打碟，跟随你的手。": "DJ with your biggest keys.",
        "大键，带着音乐起伏。": "Bring the music to life.",
        "小键安静输入，大键带动音乐。": "Type quietly. Let the big keys move the music.",
        "本次 %@ 次": "Session: %@ presses",
        "最近一分钟 %@ 次": "Last minute: %@ presses",
        "只保存次数，不保存输入文字": "Counts only. Your words stay private.",
        "大键 DJ": "Big-key DJ",
        "高亮大键可试听 · 不计入统计": "Click highlighted keys to preview · Not counted",
        "空格轻推 · 退格回拨 · Shift 按住展开": "Space pushes · Delete pulls · Hold Shift to open up",
        "仅大键控制原曲强弱": "Big keys control the original track's dynamics",
        "大键正在带动音乐": "Your keys are moving the music",
        "试着写点什么": "Try typing something",
        "字母只统计 · 空格轻推 · 回车换句": "Letters count · Space pushes · Return cues a phrase",
        "字母只统计 · 仅大键回应": "Letters count · Only big keys affect the music",
        "清空": "Clear",
        "正常打字，再试试空格、退格、Tab 和 Shift。": "Type normally, then try Space, Delete, Tab and Shift.",
        "全部暂停中 · 右上角继续": "PAUSED · RESUME AT THE TOP RIGHT",
        "正在加载": "LOADING",
        "正在播放": "NOW PLAYING",
        "随时开始": "READY WHEN YOU ARE",
        "本机准备完整乐句，输入推动后续变奏": "Complete phrases are prepared locally; your input guides variations",
        "歌曲会自动循环播放": "This track loops automatically",
        "下一首音乐": "Next track",
        "AI 乐句共奏 · 本机": "AI PHRASES · ON DEVICE",
        "整曲互动": "WHOLE-TRACK RESPONSE",
        "原曲动态": "Track dynamics",
        "歌曲进度": "Track position",
        "音乐持续": "Continuous music",
        "音乐跟着你变化": "Music moves with you",
        "音乐继续，等你加入": "The music continues, ready for you",
        "跟着你的输入，轻轻起伏": "Gently following your input",
        "最近六秒的演奏与试听轨迹": "Performance and preview gestures from the last six seconds",
        "大键 DJ · 手势跟随输入间隔": "Big-key DJ · Gestures follow your timing",
        "仅大键改变原曲动态": "Only big keys shape the track's dynamics",
        "音乐已暂停，播放后响应输入": "Music paused. Play it to hear your gestures.",
        "音乐与输入已暂停": "Music and input are paused",
        "音乐正在随你展开": "The music is opening up with you",
        "音乐轻柔流动，等你推动": "The music is flowing, ready for your touch",
        "音乐展开程度": "Music response level",
        "音乐的手感": "Shape the feel",
        "整首音乐的音量": "Volume of the whole track",
        "按键影响": "Key influence",
        "越高，整首音乐的变化越明显": "Turn up for a stronger response across the track",
        "随输入改变音乐": "Shape the music as you type",
        "按键控制原曲动态。内置曲目还会打开整首音乐的明暗与层次。": "Keys shape the track's dynamics. Built-in tracks also respond with shifts in tone and texture.",
        "回落时长": "Release time",
        "短": "Short",
        "长": "Long",
        "适中": "Medium",
        "响应回落": "Response release time",
        "仅大键推盘、回拨与扫频。动作随输入节奏收放；Shift 长按保持展开。": "Big keys push, pull and sweep. Gestures follow your typing pace; hold Shift to keep the sound open.",
        "仅大键改变原曲动态，小键只计数。": "Big keys change the track's dynamics. Small keys are counted only.",
        "%@音量": "%@ volume",
        "互动强度": "Interaction strength",
        "%@输出电平": "%@ output level",
        "正在发声": "Sounding",
        "安静": "Quiet",
        "陪你听的歌": "Your listening space",
        "管理音乐库": "Manage music library",
        "本机 AI · 实验": "On-device AI · Experimental",
        "原创 · 整曲互动": "Original · Whole-track response",
        "本机 · 动态响应": "Local · Dynamic response",
        "内置原创": "Built-in original",
        "本机音乐": "Local music",
        "本地音乐": "Local music",
        "%@，%@": "%@, %@",
        "已选择": "Selected",
        "未选择": "Not selected",
        "从音乐库移除": "Remove from library",
        "全部音乐 · %d 首": "All tracks · %d",
        "正在加入音乐…": "Adding music…",
        "＋ 加入自己的歌": "＋ Add your own music",
        "正在导入本地音乐": "Importing local music",
        "导入本地音乐": "Import local music",
        "音乐库": "Music library",
        "%d 首音乐 · 选择一首，陪你继续打字": "%d tracks · Choose a companion for your typing",
        "正在导入…": "Importing…",
        "正在导入音乐": "Importing music",
        "完成": "Done",
        "移除曲目只删除应用内副本，原文件不受影响。": "Removing a track deletes only the app's copy. Your original file stays untouched.",
        "选择此音乐，保持当前播放或暂停状态": "Select this track while keeping the current playback state",
        "移除本机副本，原文件不受影响": "Remove the local copy; keep the original file",
        "移除 %@ 的本机副本": "Remove the local copy of %@",
        "时长未知": "Unknown duration",
        "AI · 乐句共奏": "AI · Phrase Sessions",
        "音乐持续 · 词句推动变奏": "Continuous music · Your input guides variations",
        "夜色书桌 · 温暖 Lo-fi": "Late-night desk · Warm lo-fi",
        "柔光流动 · 轻电子": "Soft glow · Light electronic",
        "柔和推盘": "Gentle push",
        "通透扫频": "Open sweep",
        "弹性律动": "Elastic groove",
        "大键轻推整段音乐，动作随输入节奏收放": "Gently push the whole track with gestures that follow your typing",
        "用大键打开整曲明暗，长按 Shift 保持展开": "Open up the track's tone; hold Shift to keep it lifted",
        "跟随你的敲击速度，轻巧切分与回弹": "Light, springy gestures that follow your typing pace",
        "互动声音启动失败：%@": "Could not start interactive audio: %@",
        "音乐播放中断：%@": "Music playback stopped: %@",
        "找不到这首音乐，请重新选择文件。": "This track could not be found. Please select the file again.",
        "文件没有可播放的音频。": "The file contains no playable audio.",
        "播放器无法开始播放。": "The player could not start playback.",
        "无法打开音乐：%@": "Could not open music: %@",
        "音乐暂时无法播放，请检查音频输出。": "Music could not play. Please check your audio output.",
        "AI 乐句": "AI phrase",
        "等待播放": "Ready to play",
        "换句": "New phrase",
        "仅统计": "Count only",
        "推盘": "Push",
        "回拨": "Pull",
        "扫频": "Sweep",
        "抬起": "Lift",
        "展开": "Open up",
        "仅大键响应": "Big keys only",
        "本机音乐库暂时无法读取，已保留原文件。请先检查音乐库文件。": "The local music library could not be read. Its files were preserved. Please check the library file.",
        "这份音频无法播放，或没有有效音频内容。请换一个 MP3、M4A、WAV、AIFF 或 FLAC 文件。": "This file has no playable audio. Try an MP3, M4A, WAV, AIFF or FLAC file.",
        "找不到这份音频文件。请确认文件已下载到本机。": "This audio file could not be found. Make sure it has been downloaded to this Mac.",
        "音乐库记录无效，已停止操作以保留原文件。": "The library record is invalid. The operation stopped to preserve the original file.",
        "导入失败：%@": "Import failed: %@",
        "未能移除音乐：%@": "Could not remove music: %@",
        "全局监听尚未生效。授权后可尝试退出并重新打开 KeyWoo。": "Global monitoring is not active yet. After granting access, try quitting and reopening KeyWoo.",
        "无法建立键盘监听，当前仍可在应用内试奏。": "Keyboard monitoring could not start. You can still try it inside the app.",
        "全局监听未能启用，当前仍可在应用内试奏。": "Global monitoring could not be enabled. You can still try it inside the app.",
        "你的节奏，你的音乐。": "Your rhythm. Your music.",
        "你的空间": "YOUR SPACE",
        "旋律，随处发生": "Music, wherever you type",
        "把旋律带到每个应用": "Bring music to every app",
        "在文档、聊天或代码里，继续你的节奏。": "Keep your rhythm in documents, chats and code.",
        "已暂停。点击右上角继续，找回你的节奏。": "Paused. Resume at the top right to find your rhythm again.",
        "开启输入监控，在其他应用继续用大键带动音乐。": "Enable Input Monitoring to shape music with big keys in other apps.",
        "开启全局体验  ↗": "Enable across apps  ↗",
        "本机统计 · 不记录文字": "Local counts · No text recorded",
        "暂停或继续声音与按键统计": "Pause or resume sound and key statistics",
        "%@ · %d 次 · 键码 %d": "%@ · %d presses · Key code %d",
        "试听 %@": "Preview %@",
        "仅统计，不影响音乐": "Counted only; does not affect music",
        "%@ 键，%d 次": "%@ key, %d presses",
        "%@ 键，点击试听": "%@ key, click to preview",
        "%@ 键，仅统计": "%@ key, counted only",
        "今天": "Today",
        "近一小时": "Last hour",
        "近七天": "Last 7 days",
        "自定义": "Custom",
        "每一份专注，都有迹可循。": "See where your focus takes you.",
        "看看你的手指，今天去了哪些地方。": "A closer look at where your fingers have been.",
        "导出 CSV": "Export CSV",
        "时间范围": "Time range",
        "显示与语言": "Display & language",
        "输入与隐私": "Input & privacy",
        "本机时间 · 精度为分钟": "Local time · Minute-level detail",
        "从": "From",
        "至": "To",
        "结束时间需要晚于开始时间。": "The end time must be later than the start time.",
        "总敲击": "Total presses",
        "次": "presses",
        "使用按键": "Keys used",
        "个": "keys",
        "最常用": "Most used",
        "活跃分钟": "Active minutes",
        "分钟": "min",
        "键盘热力图": "Keyboard heatmap",
        "少": "Less",
        "多": "More",
        "这段时间还没有记录。回到演奏室敲几下键盘，就会亮起第一块颜色。": "No activity in this period yet. Return to your space and type a few keys to start the heatmap.",
        "悬停查看次数。按物理键位统计，热力图展示 ANSI 主键区，完整按键见下表。": "Hover for counts. Statistics use physical key positions. The heatmap shows the main ANSI keys; the full list is below.",
        "敲击节奏": "Typing rhythm",
        "时间": "Time",
        "次数": "Presses",
        "逐键明细": "Per-key details",
        "包含零次按键": "Include unused keys",
        "尚无按键记录": "No key activity yet",
        "%d 次": "%d presses",
        "统计包含修饰键，忽略按住不放产生的自动重复。范围向外对齐到整分钟；结束时间恰好为整分钟时，不含该分钟。试听按钮和屏幕琴键不计入统计。": "Counts include modifier keys and exclude automatic repeats while holding a key. Ranges extend to full minutes; an end time exactly on a minute excludes that minute. Previews and on-screen keys are not counted.",
        "让 KeyWoo，融入你的日常。": "Make KeyWoo part of your day.",
        "全局键盘体验": "Keyboard experience across apps",
        "开启系统的「输入监控」权限后，在文档、浏览器和编辑器里也能用大键操控音乐；全部按键照常统计。应用内试奏无需授权。": "With Input Monitoring permission, big keys can shape music in documents, browsers and editors. All keys are still counted. Trying it inside the app needs no permission.",
        "已暂停 · 全局权限已授权": "Paused · Global access granted",
        "已暂停 · 尚未开启全局权限": "Paused · Global access not granted",
        "全局监听已生效": "Global monitoring is active",
        "当前仅在 KeyWoo 内生效": "Currently works only inside KeyWoo",
        "打开系统设置": "Open System Settings",
        "开启输入监控": "Enable Input Monitoring",
        "如果授权后仍未生效，请退出并重新打开 KeyWoo。安全输入启用时，键盘反馈与统计暂停，音乐继续播放。": "If access is granted but not active, quit and reopen KeyWoo. Secure Input pauses keyboard feedback and statistics; music keeps playing.",
        "你的输入，只属于你": "Your typing stays yours",
        "保存什么": "What is saved",
        "每分钟、每个物理键的累计次数。": "Cumulative counts for each physical key, by minute.",
        "不保存什么": "What is never saved",
        "输入文字、按键顺序、剪贴板和应用内容。": "Typed text, key order, clipboard data and app contents.",
        "保存在哪里": "Where it is saved",
        "本机应用数据目录，不上传网络。": "In the app's local data folder. Nothing is uploaded.",
        "统计精度": "Statistics detail",
        "分钟级。长按自动重复不计入；系统截获的媒体键不计入。": "Minute-level. Automatic key repeats and media keys intercepted by macOS are excluded.",
        "大键响应": "Big-key response",
        "空格轻推、退格回拨、Tab / Caps 扫频、Shift 按住展开；回车抬起，AI 模式还可衔接乐句。": "Space pushes, Delete pulls, Tab and Caps sweep, and holding Shift opens up the sound. Return lifts the music and can cue a phrase in AI mode.",
        "跟随输入": "Follow your input",
        "动作长短与力度随你的输入间隔调整；快打时变浅，停顿后再敲更清楚，不自动补拍。": "Gesture length and strength follow your input timing: lighter while typing fast, clearer after a pause. No beats are added automatically.",
        "小键静默": "Small keys stay quiet",
        "字母、数字、标点及方向键只统计，不触发音乐。Command / Control / Option / Fn 也保持静默。": "Letters, numbers, punctuation and arrows are counted without affecting music. Command, Control, Option and Fn also stay quiet.",
        "本地歌曲": "Local tracks",
        "导入歌曲由大键控制原曲强弱；完整 DJ 推拉用于内置与 AI 音乐。": "Big keys control the dynamics of imported tracks. Full DJ push and pull gestures work with built-in and AI music.",
        "安静陪伴，随时掌控": "A quiet companion, always in your control",
        "随手暂停": "Pause anytime",
        "点击右上角暂停，或在 KeyWoo 窗口内按 ⌘ ⇧ P；声音和统计一起暂停。": "Pause at the top right, or press ⌘ ⇧ P in the KeyWoo window. Sound and statistics pause together.",
        "只想统计": "Statistics only",
        "把音乐音量调至 0，仍会正常统计；按键影响为 0 时听原曲。": "Set music volume to 0 to keep counting in silence. Set key influence to 0 to hear the original track.",
        "留在菜单栏": "Stay in the menu bar",
        "关闭窗口后继续工作，从菜单栏的琴键图标重新打开。": "Keep working after closing the window. Reopen it from the keyboard icon in the menu bar.",
        "完全退出": "Quit completely",
        "按 ⌘ Q 或从菜单栏选择退出，会保存统计并停止监听。": "Press ⌘ Q or choose Quit from the menu bar to save statistics and stop monitoring.",
        "音乐已暂停 · 乐句已保留": "Music paused · Phrase preserved",
        "音乐继续 · 下一乐句暂时未就绪": "Music continues · The next phrase is not ready yet",
        "下一乐句已就绪 · 随输入自然衔接": "Next phrase ready · Your input guides the transition",
        "本机音乐模型尚未准备好，请先选择内置音乐。": "The local music model is not ready. Please choose a built-in track.",
        "无法载入初始乐句。": "The starting phrase could not be loaded.",
        "找不到初始音乐乐句。": "The starting music phrase could not be found.",
        "初始乐句格式不正确。": "The starting phrase has an invalid audio format.",
        "红轴": "Red switch",
        "青轴": "Blue switch",
        "茶轴": "Brown switch",
        "麻将": "Mahjong",
        "轻柔顺滑，低沉短促": "Smooth and muted, short and low",
        "清脆双段，明晰回弹": "Crisp click with a distinct return",
        "温暖段落，柔和触底": "Warm tactile bump, gentle bottom-out",
        "瓷牌碰击，圆润清亮": "Rounded, bright tile taps",
        "键盘音效无法启动，请重新开启音效。": "Keyboard sounds could not start. Please turn them on again.",
        "已暂停": "Paused",
        "键盘反馈已暂停 · 安全输入": "Keyboard feedback paused · Secure Input",
        "正在合奏 · 所有应用": "Playing together · All apps",
        "正在合奏 · 仅应用内": "Playing together · In this app",
        "所选音乐暂时无法播放，已保留当前音乐。": "The selected track could not play. The current music was preserved.",
        "文件暂时不可用": "File unavailable",
        "找不到这首本机音乐的副本。当前音乐会继续播放。": "The app's copy of this track could not be found. The current music will continue.",
        "这首音乐暂时无法播放，当前音乐保持不变。": "This track could not play. The current music is unchanged.",
        "加入你的音乐": "Add your music",
        "选择本机音频，陪你一起打字。原文件会保留。": "Choose local audio to accompany your typing. The original file will be preserved.",
        "加入音乐": "Add music",
    ]
}

func L(_ text: String) -> String {
    AppLocalization.localized(text, language: AppLocalization.language)
}
func Lf(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: L(format), locale: AppLocalization.locale, arguments: arguments)
}
