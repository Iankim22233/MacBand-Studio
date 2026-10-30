# MacBand Studio for iPhone and iPad

The same app as the Mac version, sharing its code (`../Sources/MacBandStudio`): the song model, the audio engine, MIDI import and
export, notation, Vocal Tune, the visualizers and the projects are the same code on both. What differs is the touch layer and the
layout (`Sources/`).

## What is the same, what isn't

| | iOS |
|---|---|
| Arrangement, piano roll, step sequencer, score, mixer, visualizers, Vocal Tune | yes, all touch-driven |
| Project files (`.macband`) | the same files; they open on both |
| Sounds | the 128 General MIDI sounds and 9 drum kits come from a bundled SoundFont (GeneralUser GS, by S. Christian Collins, licence in `Resources/GeneralUser_GS_LICENSE.txt`), played by the app's own SoundFont synthesizer (`Sources/SF2Synth.swift`; Apple's iOS sampler crashed on this file). Your own `.sf2` files can be added (Sound Library ▸ +, or drop them into the app's folder in the Files app); `.dls` and `.exs` are not supported on iOS |
| Plugins (VST3, Audio Units) | **not hosted on iOS.** A track that used one plays its General MIDI sound instead |
| GarageBand, Logic and macOS sampler instruments | not available (they are Mac files); SoundFonts are the way to bring sounds over |
| GarageBand import | File picker: project menu ▸ Import ▸ Project or GarageBand Project… (the automatic first-launch import is Mac only) |

## Where things are

* Projects: the Files app ▸ On My iPhone ▸ **MacBand Studio**. Copy `.macband` files there to open them on the phone, or share one from the
  project chooser. A song's audio is kept in a folder called `<name> Audio` beside it: copy that folder too.
* SoundFonts: `MacBand Studio/Sounds` in the same place.

## Touch controls

* **Tracks page:** tap a clip to select; drag to move; drag its right end to resize; double-tap an empty spot to make a pattern; double-tap a
  clip to open it in the piano roll; tap the ruler to move the playhead; drag in the strip above the ruler for a loop; tap the tempo lane to add a
  tempo change. Two fingers scroll, a pinch zooms. Press and hold a clip for its menu.
* **Piano roll:** the toolbar has Draw / Select / Erase and a **Hand** tool (one finger scrolls). The ✓ button is multi-select (it is the Shift key).
  Undo, redo, duplicate, delete, transpose and the velocity lane are buttons. Two fingers always scroll; a pinch zooms.
* **Piano button (top right):** an on-screen keyboard for the selected instrument; with Record on it records what you play.
* The app is locked to landscape. On an iPad with a keyboard: Space plays, Return goes to the start,
  ⌘Z / ⇧⌘Z undo and redo, ⌘S saves, ⌘O opens, C metronome, R record, L loop.

## Building

You need Xcode and, only if you change `project.yml`, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`, then `xcodegen generate` in this folder).

**Simulator:**

```bash
xcodebuild -project MacBandStudioiOS.xcodeproj -scheme MacBandStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "iPhone 17" "build/Build/Products/Debug-iphonesimulator/MacBand Studio.app"
xcrun simctl launch "iPhone 17" com.macband.studio.ios
```

**Your iPhone:** open `MacBandStudioiOS.xcodeproj` in Xcode, select the **MacBandStudio** target ▸ Signing & Capabilities ▸ pick your Team (a
free Apple ID works), connect the phone, choose it as the destination and press Run. If Xcode says the bundle identifier is taken, change
`PRODUCT_BUNDLE_IDENTIFIER` (in `project.yml`, or in Xcode) to something of your own.

## Testing

Launch arguments (in the Simulator: `xcrun simctl launch --console-pty <device> com.macband.studio.ios <args>`):

* `--selfcheck`: loads the demo song through the SoundFont, renders it, checks the sounds, MIDI round trip, save / open / undo, sheet-music PDF,
  GarageBand import, the scrolling waveform and Vocal Tune's pitch finding. Prints `SELF CHECK PASSED`.
* `--landscape`: turns the Simulator screen (its own rotation is unreliable, and its touches are wrong once rotated).
* `--demo-song [--demo-panel editor|steps|score|visual|tune|mixer|inspector|projects|intro|sounds] [--demo-visual Wave|Circle|Rings|…] [--demo-keys] [--demo-play]`
  opens the demo song on a page, for screenshots.
