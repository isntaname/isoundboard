# Contributing

Bug reports and pull requests are welcome. For anything bigger than a fix,
open an issue first so we can agree on the approach.

## Build and test

```bash
./build-app.sh --install && open /Applications/iSoundboard.app
swift test          # no audio hardware needed
```

Launch the app with `open`, never by running the binary. See
[`docs/permissions-findings.md`](docs/permissions-findings.md) for why.

## Testing with real audio

Anything that touches real devices is checked with `soundboardctl`:

```bash
swift run soundboardctl devices                          # list audio devices
swift run soundboardctl verify "iSoundboard" --mic     # mixer -> virtual mic
swift run soundboardctl monitor "iSoundboard"          # monitor -> chosen output
swift run soundboardctl dual "iSoundboard"             # both at once
swift run soundboardctl interrupt "iSoundboard"        # clips cancel, never stack
```

`verify` plays a 440 Hz tone through the mixer while a separate engine records
the virtual device, which is what the game hears. It then measures the energy
at 440 Hz to confirm the tone arrived.

## Layout

| Path | What |
|---|---|
| `Sources/SoundboardCore` | Portable logic with no platform APIs |
| `Sources/AudioEngine` | Aggregate device, mixer, decoding, signal analysis |
| `Sources/InputControl` | Hotkeys, key injection, permissions |
| `Sources/SoundboardApp` | SwiftUI app |
| `Sources/soundboardctl` | Hardware verification harness |
| `Resources/Icon` | App icon and the script that draws it |
| `docs/audio-findings.md` | Core Audio traps. Read before touching the engine |
