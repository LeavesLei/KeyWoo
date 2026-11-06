# KeyWoo third-party notices

KeyWoo's recorded sounds and dependencies retain their respective licenses.
Product names identify recordings; they do not imply endorsement or affiliation.
The KeyWoo project itself has not been assigned an open-source license.

## Recorded sounds

| Source / author | Included recordings | Published license |
| --- | --- | --- |
| Mechvibes / Hải Nguyễn | Ten Cherry, Everglide and Topre packs | MIT |
| kbsim / Thomas Lai | Holy Panda only | MIT |
| BigSoundBank / Joseph Sardin | MacBook Pro, Hermes typewriter, wooden-desk taps | CC0 1.0 |
| Freesound / Detective_Lemons | Mahjong tiles falling on corkboard | CC0 1.0 |

The [full sound notices](Sources/KeyDance/Resources/KeyboardSounds/THIRD-PARTY-NOTICES.md)
identify each source, pinned repository commit, recording attribution and edits.
The [Mechvibes MIT notice](Sources/KeyDance/Resources/KeyboardSounds/Mechvibes-LICENSE)
and [kbsim MIT notice](Sources/KeyDance/Resources/KeyboardSounds/kbsim-LICENSE.md)
must accompany redistribution of these assets. CC0 source references are
[BigSoundBank's license](https://bigsoundbank.com/licenses.html) and
[the Mahjong recording page](https://freesound.org/people/Detective_Lemons/sounds/785585/).

`SOURCE-FILES.json` records the downloaded URLs, file sizes and hashes.
`manifest.json` records the exported clips and their processing. Hi-Fi variants
are processed versions of the same recordings and retain their source licenses.
KeyWoo generates the synthesized effects, including Street Beat.
No audio was copied from ZF / zFrontier forum discussions.

Installed sound notices are in:

- macOS: `KeyWoo.app/Contents/Resources/KeyboardSounds/`
- Windows: `Assets/KeyboardSounds/`

## Windows audio and runtime

Windows uses [NAudio 2.2.1](https://github.com/naudio/NAudio/tree/v2.2.1),
Copyright Mark Heath, under MIT. Its full license is included in
[`windows/licenses/NAudio-LICENSE.txt`](windows/licenses/NAudio-LICENSE.txt).
Self-contained Windows packages also include the .NET runtime's license and
third-party notices under `Licenses/` beside the application.

## Internal music experiment

The source tree retains an unpublished music experiment, whose
[notice](Sources/KeyDance/Resources/AI/NOTICE.md) identifies its model and library.
The v1.0 application packages exclude its music recordings and model worker;
no model weights are included. This component is not a v1.0 user feature.
