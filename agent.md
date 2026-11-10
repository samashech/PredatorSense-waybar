# agent.md: install omarchy-predator-fans

You are an AI coding agent installing this project on the user's Acer Predator or Nitro laptop.
Work through the steps in order. Each step says what to check, what to run, and when to stop.

The project gives the user fan control (Auto, Max or a fixed speed for the CPU and GPU fans) plus live RPM, CPU and GPU temperature, and the power profile. They get it in their status bar, so they don't need PredatorSense, NitroSense or DAMX.

## Rules for the agent

- **Ask before every privileged or system-wide change.** That covers `sudo`, `/etc`, kernel modules, DKMS, and group membership. Show the exact command first. Use `sudo` when you have a terminal the user can type a password into. Use `pkexec` only when you don't.
- **Never run two fan drivers at once.** Mainline `acer_wmi`, Linuwu-Sense and other forks (for example `facer`, shipped by some PredatorSense ports) all bind the same `acer-wmi` platform device. Before you install one, find out what is loaded now (step 2).
- **Don't uninstall the user's existing tools (DAMX, PredatorSense, NitroSense ports) unless they ask.** Tell them what conflicts and let them decide.
- **Back up any user config file before you edit it**: `cp file file.bak.$(date +%s)`.
- **Don't edit files owned by a package**: anything under `/usr`, and on Omarchy anything under `/usr/share/omarchy`.
- **Never set a fan below 30%.** `fanctl` enforces this, so don't work around it.
- **Report test results faithfully.** If a step fails, show the output and stop. Don't guess past it.

Throughout, `REPO` means the directory holding this file.

## 1. Check the machine

```bash
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name   # must say Acer
. /etc/os-release; echo "$ID $VERSION_ID"                         # arch, cachyos, ubuntu, ...
uname -r
echo "$XDG_CURRENT_DESKTOP"; pgrep -x Hyprland >/dev/null && echo hyprland
command -v omarchy-shell && echo "omarchy-shell present"
pgrep -x waybar >/dev/null && echo "waybar running"
```

- Stop if the vendor isn't Acer.
- The distro decides the package commands: Arch and CachyOS use `pacman`, Ubuntu and Debian use `apt`.
- The bar decides step 5: `omarchy-shell` goes to 5a, Waybar to 5b, anything else to 5c.

## 2. Find out which fan driver is active

```bash
bash "$REPO/fanctl" status
lsmod | grep -E '^(acer_wmi|linuwu_sense|facer) '
grep -rhE 'acer_wmi|linuwu|facer' /etc/modprobe.d /etc/modules-load.d 2>/dev/null
dkms status 2>/dev/null | grep -Ei 'linuwu|facer|acer'
```

Read the `backend` line of `fanctl status`:

| backend | Meaning | Next |
|---|---|---|
| `hwmon` | A driver exposes hwmon `acer` with `pwm1`/`pwm2` (mainline `acer_wmi` or a fork). | Step 4 |
| `linuwu` | Linuwu-Sense is loaded. | Step 4 |
| `none` | No fan control yet. | Step 3 |

## 3. Get a fan control driver (only if backend is `none`)

### 3a. Try mainline `acer_wmi` first

It ships with the kernel, so there's nothing to build. Newer kernels can control Predator fans through hwmon. Some models need `predator_v4=1`.

1. If `acer_wmi` is blacklisted, or another fork owns the device, **ask the user** before you change anything.
2. Try it with the user's approval:

   ```bash
   sudo modprobe -r acer_wmi 2>/dev/null; sudo modprobe acer_wmi predator_v4=1
   bash "$REPO/fanctl" status        # backend hwmon?
   ```

3. If the backend is now `hwmon`, make the setting persistent:

   ```bash
   echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi-predator.conf
   ```

   Then go to step 4.
4. If it's still `none`, undo the change (`sudo modprobe -r acer_wmi`) and go to 3b.

### 3b. Install Linuwu-Sense (DKMS)

Upstream is https://github.com/0x7375646F/Linuwu-Sense. **Read its README first.** Its installer is the source of truth and may have changed since this file was written.

`make install` does four things:
- blacklists `acer_wmi`
- registers the module with DKMS, so it rebuilds on kernel updates
- loads it at boot
- creates a `linuwu_sense` group with sysfs access

Install the build dependencies.

Arch or CachyOS: the headers package must match the running kernel. Find it with `pacman -Qo /usr/lib/modules/$(uname -r)`. Examples: `linux-headers`, `linux-zen-headers`, `linux-lts-headers`, `linux-cachyos-headers`, `linux-omarchy-headers`.

```bash
sudo pacman -S --needed git dkms base-devel <kernel>-headers
```

Ubuntu:

```bash
sudo apt install git dkms build-essential linux-headers-$(uname -r)
```

Then build and install it:

```bash
git clone https://github.com/0x7375646F/Linuwu-Sense.git /tmp/Linuwu-Sense
cd /tmp/Linuwu-Sense && sudo make install
```

Afterwards, `bash "$REPO/fanctl" status` must show `backend linuwu`. If it doesn't, show the user `dmesg | tail -50` and stop. The model may not be supported.

## 4. Let the user change fan speed without sudo

**Backend `hwmon`:** install the udev rule, which grants the `predator-fans` group write access to `pwm1`, `pwm1_enable`, `pwm2` and `pwm2_enable`.

```bash
sudo groupadd -f predator-fans
sudo usermod -aG predator-fans "$USER"
sudo install -m 0644 "$REPO/udev/99-predator-fans.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acer ] && sudo udevadm trigger --action=change "$h"; done
```

**Backend `linuwu`:** Linuwu-Sense already created its group. Check with `id -nG | grep -w linuwu_sense`, and add the user if needed: `sudo usermod -aG linuwu_sense "$USER"`.

Group membership only applies to new logins. Until the user logs out and back in, test with `sg <group> -c '...'`:

```bash
sg predator-fans -c "bash $REPO/fanctl set 1 manual 60"; sleep 5; bash "$REPO/fanctl" status
bash "$REPO/fanctl" auto
```

The CPU fan's RPM should change noticeably. If it doesn't, the firmware ignores manual control on this model. Tell the user, and skip manual speed in what you set up.

Optional: install the CLI for every bar and for keybindings.

```bash
mkdir -p ~/.local/bin && install -m 0755 "$REPO/fanctl" ~/.local/bin/predator-fanctl
```

## 5. Put it in the user's bar

### 5a. Omarchy with `omarchy-shell` (Quickshell bar)

The repo root is the plugin, so `manifest.json` sits at the top level. If the repo is on GitHub:

```bash
omarchy plugin add <git-url> --enable
```

From a local checkout:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r "$REPO" ~/.config/omarchy/plugins/samashech.fans
omarchy plugin validate ~/.config/omarchy/plugins/samashech.fans
omarchy-shell shell rescanPlugins
omarchy plugin enable samashech.fans --section centerEnd --index 0   # right next to the clock
```

Run `omarchy bar --help` for other placements. `centerBegin` and `centerEnd` sit either side of the clock. Don't put it in `center` itself, because that pushes the clock off center.

If the widget doesn't appear, run `omarchy restart shell` and check `journalctl --user -b | grep -i samashech.fans`.

The power profile buttons call `omarchy-powerprofiles-set`, which needs power-profiles-daemon. Omarchy ships it.

### 5b. Waybar (vanilla Arch, CachyOS, Ubuntu, older Omarchy, any Hyprland/Sway setup)

1. Install the dependencies. On Arch or CachyOS: `sudo pacman -S --needed jq power-profiles-daemon`. On Ubuntu: `sudo apt install jq power-profiles-daemon`. Add `nvidia-utils` (Arch) or the `nvidia-utils-<version>` that matches the driver (Ubuntu) for GPU temperature.
2. Install the scripts:

   ```bash
   install -m 0755 "$REPO/fanctl" ~/.local/bin/predator-fanctl
   install -m 0755 "$REPO/waybar/predator-fans-waybar" ~/.local/bin/predator-fans-waybar
   ~/.local/bin/predator-fans-waybar     # must print one JSON line
   ```

3. **Find the config this user's Waybar actually loads.** Check in this order and use the first hit:
   1. A `-c <file>` / `--config <file>` argument on the running process: `ps -o args= -C waybar`. Also check how it's launched: Hyprland `exec-once` in `~/.config/hypr/*.conf` or `*.lua`, or `systemctl --user cat waybar`.
   2. `$XDG_CONFIG_HOME/waybar/config.jsonc`, then `$XDG_CONFIG_HOME/waybar/config`. `XDG_CONFIG_HOME` defaults to `~/.config`.
   3. `/etc/xdg/waybar/config.jsonc` or `/etc/xdg/waybar/config`. These belong to the system, so copy them to `~/.config/waybar/` first and edit the copy.

   The style sheet is `style.css` in the same directory, or whatever `-s` points to.
4. Back up both files, then edit them:
   - Add `"custom/predator-fans"` to a module list. Ask the user which one. The default is `modules-center` right after `clock`, or `modules-right` if there's no clock in the center.
   - Paste the block from `$REPO/waybar/module.jsonc` into the top-level object. If the config is an array of bars, add it to the bar the user named.
   - Append `$REPO/waybar/style.css` to the style sheet. Adjust the colors to the user's theme if it uses `@define-color`.
5. Reload. Recent Waybar versions reload their config on `pkill -SIGUSR2 waybar`. Otherwise run `pkill waybar` and relaunch it the way it was started (on Omarchy with Waybar: `omarchy restart waybar`). Check its stderr for JSON errors.

Module controls:
- Click: Auto ↔ Max
- Scroll: ±10%
- Right-click: next power profile

The module refreshes every 5 s and immediately after each action (signal 9). If the user's config already uses signal 9, pick a free one and change it in all four places.

### 5c. Any other bar (HyprPanel, AGS, eww, i3bar, ...)

Install `~/.local/bin/predator-fanctl` as in step 4, show the user the commands below, and offer keybindings instead:

```
predator-fanctl status | toggle | max | auto | bump +10 | set 1 manual 60
```

## 6. Optional: keybindings

Ask the user which keys they want. Examples:

- **Vanilla Hyprland** (`~/.config/hypr/hyprland.conf`):

  ```
  bind = SUPER ALT, F, exec, ~/.local/bin/predator-fanctl toggle
  ```

- **Omarchy:** Hyprland config lives in `~/.config/hypr/bindings.lua`. Follow the patterns already in that file, and check that the key isn't already bound.
- **Sway** (`~/.config/sway/config`):

  ```
  bindsym $mod+Alt+f exec ~/.local/bin/predator-fanctl toggle
  ```

## 7. Verify and report

Show the user:
- the final `fanctl status`
- a screenshot or description of the bar module
- the files and groups you changed

Remind them to log out and back in if you changed group membership.

## Uninstall

1. Hand the fans back to the firmware: `predator-fanctl auto` (or `bash "$REPO/fanctl" auto`).
2. Remove the plugin. On Omarchy: `omarchy plugin remove samashech.fans`. With Waybar: remove the module from the config and style sheet, and delete `~/.local/bin/predator-fans-waybar`.
3. Remove the CLI and permissions:

   ```bash
   rm -f ~/.local/bin/predator-fanctl
   sudo rm -f /etc/udev/rules.d/99-predator-fans.rules /etc/modprobe.d/acer-wmi-predator.conf
   sudo udevadm control --reload-rules
   ```

4. Linuwu-Sense, if this guide installed it: `cd /tmp/Linuwu-Sense && sudo make uninstall`, after asking.
