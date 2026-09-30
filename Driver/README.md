# Audio driver

iSoundboard's virtual audio device is built from
[BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio,
licensed GPL-3.0.

`BlackHole/` is an unmodified copy of BlackHole v0.7.1
(commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`), without its installer,
uninstaller and images.

`build-driver.sh` builds it under our own name, as BlackHole's license asks of
third-party builds:

- name, device and manufacturer "iSoundboard", bundle id
  `io.github.isntaname.isoundboard.driver`, our icon
- 2 channels
- two hard-coded strings in `BlackHole.c` ("BlackHole Box" and the box
  manufacturer) are patched to use our name, in a temporary copy

To update BlackHole, replace `BlackHole/` with the new release and reset
`DRIVER_REVISION` in `build-driver.sh` to 1.
