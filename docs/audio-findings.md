# CoreAudio / AVAudioEngine findings

Discovered while building M1. Each of these fails *silently* — the engine
reports `isRunning == true` and renders audio internally while the device
receives nothing.

## 1. Touching `engine.inputNode` reconfigures the AUHAL

Merely *reading a property* off `engine.inputNode` (even
`outputFormat(forBus:)`) enables the input side and resets the audio unit's
device assignment. Consequences:

- Never reference `inputNode` unless the microphone is actually in use.
  A diagnostic `print` of its format is enough to break output.
- Never touch it on a **running** engine. Doing so kills output mid-session.
- This bit twice: once in the verification harness, once inside the engine's
  own diagnostics.

## 2. Assign the device *after* the graph exists, and verify it stuck

`kAudioOutputUnitProperty_CurrentDevice` set before `inputNode` is first
touched gets silently discarded — AVAudioEngine substitutes an aggregate of
its own. Correct order:

1. create the aggregate
2. touch `inputNode` (only if using the mic)
3. assign the device
4. set the input channel map
5. build the graph
6. re-assign **only if** a read-back shows it drifted
7. assert the read-back matches, and throw if not

Step 6 must be conditional. Re-setting the device on an already-correct unit
tears down the output connection and renders silence.

## 3. Build the graph at the device's real sample rate

AVAudioEngine defaults to 44.1 kHz. With playback only it quietly resamples,
so the bug hides. One AUHAL cannot run input at 48 kHz and output at 44.1 kHz,
so engaging the microphone makes the mismatch fatal. Read
`outputNode.outputFormat(forBus: 0)` after assigning the device and build every
connection at that rate.

## 4. The aggregate exposes the virtual device's loopback return

Aggregating a 1-channel mic with BlackHole 2ch yields **3** input channels:
mic on ch 0, BlackHole's loopback on ch 1-2. Connecting the input node as-is
feeds our own output back in. Fix with an AUHAL channel map
(`kAudioOutputUnitProperty_ChannelMap`, scope output, element 1) of `[0]`.

## 5. `AVAudioFile.read(into:)` returns short

It stops on whole 1024-frame chunk boundaries and does **not** guarantee reading
the whole file in one call. A 22050-frame file yielded 21504 frames; 44100 gave
44032; 88200 gave 88064. Every sound silently lost an erratic slice of its tail.

Loop until the file position reaches its length. This cost five wasted fix
attempts aimed at `AVAudioConverter`, which was innocent — it consumed 100% of
what it was handed. The lesson is the general one: when output is short, measure
what went *in* before blaming the thing in the middle.

Related, and both required when resampling with `AVAudioConverter`:
- feed the input block the packet count it **asks for** (hand it the whole
  buffer and it takes what it wanted and drops the rest)
- call `convert` repeatedly until `.endOfStream`
- `convert(to:from:)` is not an option — it cannot resample and fails with
  paramErr (-50)

A correct conversion overshoots by a small **constant** (~34 frames of resampler
tail). Anything erratic means data is being lost upstream.

## 6. One AVAudioEngine drives exactly one device

Monitoring — hearing your own clips locally — needs a second engine, because
your output device is a third device on its own sample clock. Adding it to the
aggregate instead would work, but then the microphone reaches it too and you
hear yourself delayed (and feed back on speakers); keeping the monitor separate
makes that impossible by construction.

Two engines on two devices do coexist (`soundboardctl dual` proves the virtual
mic still receives audio while the monitor plays elsewhere), but each needs its
buffers in *its own* graph format — the devices may run at different sample
rates, and a buffer whose format does not match its player is dropped in
silence. Hence the separate buffer cache per engine.

## 7. One clip at a time

Both engines use a single `AVAudioPlayerNode` and schedule with `.interrupts`,
which replaces whatever is playing on that node. A pool of nodes would let clips
stack.

The cancelled clip's completion handler may still fire *after* its replacement
started. Retiring plays by sound id would then let a stale completion close the
mic on the clip that replaced it — so each *playback* gets a unique token
(`play-1`, `play-2`, …) and the interrupted play is retired explicitly at the
moment it is cancelled, since its handler may never arrive at all.

`soundboardctl interrupt` proves it: 440 Hz energy falls from 4.0e-02 to 1.3e-11
the instant an 880 Hz clip takes over.

## 8. Ducking the microphone shares the interrupt problem

`whenIdle` mutes the mic while a clip plays. Restoring it on the clip's
completion handler has the same hazard as retiring a play: a cancelled clip's
handler fires *after* its replacement began, and would un-duck the microphone
underneath it. The engine guards this with a generation counter — only the
newest playback may restore the gain — and `stopAllSounds` bumps the generation
so a manual stop restores the mic immediately.

`soundboardctl duck` checks all three modes, plus the interrupted and
manually-stopped cases.

## 9. `inputNode.outputFormat` is a lie — use `inputFormat`

`AVAudioEngine.inputNode.outputFormat(forBus:)` reports a format cached from the
**system default input device**, not from the device the engine's audio unit is
actually assigned to. With a Bluetooth headset as the system default, the same
node reported:

```
out = 1 ch, 16000 Hz   <- the system default input
in  = 1 ch, 48000 Hz   <- the aggregate this engine is really on
```

Connecting the input node with `outputFormat` wires the graph at a rate the
hardware is not running, and the whole thing renders silence. Use
`inputFormat(forBus:)` — the hardware side — for the connection, and for taps on
a recorder pointed at a specific device.

This was invisible for weeks because the system default input happened to be the
same 48 kHz device the aggregate used. It only surfaced when a 16 kHz Bluetooth
headset became the default.

## 10. An aggregate runs every sub-device at ONE rate

Sample rates are not negotiated per sub-device. A Bluetooth headset microphone
supports **only 16 kHz** (hands-free profile), so an aggregate containing it
collapses to 16 kHz and drags the virtual device down with it.

Consequences, all of which are now handled:

- The aggregate's rate must be the best rate **both** devices support, not
  simply 48 kHz. Asking for a rate a sub-device cannot do leaves the aggregate
  reporting one rate while its members run at another — silence.
- Sub-device rates must be pinned **before** the aggregate is created; it
  inherits whatever they are already at, and a previous Bluetooth session can
  leave the virtual device stuck at 16 kHz.
- The clock master is the **virtual device**, not the microphone. The virtual
  device is the destination and has to run at a rate games expect.
- When the microphone is not in use, skip the aggregate entirely and drive the
  virtual device directly — otherwise a Bluetooth mic forces 16 kHz on a device
  we never read.

With a Bluetooth headset mic the whole chain, clips included, runs at 16 kHz.
That is inherent to HFP; the app says so and suggests using the built-in mic and
keeping the headset for listening.

## 11. Starting the engine must not run on the main thread

Opening a Bluetooth device takes seconds while the profile is negotiated. Doing
that on the main actor freezes the UI — the app looks hung. Engine start and
stop both run on a detached task, with state handed back to the main actor.

## 12. Claiming the system default microphone

The app points `kAudioHardwarePropertyDefaultInputDevice` at the virtual device
so games pick it up with no in-game configuration. Two consequences have to be
handled or this does real damage:

- **It must be given back.** Quitting while the virtual device is still the
  default input leaves every other app — Zoom, FaceTime, voice memos — recording
  silence, because nothing feeds it when Soundboard is not running. Released on
  `willTerminate`, and the previous device UID is persisted so a force-quit or
  crash can be undone on the next launch.
- **"Follow the system default" becomes a feedback loop.** Once the default
  input is the virtual device, resolving the app's own microphone that way makes
  it capture its own output. `DeviceSelection.microphone` excludes the virtual
  device outright, by whichever route it was selected, and falls back to any
  real input.

`soundboardctl claim` exercises the whole cycle against the real system and
checks the default input is actually handed back.

## 13. A Bluetooth headset changes shape while you are using it

The Logitech Zone Vibe supports both A2DP (stereo, 44.1 kHz) and hands-free
(mono, 16 kHz), and macOS switches profile the moment the microphone is
activated. The device keeps its id, but its **sample rate and channel count
change underneath a running engine**, which invalidates a graph built for the
other shape. Observed live:

```
monitor device changed (102:16000:0x1 -> 102:44100:0x2) — rebuilding
```

Two consequences:

- **Never assume stereo.** `AVAudioFormat(standardFormatWithSampleRate:channels: 2)`
  on a device presenting one output channel renders silence, while the engine
  reports that it started and is playing. Take the channel count from
  `outputNode.outputFormat(forBus:)`.
- **Watch for the switch.** The engines record a signature of each device they
  were built for — id, rate, channel counts — and rebuild when it changes.
  Polling once a second is enough and avoids CoreAudio listener threading.

Also: muting the microphone now *releases* it rather than zeroing its gain.
Holding a Bluetooth mic open keeps the headset in hands-free mode, so it stays
mono and 16 kHz for listening too. Letting go returns it to full stereo.

## 14. AVAudioEngine stops itself and does not tell you

When a device changes configuration — a Bluetooth headset switching profile is
exactly this — AVAudioEngine **stops the engine** and posts
`.AVAudioEngineConfigurationChange`. Nothing else reports a problem:

```
monitorAccepted=true  playing=true  peak=0.0  renders=0
```

`isRunning` (our own flag) still said true, the player node still said it was
playing, the buffer was fine (peak 0.35), and the output unit was verifiably on
the right device. The graph had simply never rendered a single buffer.

Two defences, both needed:

- Observe `.AVAudioEngineConfigurationChange` and rebuild the affected engine.
- Poll `engine.isRunning` — AVAudioEngine's own flag, not ours — on the health
  tick, because a stop can happen without the notification reaching us.

The diagnostic that found this was a render counter on a tap of the graph's own
output. "Is it producing audio" and "is it being pulled" look identical from
every other angle: a silent buffer and a dead engine both read as peak 0. Only
the render count separates them.

## 15. Verifying by ear is not verification

`soundboardctl verify` pushes a 440 Hz tone through the mixer while a separate
engine records the virtual device — exactly what the game hears. Use Goertzel
energy at the target frequency, not zero-crossing rate: once the live mic adds
room noise, crossing counts over-report badly (440 Hz measured as 533 Hz).
