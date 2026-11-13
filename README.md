# PredatorSense-waybar

PredatorSense-style tools for Acer Predator laptops on [Omarchy](https://omarchy.org), living in the Omarchy shell bar. No PredatorSense, NitroSense or DAMX needed.

Built and tested on an Acer Predator Helios Neo 16 (PHN16-72). The fan module also runs on plain Waybar.

## Install

**With an AI agent (recommended):** give [`agent.md`](agent.md) to Claude Code, Codex or similar and ask it to follow it. It checks your laptop, installs only the drivers you're missing, asks before anything that needs `sudo`, and puts everything on your bar.

**By hand:**

```bash
git clone https://github.com/samashech/PredatorSense-waybar
cd PredatorSense-waybar
./install.sh              # everything, or e.g. ./install.sh fans pet
```

`install.sh` only copies the plugins and places them on the bar. Drivers and permissions are in [`agent.md`](agent.md).

## Components

## Fans
- Auto, Max, or a fixed speed per fan, with live RPM
- CPU and GPU temperature, without waking a sleeping NVIDIA GPU
- Power profile switching; also works as a Waybar module or a plain CLI

*How it's made:* a bash helper (`fanctl`) drives the kernel's hwmon `pwm` controls (mainline `acer_wmi`/`facer`) or Linuwu-Sense, with a QML panel on top.

### Keyboard Sync
- 4-zone RGB synced to whatever is playing, with a punchy beat kick (pulse, spectrum, wave, theme)
- Typing ripple: the zone you type in lights up and spreads outward
- Notification flash: blinks on new notifications, red for critical, never during Do Not Disturb

*How it's made:* a Python daemon (`kbsync`) reads the audio output through `parec`, runs a small FFT with beat detection, and writes zone colors to the `facer` driver's `/dev/acer-gkbbl-*` devices at a pace the keyboard controller can keep up with.

### Mechanical key sounds
- Blue (clicky), Brown (thocky) or Typewriter (with a bell on Enter)
- Every press sounds slightly different, and big keys sound deeper
- Volume slider; works with any keyboard, not just the RGB one

*How it's made:* `keysound` synthesizes the clicks at startup (no audio files), reads key presses from `/dev/input`, and mixes them into a low-latency `pacat` stream that closes when you stop typing. Its switch is in the Keyboard Sync panel.

### Now Bar
- Phone-style media card: cover art, seek bar, play/pause/skip, output device picker
- Shows the next 4 songs in your Spotify queue with cover art; tap one to jump to it
- Save the current song to your library

*How it's made:* QML on top of MPRIS for any player. A small Python helper (`nowq`) reads the queue from the Spotify Web API through a PKCE login (no client secret).

### Tasks
- Top 5 apps by CPU, RAM and GPU, with helper processes grouped (all of Brave counts as one)
- RAM in MB/GB; CPU and GPU in %, plus VRAM per app
- Samples only while the panel is open

*How it's made:* `topproc` samples `/proc` over one second, reads Intel GPU use from DRM fdinfo, and calls `nvidia-smi` only when the NVIDIA GPU is already awake.

### Cleaner
- Shows how much space each cache takes: uv, mise, pip, npm, Cargo, VS Code, browsers, Spotify and more
- Tick what to clear; browsers and apps that are open are skipped
- Old package versions, crash dumps and old logs, with one password prompt

*How it's made:* `sweep` measures and clears only known cache folders, using each tool's own clean command where one exists. System items run as a single fixed `pkexec` command.

### Bar Pet
- A tiny creature in your bar: dances to music, sleeps when you're away, sweats when the CPU is hot
- Eats the cache the Cleaner frees, and shows a heart when you click it
- Remembers its age, what it has eaten and how often it was petted

*How it's made:* drawn entirely in QML (Canvas plus animations), reading MPRIS, UPower, the CPU temperature sensor and Wayland idle state.

## Working on it

Omarchy runs plugins from `~/.config/omarchy/plugins/` and doesn't allow symlinks there, so edit and test the live copies, then copy them back into the repo:

```bash
./sync-from-system.sh --dry   # see what changed
./sync-from-system.sh         # copy it into plugins/
```

## Layout

```
plugins/<id>/         one folder per Omarchy shell plugin
install.sh            copy plugins into place and add them to the bar
sync-from-system.sh   copy your live plugins back into the repo
agent.md              full setup guide for AI agents (and humans)
waybar/, udev/        Waybar fan module and the fan permission rule
requirements.txt      system packages per component
```
