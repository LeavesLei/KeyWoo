# Recorded keyboard sounds used by KeyWoo / 键舞

The catalogue uses twelve keyboard recordings and three recorded foley presets
from the sources below. Nine other effects use original KeyWoo synthesis.

## Mechvibes — Hải Nguyễn

Repository: https://github.com/hainguyents13/mechvibes

Pinned commit: `e94ad2fd9a31e77c8a3c9dc5617d6ac91eb581df`

Source directory: `soundpacks/keyboard/`

Used packs: `cherrymx-red-abs`, `cherrymx-blue-abs`, `cherrymx-brown-pbt`,
`cherrymx-black-pbt`, `eg-oreo`, `eg-crystal-purple`, and
`topre-purple-hybrid-pbt`, plus `cherrymx-blue-pbt`, `cherrymx-brown-abs` and
`cherrymx-black-abs`. Their upstream configurations identify the author as
Mechvibes. The original Cherry recordings were present in Hải Nguyễn's earlier
Mechvibes repository; this is repository author attribution, not a claim that
KeyWoo independently witnessed the recording sessions.

License: MIT, Copyright (c) 2026 Hải Nguyễn. The full notice is included in
`Mechvibes-LICENSE` and applies under the upstream repository's published license.
No NovelKeys Cream/Ryan pack or other known third-party video excerpts were used.

## Holy Panda — Thomas Lai / kbsim

Repository: https://github.com/tplai/kbsim

Pinned commit: `ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4`

Source directory: `src/assets/audio/holypanda/`

License: MIT, Copyright (c) Thomas Lai. The full notice is included in
`kbsim-LICENSE.md`. The author's discussion identifies Holy Panda as his own
keyboard recordings, while other kbsim packs were sampled from videos. Only
Holy Panda is used here. Primary discussion:
https://www.reddit.com/r/MechanicalKeyboards/comments/kpl3ta/i_made_a_mechanical_keyboard_simulator_kbsim/

The source supplies five generic press variants and dedicated Space, Enter and
Backspace press/release files. Other keys use the recorded generic sounds; they
are not represented as individually recorded Holy Panda keys.

## BigSoundBank — Joseph Sardin

The following releases are under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
The creator's [license page](https://bigsoundbank.com/licenses.html) confirms
redistribution and adaptation. KeyWoo uses the public Ogg versions.

- **MacBook Pro Keyboard** uses [Slow MacBook Pro keyboard #2](https://bigsoundbank.com/slow-macbook-pro-keyboard-2-s1729.html).
  Ten source windows supply paired contacts. Their original key positions are
  unlabelled. Space, Return and Backspace use distinct pools selected by sound.
- **Hermes Typewriter** uses recordings of a Hermes Precisa 305. Space uses the
  recorded space bar. Return plays a shortened decay from the machine's margin
  bell. Ordinary keys and Backspace use different pools of typebar strikes.
  Sources are [Key](https://bigsoundbank.com/typewriter-key-s2842.html),
  [Space](https://bigsoundbank.com/typewriter-space-s2843.html),
  [Bell #2](https://bigsoundbank.com/typewriter-bell-s2845.html) and
  [Typing #6](https://bigsoundbank.com/typewriter-6-s2839.html).
- **Wooden Desk** uses [Impatient finger tapping #2](https://bigsoundbank.com/impatient-finger-tapping-2-s1428.html).
  The selected individual hits use softer variations for ordinary keys and
  distinct contacts for Space, Return and Backspace.

## Mahjong Tiles — Detective_Lemons / Freesound

**Mahjong Tiles** uses the author's [tiles fall on corkboard](https://freesound.org/people/Detective_Lemons/sounds/785585/)
recording, released under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
KeyWoo uses eight short excerpts from the public high-quality preview, with
separate selections for ordinary keys, Space, Return and Backspace.

## Processing and limitations

`SOURCE-FILES.json` preserves every downloaded source URL, byte count, and SHA-256.
`manifest.json` preserves per-clip source windows, trim information, physical-key
mapping, release availability, pack-wide gain, output hashes and sample offsets.

Recordings were resampled to 48 kHz, kept stereo (mono duplicated), lightly
trimmed around actual sound and given tiny edge fades. One gain per keyboard
preserves within-board differences. No pitch shifting, generated variations,
heavy EQ, or per-key loudness normalization was used to invent extra models.

Mechvibes V2's midpoint timing split was not used as evidence of separate
actuation/release recordings. We inspect the complete original tap window:
only two energetic contacts separated by a clear quiet gap are split; ambiguous
windows play as a complete one-shot on press and produce no extra sound on
release. This is signal-based segmentation, not a claim of ground-truth switch
contact timestamps. Holy Panda's separate files retain their upstream roles.
Hermes, Mahjong Tiles and Wooden Desk play complete one-shots on press.
Their one-shots keep the contact detail inside the selected window and use
silence on key release. A short fade where a recorded tail was shortened keeps
rapid typing from stacking long tails.

Product and switch names identify the upstream recordings and do not imply
endorsement or affiliation with the switch manufacturers.

## Original generated effects

The original Mahjong, Typewriter, Bubble, Woodblock, Paper, Raindrop, Brick,
Arcade and Laser presets are deterministic procedural effects generated by
KeyWoo. The recording presets have separate names and settings IDs.
`synthetic-manifest.json` describes exported pre-volume stereo Float32 WAVs of
the same cache used by the native engine, including all six key families, both
edges and three variants. These are shared application assets, not claims of
physical material recordings.

## Community research boundary

ZF / zFrontier and other keyboard communities were consulted for sound
preferences and vocabulary only. No sounds or video audio were copied from
those discussions. The independently licensed source repositories above are
the sources of the recorded presets. The Mechvibes samples come from the pinned
official repository packs listed here.
