# omarchy-predator-fans

Fan control for Acer Predator and Nitro laptops on Linux, right in your status bar. You don't need PredatorSense, NitroSense or DAMX running.

- **Auto / Max** for both fans in one click, or a fixed speed per fan (30–100%)
- **Live RPM** for the CPU and GPU fans
- **CPU and GPU temperature.** The NVIDIA GPU is never woken from sleep just to read it.
- **Power profile** switching (power-saver / balanced / performance)
- Works as an **Omarchy shell plugin**, a **Waybar module**, or a plain **CLI** for any other bar or keybinding

It was built and tested on an Acer Predator PHN16-72 running Omarchy (Hyprland). Other models work if the kernel exposes fan control: see [Compatibility](#compatibility).

## Install

### Let an AI agent do it

Give [`agent.md`](agent.md) to your coding agent (Claude Code, Codex, etc.) and ask it to follow the file. It will:
- detect your distro, kernel, bar and current fan driver
- install a driver only if one is missing
- set up permissions so you don't need sudo
- put the module in your bar

It asks before every privileged step.

### Omarchy, by hand

```bash
omarchy plugin add https://github.com/<you>/omarchy-predator-fans --enable
```

The widget lands next to the clock. You still need the one-time permission setup from step 4 of [`agent.md`](agent.md), unless your driver already lets your user write the fan controls.

### Waybar, by hand

Follow step 5b of [`agent.md`](agent.md). In short:

1. Copy `fanctl` to `~/.local/bin/predator-fanctl` and `waybar/predator-fans-waybar` to `~/.local/bin/`.
2. Add the block from `waybar/module.jsonc` to your config, and the CSS from `waybar/style.css` to your style sheet.

## Usage

| Where | Action |
|---|---|
| Omarchy bar icon | Left-click opens the panel. Right-click switches between Auto and Max. |
| Omarchy panel | Auto / Max buttons, a slider per fan, power profile buttons |
| Waybar | Click: Auto ↔ Max. Scroll: ±10%. Right-click: next power profile. Tooltip: RPM, temperatures, profile. |

The CLI works the same everywhere:

```bash
predator-fanctl status              # backend, RPM, mode, %, CPU/GPU temperature
predator-fanctl max                 # both fans to 100%
predator-fanctl auto                # back to the firmware curve
predator-fanctl toggle              # Auto <-> Max
predator-fanctl set 1 manual 60     # CPU fan (1) to 60%; the GPU fan is 2, both is "all"
predator-fanctl bump -10            # nudge both fans down 10%
```

The bar icon changes when any fan is under manual control, so you don't forget a fan pinned at a fixed speed.

## How it works

`fanctl` is a small bash script that talks to whichever kernel driver is present:

| Backend | Driver | Interface |
|---|---|---|
| `hwmon` | mainline `acer_wmi` (or a fork such as `facer`) | `/sys/class/hwmon/hwmonN` named `acer`: `pwmX_enable` (1 manual, 2 auto) and `pwmX` (0–255) |
| `linuwu` | [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense) | `predator_sense/fan_speed` or `nitro_sense/fan_speed` as `cpu,gpu` (0 = auto) |

Temperatures come from hwmon `coretemp` (Intel package) or `k10temp` (AMD Tctl), and from `nvidia-smi`. The NVIDIA query only runs when the GPU is already awake.

The bar UIs only read `fanctl status` and call `fanctl`. They never pass text into a shell, and the panel validates every value before showing it.

## Compatibility

| | Status |
|---|---|
| Omarchy (omarchy-shell bar) | ✅ tested |
| Hyprland + Waybar (vanilla Arch, CachyOS) | ✅ supported (Waybar module) |
| Ubuntu (Waybar on Hyprland/Sway) | ⚠️ supported; older Ubuntu kernels usually need Linuwu-Sense |
| GNOME / KDE | CLI only (no bar module yet) |
| `hwmon` backend | ✅ tested on PHN16-72 |
| `linuwu` backend | ⚠️ implemented from Linuwu-Sense's documented interface, not yet tested on hardware |

## FAQ

**Do I still need DAMX or PredatorSense?**
No. The plugin doesn't talk to DAMX at all. It only needs a kernel driver that exposes fan control. One catch: some PredatorSense ports install their own fork of the kernel driver (for example `facer`). If you uninstall such a port, also remove its `acer_wmi` blacklist so the mainline driver loads again. Step 2 of `agent.md` checks this.

**Is it safe?**
Manual speed can't go below 30%, and Auto is always one click away. The firmware may switch back to Auto after suspend or reboot. The bar shows the real state either way.

## Requirements

See [`requirements.txt`](requirements.txt). It lists OS packages, not pip packages. The core is just bash. `jq` is needed for Waybar, `nvidia-utils` for GPU temperature, and `power-profiles-daemon` for the profile buttons.

## Files

```
manifest.json, Panel.qml, i18n/   Omarchy shell plugin (repo root = plugin root)
fanctl                            the fan helper / CLI
waybar/                           Waybar module script, config block, CSS
udev/99-predator-fans.rules       lets the predator-fans group drive the hwmon fan controls
agent.md                          install guide for AI agents (and humans)
requirements.txt                  system packages
```
