namespace KeyWoo.Core;

[Flags]
public enum KeyModifiers { None = 0, Control = 1, Alt = 2, Shift = 4, Windows = 8 }
public readonly record struct PhysicalKey(int VirtualKey, int ScanCode, bool Extended = false) {
    public int Id => ScanCode > 0 && !KeyboardKeys.IsDownOnly(VirtualKey) ? (ScanCode & 255) | (Extended ? 256 : 0) : 4096 | VirtualKey;
    public int MacCode => KeyboardKeys.MacCode(this);
}
public readonly record struct KeyPacket(PhysicalKey Key, bool Down, bool Injected = false);
public readonly record struct KeyInjection(int VirtualKey, bool Down);
public sealed record InputRule(int Source, KeyModifiers Modifiers, int Target, KeyModifiers TargetModifiers = KeyModifiers.None);
public enum KeyCategory { Media, Function, Editing, Numpad, Modifiers, Typing, Browser, System }

public static class KeyboardKeys {
    public static bool IsModifier(int vk) => vk is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5;
    public static KeyModifiers Modifier(int vk) => vk switch {
        0x10 or 0xA0 or 0xA1 => KeyModifiers.Shift,
        0x11 or 0xA2 or 0xA3 => KeyModifiers.Control,
        0x12 or 0xA4 or 0xA5 => KeyModifiers.Alt,
        0x5B or 0x5C => KeyModifiers.Windows, _ => KeyModifiers.None
    };
    public static readonly int[] ModifierKeys = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
    public static readonly (KeyModifiers Modifier, int Key)[] CanonicalModifiers = [
        (KeyModifiers.Control, 0xA2), (KeyModifiers.Alt, 0xA4), (KeyModifiers.Shift, 0xA0), (KeyModifiers.Windows, 0x5B)
    ];
    public static bool IsDownOnly(int key) => key == 0x13; // Pause sends a single down event.
    public static bool IsOneShot(int key) => IsDownOnly(key) || key is >= 0xA6 and <= 0xB7;
    public static bool RequiresExtendedInjection(int key) => key is
        0x03 or 0x2C or 0x2D or 0x2E or >= 0x21 and <= 0x28 or 0x5B or 0x5C or 0x5D
        or 0x6F or 0x90 or 0xA3 or 0xA5 or >= 0xA6 and <= 0xB7;
    public static int NormalizeVirtualKey(int vk, int scan, bool extended) => vk switch {
        0x10 => scan == 0x36 ? 0xA1 : 0xA0,
        0x11 => extended ? 0xA3 : 0xA2,
        0x12 => extended ? 0xA5 : 0xA4, _ => vk
    };
    // Hardware scan positions, independent of typed text, share the macOS corpus.
    private static readonly Dictionary<int, int> ScanToMac = new() {
        [0x01]=53,[0x02]=18,[0x03]=19,[0x04]=20,[0x05]=21,[0x06]=23,[0x07]=22,[0x08]=26,[0x09]=28,[0x0A]=25,[0x0B]=29,
        [0x0C]=27,[0x0D]=24,[0x0E]=51,[0x0F]=48,[0x10]=12,[0x11]=13,[0x12]=14,[0x13]=15,[0x14]=17,[0x15]=16,[0x16]=32,[0x17]=34,[0x18]=31,[0x19]=35,
        [0x1A]=33,[0x1B]=30,[0x1C]=36,[0x1D]=59,[0x1E]=0,[0x1F]=1,[0x20]=2,[0x21]=3,[0x22]=5,[0x23]=4,[0x24]=38,[0x25]=40,[0x26]=37,[0x27]=41,[0x28]=39,[0x29]=50,
        [0x2A]=56,[0x2B]=42,[0x2C]=6,[0x2D]=7,[0x2E]=8,[0x2F]=9,[0x30]=11,[0x31]=45,[0x32]=46,[0x33]=43,[0x34]=47,[0x35]=44,[0x36]=60,[0x37]=67,[0x38]=58,[0x39]=49,[0x3A]=57,
        [0x3B]=122,[0x3C]=120,[0x3D]=99,[0x3E]=118,[0x3F]=96,[0x40]=97,[0x41]=98,[0x42]=100,[0x43]=101,[0x44]=109,[0x45]=71,
        [0x47]=89,[0x48]=91,[0x49]=92,[0x4A]=78,[0x4B]=86,[0x4C]=87,[0x4D]=88,[0x4E]=69,[0x4F]=83,[0x50]=84,[0x51]=85,[0x52]=82,[0x53]=65,[0x56]=10,[0x57]=103,[0x58]=111
    };
    private static readonly Dictionary<int, int> ExtendedToMac = new() {
        [0x1C]=76,[0x1D]=62,[0x35]=75,[0x38]=61,[0x47]=115,[0x48]=126,[0x49]=116,[0x4B]=123,[0x4D]=124,[0x4F]=119,[0x50]=125,[0x51]=121,[0x52]=114,[0x53]=117,[0x5B]=55,[0x5C]=54
    };
    public static int MacCode(PhysicalKey key) => (key.Extended ? ExtendedToMac : ScanToMac).GetValueOrDefault(key.ScanCode, 65535);
    private static readonly Dictionary<int, (string English, string Chinese)> NamedKeys = new() {
        [0x03]=("Break", "中断"), [0x08]=("Backspace", "退格"), [0x09]=("Tab", "制表键"),
        [0x0D]=("Enter", "回车"), [0x13]=("Pause", "暂停键"), [0x14]=("Caps Lock", "大写锁定"),
        [0x15]=("Kana / Hangul", "假名／韩文"), [0x1B]=("Esc", "Esc"), [0x1C]=("IME convert", "输入法转换"),
        [0x1D]=("IME non-convert", "输入法无转换"), [0x20]=("Space", "空格"),
        [0x21]=("Page Up", "向上翻页"), [0x22]=("Page Down", "向下翻页"), [0x23]=("End", "行尾"), [0x24]=("Home", "行首"),
        [0x2C]=("Print Screen", "截屏键"), [0x2D]=("Insert", "插入"), [0x2E]=("Delete", "删除"),
        [0x5B]=("Left Win", "左 Win"), [0x5C]=("Right Win", "右 Win"), [0x5D]=("Context menu", "右键菜单"),
        [0x90]=("Num Lock", "数字锁定"), [0x91]=("Scroll Lock", "滚动锁定"),
        [0xA0]=("Left Shift", "左 Shift"), [0xA1]=("Right Shift", "右 Shift"), [0xA2]=("Left Ctrl", "左 Ctrl"),
        [0xA3]=("Right Ctrl", "右 Ctrl"), [0xA4]=("Left Alt", "左 Alt"), [0xA5]=("Right Alt", "右 Alt"),
        [0xA6]=("Browser back", "浏览器后退"), [0xA7]=("Browser forward", "浏览器前进"),
        [0xA8]=("Browser refresh", "刷新网页"), [0xA9]=("Browser stop", "停止加载网页"),
        [0xAA]=("Browser search", "浏览器搜索"), [0xAB]=("Browser favorites", "浏览器收藏夹"), [0xAC]=("Browser home", "浏览器主页"),
        [0xAD]=("Mute", "静音"), [0xAE]=("Volume −", "减小音量"), [0xAF]=("Volume +", "增大音量"),
        [0xB0]=("Next track", "下一首"), [0xB1]=("Previous track", "上一首"), [0xB2]=("Stop media", "停止播放"),
        [0xB3]=("Play / pause", "播放／暂停"), [0xB4]=("Open mail", "打开邮件"),
        [0xB5]=("Select media", "打开媒体应用"), [0xB6]=("Launch app 1", "启动应用 1"), [0xB7]=("Launch app 2", "启动应用 2"),
        [0xE2]=("ISO extra key", "ISO 附加键")
    };
    public static string Name(int vk, bool chinese = false) {
        if (NamedKeys.TryGetValue(vk, out var label)) return chinese ? label.Chinese : label.English;
        return vk switch {
        >=0x41 and <=0x5A or >=0x30 and <=0x39 => ((char)vk).ToString(),
        >=0x70 and <=0x87 => $"F{vk - 0x6F}",
            0x25=>"←",0x26=>"↑",0x27=>"→",0x28=>"↓",
            >=0x60 and <=0x69=>$"Num {vk-0x60}",0x6A=>"Num ×",0x6B=>"Num +",0x6C=>"Num Separator",0x6D=>"Num −",0x6E=>"Num .",0x6F=>"Num ÷",
            0xBA=>";",0xBB=>"=",0xBC=>",",0xBD=>"−",0xBE=>".",0xBF=>"/",0xC0=>"`",0xDB=>"[",0xDC=>"\\",0xDD=>"]",0xDE=>"'", _=>$"VK {vk:X2}"
        };
    }
    public static string Chord(int key, KeyModifiers modifiers, bool chinese = false) =>
        string.Join(" + ", CanonicalModifiers.Where(m => modifiers.HasFlag(m.Modifier)).Select(m => Name(m.Key).Replace("Left ", "")).Append(Name(key, chinese)));
    public static IEnumerable<(KeyCategory Category, IEnumerable<int> Keys)> KeyGroups {
        get {
            yield return (KeyCategory.Media, [0xB3,0xB1,0xB0,0xB2,0xAF,0xAE,0xAD]);
            yield return (KeyCategory.Function, Enumerable.Range(0x70,24));
            yield return (KeyCategory.Editing, [0x1B,0x08,0x09,0x0D,0x20,0x2D,0x2E,0x24,0x23,0x21,0x22,0x25,0x26,0x27,0x28]);
            yield return (KeyCategory.Numpad, Enumerable.Range(0x60,16).Prepend(0x90));
            yield return (KeyCategory.Modifiers, ModifierKeys.Prepend(0x14));
            yield return (KeyCategory.Typing, Enumerable.Range(0x41,26).Concat(Enumerable.Range(0x30,10))
                .Concat([0xBA,0xBB,0xBC,0xBD,0xBE,0xBF,0xC0,0xDB,0xDC,0xDD,0xDE,0xE2]));
            yield return (KeyCategory.Browser, Enumerable.Range(0xA6,7));
            yield return (KeyCategory.System, [0x2C,0x13,0x03,0x91,0x5D,0xB4,0xB5,0xB6,0xB7,0x15,0x1C,0x1D]);
        }
    }
    public static IEnumerable<int> Choosable => KeyGroups.SelectMany(group => group.Keys);
}
