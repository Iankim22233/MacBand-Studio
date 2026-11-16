# MacBand Studio

A bigger sibling of MacBand: the same simple, uncluttered DAW (VST3 + AU hosting, MIDI and band-project import/export,
tempo lane, volume automation, slide notes, Vocal Tune) with a sheet music editor, a huge sound library, drum tools
and a Vista-style interface.

**iPhone and iPad:** the same app runs on iOS, sharing this code: see [iOS/README.md](iOS/README.md).

Build: `./build.sh` → `MacBand Studio.app`. It has its own settings folder (`~/Library/Application Support/MacBand Studio`)
and bundle id (`com.macband.studio`), so it never touches MacBand's data. Projects (`.macband`) open in both.

## The look

Every clickable thing is a sharp square with a thin white frame and a vertical gradient (light at the top, saturated
at the bottom), set in Tahoma. Toggles that are off are the same face in a dimmer colour; pressed buttons darken.
That covers buttons, tabs, menus, track and mixer rows, colour swatches, checkboxes, steppers, list rows, and the
sliders and faders (square glossy thumb on a filled bar).

The colour follows the system accent colour. **View ▸ Button Color** can fix it to red, blue, green, orange, purple or
graphite instead.

## Sounds (⌘B or the instrument button in the Inspector)

The Sound Library lists everything that can make sound, with search, categories and an audition button (click a sound
to hear it, double-click to use it):

| Source | What |
|---|---|
| General MIDI | the 128 built-in sounds and **9 drum kits** (Standard, Room, Power, Electronic, TR-808, Jazz, Brush, Orchestra, SFX) |
| GarageBand | the sampled instruments in `/Library/Application Support/GarageBand/Instrument Library` (pianos, strings, basses, organs, kits) |
| Logic Pro | the ~500 sampler instruments in `/Library/Application Support/Logic/Sampler Instruments`: pianos, basses, keys, guitars, orchestral, world, and about 140 electronic drum kits (808, 909, CR-78, TR-606, trap, house, lo-fi…) plus percussion |
| SoundFonts | every preset inside the `.sf2` files in `~/Library/Audio/Sounds/Banks` (and **Add SoundFont…** for any other file) |
| Plugins | your AU and VST3 instruments |

Notes on the Apple libraries:

* They load through Apple's own sampler, so they sound like they do in GarageBand and Logic. The samples are read from
  where Apple installed them; nothing is copied.
* Some instruments reference sample files that aren't installed on this Mac. The first time the library opens it tries
  each one in the background (about a minute, remembered afterwards) and hides the ones that can't load; "Show unavailable"
  lists them.
* Logic's *synth* instruments (Alchemy, Retro Synth, ES2…) and Drum Kit Designer are plugins that only run inside
  Apple's apps, so they can't be loaded here. The sampled instruments are what's available.

## Drums

* Drum tracks show the General MIDI drum names (Kick, Snare, Closed Hi-Hat…) as colour-coded pads beside the piano roll.
* **Step Sequencer** tab: a grid per drum. Click or drag to paint hits, ⌥-click for an accent, click a drum name to hear
  it, 1/4 – 1/32 steps, add any other drum as a row, one-click patterns (four on the floor, rock, hip hop, hats).
* Drum notation uses the standard percussion staff (kick on the bottom space, snare on the third, × hi-hats, ◇ open hat).

## Sheet music (Score tab)

Shows the selected pattern as notation and edits the same notes as the piano roll.

* Grand staff for wide-ranging parts, treble or bass clef otherwise, percussion staff for drums; key signature from the
  project key (or pick one), any time signature including 6/8, ties across barlines, dotted notes, rests, beams,
  accidentals that follow the key and reset each bar.
* **Note tool**: click the staff to place a note of the chosen length (palette `1 … 1/32`, `•` for dotted).
  **Select tool**: click or rubber-band notes, drag up/down to change pitch (by staff step, in the key), left/right to move
  in time. **Erase tool** (or right-click) removes notes.
* Keys: ↑/↓ semitone (⇧ octave), ←/→ nudge in time, `1`–`6` note length, `.` dotted, ⌫ delete, ⌘A select all.
* ♯ / ♭ buttons raise or lower the selection; a moving playhead follows playback.
* **Export Score**: PDF (printable, paginated) or MusicXML (opens in MuseScore, Finale, Sibelius, Dorico).

## Piano roll tools

**Placing notes:** the roll starts on the Select tool. Hold **⌘** and a see-through note follows the pointer (snapped to the grid); click to place it, drag to stretch it. Let go of ⌘ and you are back to selecting. The Draw / Select / Erase buttons (and P, V, E) still work. Draw stays on until you pick another tool.

**Moving notes with the keys:** ↑ / ↓ (with or without ⇧) move the selected notes one row, every note by the same amount. **⌘↑ / ⌘↓** move them a whole octave. ← / → move by the grid, ⇧← / ⇧→ by a bar.

**Colours:** the buttons, sliders and toggles in the Inspector and in each mixer strip take the colour of their instrument. Everything else keeps the system accent colour.

The **Tools** menu works on the selected notes (or the whole pattern): quantize (100% / 50% / with lengths), swing,
humanize, legato, reverse, transpose, fit to the scale, add major/minor/seventh chords or octaves, arpeggiate, louder/softer.

## Visualizer

The **Visualizer** tab (or **View ▸ Visualizer Window**, ⌥⌘V, which can go full screen) has two kinds of picture:

* **All Notes**: every track's notes in one big piano roll, each track in its own colour, scrolling past a playhead and
  lighting up as they sound (or the whole song at once with Follow off).
* **Circle** and **Rings** follow the notes that are playing, each track in its own colour. Circle is a pitch wheel (the
  twelve note names around it, higher octaves further out): every sounding note is a glowing circle with a ripple when it
  starts, and a chord is joined by a shape. Rings has one ring per track, and notes light up on their track's ring by pitch.
  A project with no notes (audio only) shows the live spectrum in these two instead.
* **Wave** is a waveform viewer: the output scrolls smoothly to the left, new sound entering on the right, above the live
  spectrum curve. The **Speed** slider sets how many seconds of sound fit across the picture (0.02 s to 3 s, 0.1 s to start): the
  faster it moves, the closer the zoom, so at the default you see the shape of each wave cycle and further out only the outline.
* **Spectrum shapes** driven by the real audio output: Bars, Mirror, Mountains and Dots, in Accent, Rainbow, Fire
  or Ice colours.

## Levels: Trim, Auto Balance, Bass

Every track has a **Trim** (dB) on top of its fader. **Auto Balance** (Mixer tab, or ⇧⌘L) measures how loud each track
really is and sets the trims so tracks sit at the same level and the mix reaches a healthy loudness; it also runs after a MIDI
import. The measurement counts very low and very high frequencies more heavily, so bass-heavy or hissy tracks aren't lifted
too far. The master strip has a **Bass** control (a low shelf) for taste. Track panels glow with their live loudness.

## Projects folder, chooser, introduction and GarageBand import
- The first time it starts, MacBand makes a **MacBand** folder beside your GarageBand folder (`~/Music/MacBand`), puts a small *Welcome to MacBand* song in it, and plays an animated introduction (replay it any time from **Help ▸ Show Introduction**).
- **File ▸ Open…** (⌘O) shows a chooser with the projects in that folder, recent ones, and others Spotlight finds. **Open File…** (⌥⌘O) is the normal file dialog.
- **GarageBand import:** on that first start every `.band` project in `~/Music/GarageBand` is converted into the MacBand folder, and a message tells you what happened. Each audio stem becomes an audio track, and the tempo, time signature and key come across. GarageBand keeps its notes and instruments in a private file nothing else can read, so those can't be imported. Your GarageBand projects are never changed. Later, use **File ▸ Import ▸ Band Project…** or drop a `.band` onto the window.

## Master track (effects on the whole mix)

Click **Master** under the track list (or **FX** on the Master strip in the Mixer) to open the Master panel in the Inspector. **Add Effect to
Master** puts an Audio Unit or VST3 effect on everything you hear, so one reverb, compressor or EQ covers the whole song instead of one
instrument. Effects run in the order shown (top to bottom), then through the limiter that protects your speakers; each can be bypassed
(power button), opened (sliders button) or removed (×). They are saved with the project, undo/redo works, and exports include them.
The Master panel also has the master volume and bass. The level meter and the Visualizer now listen after the master effects.

## Auto Save

Changes are saved to the project's file about ten seconds after you make them, when you switch to another app, and when you
quit. Before overwriting a file it keeps a backup of what was there (at most one every ten minutes, the last ten kept, in
`Backups/<project>` inside the support folder). An untitled project is kept as a recovery copy and offered back at the next
launch. Turn it off with **File ▸ Auto Save** or the project dropdown, which also shows when it last saved.

## Track height

Make the tracks taller or shorter with the slider above the track list or ⌘-scroll over the timeline (⌥-scroll and pinch
still zoom the time axis). It is remembered between launches.

## Fixed along the way (also in MacBand)

Export Audio (WAV) rendered every built-in sound as the same plain tone, because Apple's sampler forgets its instrument
when the engine switches to offline rendering. Both apps now reload the sounds before bouncing.

## Developer flags (run `MacBandStudio --flag`)

`--selftest` · `--uitest` · `--soundtest` (library, loading, rendering, audition) · `--soundtest-live` (decay envelopes) ·
`--steptest` · `--scoretest` (notation engine) · `--scoreuitest` (mouse and keyboard editing) · `--toolstest` · `--balancetest` · `--visualtest` · `--visualshots <dir>` · `--autosavetest` · `--projecttest` · `--bandtest` (GarageBand import) · `--mastertest` (Master track effects) · `--introshots <dir>` · `--soundtest-after` · `--stresstest <plugin>` ·
`--scoreshots <dir>` (renders test scores to PNG) · `--scoreexport <dir>` (PDF + MusicXML) ·
`--demo-song [--demo-panel editor|steps|score|mixer|sounds] [--demo-track N] [--demo-shot out.png]` ·
`--eventlog` (mouse events to `~/Library/Logs/MacBand-events.log`).
