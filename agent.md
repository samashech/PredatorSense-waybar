# agent.md: set up PredatorSense-waybar

You are an AI coding agent setting up this repo on the user's Acer Predator (or Nitro) laptop.
Work through the parts in order. Each step says what to check, what to run, and when to stop.

The repo is a set of Omarchy shell plugins, one folder each under `plugins/`:

| Component | Plugin id | What it needs beyond Omarchy |
|---|---|---|
| Fans | `samashech.fans` | a fan-control driver + write access (Part B) |
| Keyboard Sync (+ key sounds) | `samashech.audio-sync` | the `facer` driver for RGB; `input` group for typing ripple and key sounds (Part C) |
| Now Bar | `samashech.nowbar` | nothing; a Spotify app for the queue (Part D) |
| Tasks | `samashech.tasks` | nothing; `nvidia-utils` for NVIDIA stats |
| Cleaner | `samashech.cleaner` | `pacman-contrib` for old package versions (Part E) |
| Bar Pet | `samashech.pet` | nothing |

Throughout, `REPO` is the directory holding this file and `PLUGINS` is `~/.config/omarchy/plugins`.

## Rules for the agent

- **Ask before every privileged or system-wide change.** That covers `sudo`, `/etc`, kernel modules, DKMS and group membership. Show the exact command first. Use `sudo` when the user has a terminal for the password; use `pkexec` only when they don't.
- **Never run two Acer platform drivers at once.** Mainline `acer_wmi`, `facer` and Linuwu-Sense all bind the same `acer-wmi` device. Find out what is loaded (step B1) before installing anything.
- **Don't uninstall the user's existing tools** (DAMX, PredatorSense ports, Linuwu-Sense) unless they ask. Explain the conflict and let them decide.
- **Back up any config file before you edit it**: `cp file file.bak.$(date +%s)`.
- **Don't edit files owned by a package**: anything under `/usr`, and on Omarchy anything under `/usr/share/omarchy`.
- **Never set a fan below 30%.** `fanctl` enforces this; don't work around it.
- **Never ask for, print or store Spotify secrets.** The Now Bar uses PKCE and only needs the app's Client ID. The login token stays in `~/.local/state/omarchy-nowbar/` (mode 600).
- **Don't clean anything on the user's behalf.** The Cleaner only deletes what the user ticks in its panel.
- **Report results faithfully.** If a step fails, show the output and stop.

## Part A: check the machine and pick components

```bash
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name   # should say Acer
. /etc/os-release; echo "$ID $VERSION_ID"; uname -r
command -v omarchy-shell && echo "omarchy-shell present"
pgrep -x waybar >/dev/null && echo "waybar running"
id -nG
```

- Stop if the vendor isn't Acer, unless the user only wants Now Bar, Tasks, Cleaner, Bar Pet or key sounds. Those work on any laptop.
- Without `omarchy-shell`, only the fan module works (as a Waybar module or CLI, steps B5–B6). Tell the user and skip Parts C–E.
- Ask the user which components they want. The default is all of them. The names for `install.sh` are `fans keyboard nowbar tasks cleaner pet`.

## Part B: Fans

`FANCTL` below means `"$REPO/plugins/samashech.fans/fanctl"`.

### B1. Which fan driver is active

```bash
bash "$FANCTL" status
lsmod | grep -E '^(acer_wmi|linuwu_sense|facer) '
grep -rhE 'acer_wmi|linuwu|facer' /etc/modprobe.d /etc/modules-load.d 2>/dev/null
dkms status 2>/dev/null | grep -Ei 'linuwu|facer|acer'
```

| `backend` line | Meaning | Next |
|---|---|---|
| `hwmon` | A driver exposes hwmon `acer` with `pwm1`/`pwm2` (mainline `acer_wmi` or `facer`) | B3 |
| `linuwu` | Linuwu-Sense is loaded | B3 |
| `none` | No fan control yet | B2 |

If the user also wants Keyboard Sync, read Part C1 first: `facer` gives both fan control and keyboard RGB, so it may be the better single driver to install.

### B2. Get a fan-control driver (only if backend is `none`)

**a) Mainline `acer_wmi`.** It ships with the kernel. Some models need `predator_v4=1`. If `acer_wmi` is blacklisted or another fork owns the device, ask the user before changing anything. With their approval:

```bash
sudo modprobe -r acer_wmi 2>/dev/null; sudo modprobe acer_wmi predator_v4=1
bash "$FANCTL" status        # backend hwmon now?
echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi-predator.conf   # only if it worked
```

If it's still `none`, undo it (`sudo modprobe -r acer_wmi`) and try b) or c).

**b) `facer`**, from Part C1. It also unlocks Keyboard Sync.

**c) Linuwu-Sense** (https://github.com/0x7375646F/Linuwu-Sense). Read its README first; its installer is the source of truth. It needs `git dkms` plus build tools and headers that match the running kernel. On Arch, find the headers package with `pacman -Qo /usr/lib/modules/$(uname -r)`; on Ubuntu, install `build-essential linux-headers-$(uname -r)`. Then `git clone` it and run `sudo make install`. Afterwards `bash "$FANCTL" status` must say `backend linuwu`; otherwise show `dmesg | tail -50` and stop.

### B3. Let the user change fan speed without sudo

**Backend `hwmon`:** check `ls -l /sys/class/hwmon/*/pwm1`. If the user's group can already write it, skip this step. Otherwise install the udev rule, which gives the `predator-fans` group write access:

```bash
sudo groupadd -f predator-fans
sudo usermod -aG predator-fans "$USER"
sudo install -m 0644 "$REPO/udev/99-predator-fans.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acer ] && sudo udevadm trigger --action=change "$h"; done
```

**Backend `linuwu`:** its installer created the `linuwu_sense` group. Add the user if needed: `sudo usermod -aG linuwu_sense "$USER"`.

New groups apply at the next login. Until then, test with `sg`:

```bash
sg predator-fans -c "bash $FANCTL set 1 manual 60"; sleep 5; bash "$FANCTL" status
bash "$FANCTL" auto
```

The CPU fan's RPM should change. If it doesn't, the firmware ignores manual control on this model; tell the user.

### B4. Omarchy

Handled by `install.sh` (Part F). The panel's power profile buttons use `omarchy-powerprofiles-set`, which Omarchy ships.

### B5. Waybar (no Omarchy shell)

1. Dependencies: `jq power-profiles-daemon`, plus `nvidia-utils` for GPU temperature.
2. Install the scripts:

   ```bash
   install -Dm 0755 "$FANCTL" ~/.local/bin/predator-fanctl
   install -Dm 0755 "$REPO/waybar/predator-fans-waybar" ~/.local/bin/predator-fans-waybar
   ~/.local/bin/predator-fans-waybar     # must print one JSON line
   ```

3. Find the config Waybar actually loads. Check a `-c` argument (`ps -o args= -C waybar`), then `~/.config/waybar/config.jsonc` or `config`, then `/etc/xdg/waybar/` (copy that one to `~/.config/waybar/` before editing). The style sheet is `style.css` next to it, or whatever `-s` points to.
4. Back up both files. Add `"custom/predator-fans"` to a module list (ask the user where; the default is after `clock`), paste `$REPO/waybar/module.jsonc` into the top-level object, and append `$REPO/waybar/style.css` to the style sheet.
5. Reload with `pkill -SIGUSR2 waybar`, or restart Waybar the way it was launched. Check its stderr for JSON errors.

Module controls: click toggles Auto/Max, scroll changes speed by ±10%, right-click switches power profile. It uses signal 9; if that's taken, change it in all four places.

### B6. Other bars, and keybindings

Install `~/.local/bin/predator-fanctl` as in B5 and offer keybindings (ask which keys, and check they're free):

```
predator-fanctl status | toggle | max | auto | bump +10 | set 1 manual 60
```

On Omarchy, bindings go in `~/.config/hypr/bindings.lua`, following the patterns already in that file. A binding can open a panel directly, for example `o.bind("XF86Presentation", "Fan control", { panel = "samashech.fans" })`, which puts the fan panel on the PredatorSense key.

## Part C: Keyboard Sync and key sounds

`KBSYNC` means `"$REPO/plugins/samashech.audio-sync/kbsync"` and `KEYSOUND` means `"$REPO/plugins/samashech.audio-sync/keysound"`.

### C1. RGB driver

```bash
ls -l /dev/acer-gkbbl-0 /dev/acer-gkbbl-static-0
/usr/bin/python3 -I "$KBSYNC" probe       # device ok|missing, keyboard ok|noaccess
```

If both device files exist, go to C2. Otherwise the laptop needs the `facer` kernel module from the PredatorSense port at https://github.com/cleyton1986/predator-sense. Read its README before doing anything. It offers a full installer (GUI app plus the module) and a manual path; the module itself lives in `predator-sense-gui/kernel/` with a DKMS config.

- `facer` replaces mainline `acer_wmi`, which gets blacklisted, and it conflicts with Linuwu-Sense. If Linuwu-Sense or DAMX is in use, tell the user that Keyboard Sync can't drive the keyboard alongside it, and let them choose.
- Some models (the project README lists PHN16S-71, PHN16-73 and AN16S-61) put the keyboard RGB on a separate HID chip instead. `kbsync` only speaks the `/dev/acer-gkbbl-*` interface, so on those models only key sounds will work. Say so.
- After installing, `facer` creates the device files with mode 0666, so no extra permission is needed. Check with `ls -l` again.

### C2. Typing ripple and key sounds: keyboard access

Both read key presses from `/dev/input`, which needs the `input` group:

```bash
id -nG | grep -qw input || echo "not in input group"
```

Tell the user plainly that the `input` group can read every key press on the machine. The helpers only use key codes to place a ripple or play a click, and never store or send them. Then, with their approval: `sudo usermod -aG input "$USER"`. It takes effect at the next login.

### C3. Audio and notifications

The audio sync uses `parec`, and key sounds use `pacat`, both from `libpulse` (Arch) or `pulseaudio-utils` (Ubuntu). PipeWire with `pipewire-pulse`, which Omarchy ships, works. The notification flash uses `dbus-monitor` (package `dbus`). Check:

```bash
command -v parec pacat dbus-monitor
/usr/bin/python3 -I "$KEYSOUND" demo blue     # should play a short burst of typing
```

All settings, including the key sound switch, live in the Keyboard Sync panel. Right-click the bar icon to toggle audio sync. Settings are stored in `~/.local/state/omarchy-audio-sync/config.json`.

## Part D: Now Bar (Spotify queue)

The card works with any MPRIS player straight away. The **next 4 songs** come from the Spotify Web API and need a one-time setup by the user. You can't do the browser parts for them, so walk them through:

1. At https://developer.spotify.com/dashboard, create an app. The Redirect URI must be exactly `http://127.0.0.1:8898/callback`. Under APIs, tick **Web API**.
2. In Development Mode, Spotify requires the **app owner to have Premium**. Tell the user this before they start.
3. Copy the app's **Client ID** (32 hex characters). There is no client secret to copy, and none is needed.
4. After `install.sh` has run:

   ```bash
   NOWQ=~/.config/omarchy/plugins/samashech.nowbar/nowq
   "$NOWQ" setup <client-id>
   "$NOWQ" login          # opens the browser; the user approves
   "$NOWQ" queue          # should print "auth ok" and up to 4 "q" lines while Spotify plays
   ```

If `login` fails with `INVALID_CLIENT: Invalid redirect URI`, the redirect URI in the dashboard doesn't match exactly.

## Part E: Tasks, Cleaner, Bar Pet

- **Tasks:** nothing to set up. NVIDIA per-app numbers need `nvidia-smi` (`nvidia-utils`); Intel GPU numbers come from the kernel.
- **Cleaner:** the "old package versions" item uses `paccache` from `pacman-contrib` (Arch only; elsewhere that item just doesn't appear). System items ask for a password through polkit; the Omarchy shell includes a polkit agent. Test the scan without deleting anything:

  ```bash
  /usr/bin/python3 -I "$REPO/plugins/samashech.cleaner/sweep" scan
  ```

- **Bar Pet:** nothing to set up. Its memory is in `~/.local/state/omarchy-pet/state.json`. The Cleaner feeds it automatically. Rename it with `omarchy-shell samashech.pet rename <name>`.

## Part F: install the plugins

```bash
cd "$REPO" && ./install.sh                  # all components
cd "$REPO" && ./install.sh fans keyboard    # or only some
```

The script copies each plugin to `PLUGINS/<id>` and validates it. If an older copy exists, it moves it to `~/.local/state/predator-suite/backup-<time>/` first. Then it adds each widget to the bar:

| Component | Placement |
|---|---|
| Keyboard Sync, Fans | just below/right of the clock (`centerEnd`) |
| Now Bar | just above/left of the clock (`centerBegin`) |
| Bar Pet | after the workspaces (`left`) |
| Cleaner, Tasks | end of the bar (`right`) |

To move one, use `omarchy bar move <id> --section <section> [--index N | --after <id>]`. Don't put widgets in `center`, because that pushes the clock off center. If a widget doesn't appear, run `omarchy restart shell` and check `journalctl --user -b | grep -i samashech`.

## Part G: verify and report

Show the user:
- `bash "$FANCTL" status` and `/usr/bin/python3 -I "$KBSYNC" probe`
- a screenshot or description of the bar
- every file, group and driver you changed, with backup locations

Remind them to log out and back in if you changed group membership.

## Uninstall

1. Hand the fans back to the firmware: `bash "$FANCTL" auto`.
2. Remove plugins: `omarchy plugin remove <id>` for each (ids in the table at the top).
3. Optional cleanup: `rm -rf ~/.local/state/omarchy-audio-sync ~/.local/state/omarchy-nowbar ~/.local/state/omarchy-pet ~/.cache/omarchy-nowbar ~/.local/bin/predator-fanctl ~/.local/bin/predator-fans-waybar`.
4. Permissions and drivers, only if this guide added them, and after asking: `sudo rm -f /etc/udev/rules.d/99-predator-fans.rules /etc/modprobe.d/acer-wmi-predator.conf && sudo udevadm control --reload-rules`. Remove `facer` or Linuwu-Sense with their own uninstallers.

## For the repo owner: editing

Omarchy loads plugins from `PLUGINS` and refuses symlinks there, so the live copies and `plugins/` in this repo are separate. Edit and test the live copies, then run `./sync-from-system.sh` (add `--dry` to preview) to copy them back before committing.
