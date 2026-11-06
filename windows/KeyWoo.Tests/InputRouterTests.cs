using KeyWoo.Core;
using Xunit;
namespace KeyWoo.Tests;
public sealed class InputRouterTests {
    private static readonly PhysicalKey Caps=new(0x14,0x3A),Esc=new(0x1B,1),A=new(0x41,0x1E),F1=new(0x70,0x3B),Ctrl=new(0xA2,0x1D),Alt=new(0xA4,0x38);
    private static RoutingDecision Down(InputRouter r,PhysicalKey k)=>r.Process(new(k,true));
    private static RoutingDecision Up(InputRouter r,PhysicalKey k)=>r.Process(new(k,false));
    private static InputRouter Router(params InputRule[] rules){var r=new InputRouter();r.Configure(true,true,rules);return r;}
    [Fact] public void InjectionCannotRecursivelyCountOrRemap(){var r=Router(new InputRule(0x14,0,0x1B));var d=r.Process(new(Caps,true,true));Assert.False(d.Count||d.SoundDown||d.SoundUp||d.Suppress);Assert.Empty(d.Inject);Assert.Equal(0,r.HeldCount);}
    [Fact] public void RepeatsCountAndSoundOnlyOnce(){var r=new InputRouter();Assert.True(Down(r,A).Count);Assert.False(Down(r,A).SoundDown);Assert.True(Up(r,A).SoundUp);Assert.False(Up(r,A).SoundUp);}
    [Fact] public void MainAndKeypadEnterHaveSeparatePhysicalLifetimes(){var r=new InputRouter();var main=new PhysicalKey(13,28);var num=new PhysicalKey(13,28,true);Assert.True(Down(r,main).Count);Assert.True(Down(r,num).Count);Assert.Equal(2,r.HeldCount);Assert.True(Up(r,main).SoundUp);Assert.True(Up(r,num).SoundUp);}
    [Fact] public void SimpleMappingPairsOutputAndCountsOriginal(){var r=Router(new InputRule(0x14,0,0x1B));var down=Down(r,Caps);Assert.True(down.Count&&down.Suppress);Assert.Equal([new KeyInjection(0x1B,true)],down.Inject);Assert.Equal([new KeyInjection(0x1B,false)],Up(r,Caps).Inject);Assert.Equal(0,r.MappedHeldCount);}
    [Fact] public void PauseReleasesOutputAndSwallowsLateSourceUp(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Caps);Assert.Equal([new KeyInjection(0x1B,false)],r.Configure(false,true,[]));Assert.True(Up(r,Caps).Suppress);Assert.False(Down(r,A).Count);}
    [Fact] public void TwoSourcesShareOneTargetLifetime(){var r=Router(new InputRule(0x14,0,0x1B),new(0x70,0,0x1B));Assert.Single(Down(r,Caps).Inject);Assert.Empty(Down(r,F1).Inject);Assert.Empty(Up(r,Caps).Inject);Assert.Equal([new KeyInjection(0x1B,false)],Up(r,F1).Inject);}
    [Fact] public void PhysicalTargetReleaseDoesNotReleaseMappedHold(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Caps);Assert.False(Down(r,Esc).Suppress);Assert.True(Up(r,Esc).Suppress);Assert.Single(Up(r,Caps).Inject);}
    [Fact] public void MappingReleaseDoesNotReleaseStillPhysicalTarget(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Esc);Assert.Empty(Down(r,Caps).Inject);Assert.Empty(Up(r,Caps).Inject);Assert.False(Up(r,Esc).Suppress);}
    [Fact] public void SuppressedPhysicalTargetDoesNotRetainAnotherMappedOutput(){var b=new PhysicalKey(0x42,0x30);var r=Router(new InputRule(0x41,0,0x42),new(0x42,0,0x43));Down(r,b);Assert.Equal([new KeyInjection(0x42,true)],Down(r,A).Inject);Assert.Equal([new KeyInjection(0x42,false)],Up(r,A).Inject);Assert.Equal([new KeyInjection(0x43,false)],Up(r,b).Inject);}
    [Fact] public void PauseReleasesBothOutputsWhenTheirSourcesAreRemapped(){var b=new PhysicalKey(0x42,0x30);var r=Router(new InputRule(0x41,0,0x42),new(0x42,0,0x43));Down(r,A);Down(r,b);var releases=r.Configure(false,true,[]);Assert.Contains(new KeyInjection(0x42,false),releases);Assert.Contains(new KeyInjection(0x43,false),releases);Assert.Equal(2,releases.Length);Assert.True(Up(r,A).Suppress);Assert.True(Up(r,b).Suppress);}
    [Fact] public void ShortcutTemporarilyClearsUnwantedModifierAndRestoresIt(){var r=Router(new InputRule(0x41,KeyModifiers.Alt,0x43,KeyModifiers.Control));Down(r,Alt);var d=Down(r,A);Assert.True(d.Suppress);Assert.Equal([new(0xA4,false),new(0xA2,true),new(0x43,true),new(0x43,false),new(0xA2,false),new KeyInjection(0xA4,true)],d.Inject);Assert.Empty(Down(r,A).Inject);Assert.True(Up(r,A).Suppress);Assert.False(Up(r,Alt).Suppress);}
    [Fact] public void ShortcutDoesNotLiftAlreadyPhysicalTarget(){var b=new PhysicalKey(0x42,0x30);var r=Router(new InputRule(0x41,0,0x42,KeyModifiers.Control));Down(r,b);var d=Down(r,A);Assert.DoesNotContain(new KeyInjection(0x42,false),d.Inject);Assert.False(Up(r,b).Suppress);}
    [Fact] public void RemappedControlParticipatesInShortcutMatching(){var r=Router(new InputRule(0x14,0,0xA2),new(0x41,KeyModifiers.Control,0xB3));Down(r,Caps);var d=Down(r,A);Assert.True(d.Suppress);Assert.Contains(new KeyInjection(0xB3,true),d.Inject);Assert.Contains(new KeyInjection(0xA2,false),d.Inject);Assert.Equal(new KeyInjection(0xA2,true),d.Inject[^1]);}
    [Fact] public void FailedInjectionAllowsOriginalPairAndDisablesMapping(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Caps);r.InjectionFailed(Caps.Id);Assert.False(r.MappingEnabled);Assert.False(Up(r,Caps).Suppress);Assert.False(Down(r,Caps).Suppress);}
    [Fact] public void SessionLockDropsStalePhysicalStateAfterReleasingTarget(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Caps);Assert.Single(r.SuspendSession());r.Configure(true,true,[new(0x14,0,0x1B)]);Assert.True(Down(r,Caps).Count);}
    [Fact] public void BareKeyMappingStillAppliesInsidePhysicalModifierChord(){var r=Router(new InputRule(0x14,0,0x1B));Down(r,Ctrl);var d=Down(r,Caps);Assert.True(d.Suppress);Assert.Equal([new KeyInjection(0x1B,true)],d.Inject);Assert.DoesNotContain(new KeyInjection(0xA2,false),d.Inject);}
    [Fact] public void ExactModifiersAvoidStealingMoreSpecificShortcuts(){var r=Router(new InputRule(0x41,KeyModifiers.Control,0xB3));Down(r,Ctrl);Down(r,Alt);Assert.False(Down(r,A).Suppress);}
    [Fact] public void ScanMappingDistinguishesModifiersAndKeypad(){Assert.Equal(59,Ctrl.MacCode);Assert.Equal(62,new PhysicalKey(0xA3,0x1D,true).MacCode);Assert.Equal(76,new PhysicalKey(13,28,true).MacCode);Assert.Equal(0,A.MacCode);}
    [Fact] public void PhysicalAndMappedControlShareOneOsLifetime(){var r=Router(new InputRule(0x14,0,0xA2));Down(r,Ctrl);Assert.Empty(Down(r,Caps).Inject);Assert.True(Up(r,Ctrl).Suppress);Assert.Equal([new KeyInjection(0xA2,false)],Up(r,Caps).Inject);}
    [Fact] public void LeftPhysicalControlDoesNotRetainRightMappedControl(){var r=Router(new InputRule(0x14,0,0xA3));Down(r,Ctrl);Assert.Equal([new KeyInjection(0xA3,true)],Down(r,Caps).Inject);Assert.Equal([new KeyInjection(0xA3,false)],Up(r,Caps).Inject);Assert.False(Up(r,Ctrl).Suppress);}
    [Fact] public void ReconfiguredRightAltStaysHiddenUntilItsActualRelease(){var rightAlt=new PhysicalKey(0xA5,0x38,true);var rule=new InputRule(0x41,KeyModifiers.Alt,0xB3);var r=Router(new InputRule(0xA5,0,0xA2));Down(r,rightAlt);Assert.Equal([new KeyInjection(0xA2,false)],r.Configure(true,true,[rule]));Assert.True(Down(r,rightAlt).Suppress);Assert.False(Down(r,A).Suppress);Up(r,A);Assert.True(Up(r,rightAlt).Suppress);Assert.False(Down(r,rightAlt).Suppress);Assert.True(Down(r,A).Suppress);}
    [Fact] public void TargetHeldBeforeStartupKeepsOwnershipUntilItsRealRelease(){var b=new PhysicalKey(0x42,0x30);var r=Router(new InputRule(0x41,0,0x42));r.SeedVisibleKeys([0x42]);Assert.Empty(Down(r,A).Inject);Assert.Empty(Up(r,A).Inject);Assert.False(Up(r,b).Suppress);Assert.Equal([new KeyInjection(0x42,true)],Down(r,A).Inject);Assert.Equal([new KeyInjection(0x42,false)],Up(r,A).Inject);}
    [Fact] public void PreexistingTargetUpCannotReleaseAStillMappedOwner(){var b=new PhysicalKey(0x42,0x30);var r=Router(new InputRule(0x41,0,0x42));r.SeedVisibleKeys([0x42]);Down(r,A);Assert.True(Up(r,b).Suppress);Assert.Equal([new KeyInjection(0x42,false)],Up(r,A).Inject);}
    [Fact] public void PreexistingSourceRepeatsAreNotCountedOrRebound(){var r=Router(new InputRule(0x14,0,0x1B));r.SeedVisibleKeys([0x14]);var repeat=Down(r,Caps);Assert.False(repeat.Count||repeat.SoundDown||repeat.Suppress);Assert.Empty(repeat.Inject);Assert.False(Up(r,Caps).SoundUp);Assert.True(Down(r,Caps).Count);Assert.Single(Up(r,Caps).Inject);}
    [Fact] public void PreexistingRightControlMatchesChordAndIsNotReleasedByPause(){var r=Router(new InputRule(0x41,KeyModifiers.Control,0xB3));r.SeedVisibleKeys([0xA3]);Assert.True(Down(r,A).Suppress);Assert.DoesNotContain(new KeyInjection(0xA3,false),r.Configure(false,true,[]));Assert.False(Up(r,new(0xA3,0x1D,true)).Suppress);}
    [Fact] public void PreexistingEnterUsesActualUpScanAndUnlockDropsOldSnapshot(){var r=new InputRouter();r.SeedVisibleKeys([13]);Assert.Equal(1,r.HeldCount);Assert.False(Up(r,new(13,28,true)).Suppress);Assert.Equal(0,r.HeldCount);r.SeedVisibleKeys([0xA5]);r.SuspendSession();Assert.Equal(0,r.HeldCount);r.SeedVisibleKeys([0xA2]);r.Configure(true,false,[]);Assert.True(Down(r,A).Count);Assert.False(Up(r,Ctrl).SoundUp);}

    [Fact] public void CatalogExposesNamedKeysInUniqueCategories() {
        var choices = KeyboardKeys.Choosable.ToArray();
        Assert.Equal(choices.Length, choices.Distinct().Count());
        Assert.All(choices, key => Assert.False(KeyboardKeys.Name(key).StartsWith("VK ")));
        Assert.Contains(0x87, choices); // F24
        Assert.Contains(0x2C, choices); // Print Screen
        Assert.Contains(0x6F, choices); // Keypad divide
        Assert.Contains(0xE2, choices); // ISO extra key
        Assert.Contains(0x1D, choices); // JIS non-convert
        Assert.Equal("下一首", KeyboardKeys.Name(0xB0, chinese: true));
        Assert.Equal("上一首", KeyboardKeys.Name(0xB1, chinese: true));
    }

    [Theory]
    [InlineData(0xA6)] // Browser back
    [InlineData(0xB0)] // Next track
    [InlineData(0xB1)] // Previous track
    [InlineData(0xB4)] // Open mail
    public void ActionTargetFiresOneTapPerSourcePress(int target) {
        var router = Router(new InputRule(0x41, KeyModifiers.None, target));
        Assert.True(KeyboardKeys.RequiresExtendedInjection(target));
        var down = Down(router, A);
        Assert.True(down.Count && down.Suppress);
        Assert.Equal([new KeyInjection(target, true), new KeyInjection(target, false)], down.Inject);
        Assert.Empty(Down(router, A).Inject);
        var up = Up(router, A);
        Assert.True(up.Suppress);
        Assert.Empty(up.Inject);
        Assert.Equal(down.Inject, Down(router, A).Inject);
    }

    [Fact] public void MediaKeyCanBeSourceForHeldFunctionKey() {
        var previous = new PhysicalKey(0xB1, 0x10, true);
        var router = Router(new InputRule(0xB1, KeyModifiers.None, 0x87));
        var down = Down(router, previous);
        Assert.True(down.Count && down.Suppress);
        Assert.Equal([new KeyInjection(0x87, true)], down.Inject);
        Assert.Equal([new KeyInjection(0x87, false)], Up(router, previous).Inject);
    }

    [Fact] public void PauseWithoutPhysicalReleaseRemapsAsBalancedRepeatedTaps() {
        var pause = new PhysicalKey(0x13, 0x45);
        var router = Router(new InputRule(0x13, KeyModifiers.None, 0x41));
        router.SeedVisibleKeys([0x13]);
        for (int i = 0; i < 2; i++) {
            var tap = Down(router, pause);
            Assert.True(tap.Count && tap.SoundDown && tap.SoundUp && tap.Suppress);
            Assert.Equal([new KeyInjection(0x41, true), new KeyInjection(0x41, false)], tap.Inject);
            Assert.Equal(0, router.HeldCount);
            Assert.Equal(0, router.MappedHeldCount);
        }
    }

    [Fact] public void PauseRemappingDoesNotReleaseAnAlreadyHeldTarget() {
        var router = Router(new InputRule(0x13, KeyModifiers.None, 0x41));
        Down(router, A);
        Assert.Empty(Down(router, new PhysicalKey(0x13, 0x45)).Inject);
        Assert.False(Up(router, A).Suppress);
    }

    [Fact] public void ConsumedSpaceAndHardwareMediaKeepOnePhysicalSoundAndCount() {
        var space=new PhysicalKey(0x20,0x39);
        var media=new PhysicalKey(0xB3,0x22,true);
        var router=Router(new InputRule(0x20,KeyModifiers.Control|KeyModifiers.Alt,0xB3));
        Down(router,Ctrl);Down(router,Alt);
        var spaceDown=Down(router,space);
        Assert.True(spaceDown.Suppress&&spaceDown.SoundDown&&spaceDown.Count);
        Assert.False(Down(router,space).SoundDown);
        Assert.True(Up(router,space).SoundUp);
        Up(router,Ctrl);Up(router,Alt);
        foreach(var injection in spaceDown.Inject) {
            var ignored=router.Process(new(media,injection.Down,true));
            Assert.False(ignored.SoundDown||ignored.SoundUp||ignored.Count);
        }
        var physicalMedia=Down(router,media);
        Assert.True(physicalMedia.SoundDown&&physicalMedia.Count);
        Assert.False(Down(router,media).SoundDown);
        Assert.True(Up(router,media).SoundUp);
    }
}
