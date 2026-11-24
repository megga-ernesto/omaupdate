# ElMeGGa OmaUpdate

A status-bar update manager for **Omarchy**. It compares installed and available versions, highlights changed version segments, and opens a floating terminal for updates.

![OmaUpdate in Base, Glass and Blur](preview.jpg)

*Panels rendered from the plugin with sample data and the Rubí OLED palette. The background blur is simulated in the preview.*

## Features

- Check Arch and AUR packages, mise tools, Flatpak applications and runtimes, and Snap packages. AppImages appear in a separate local inventory.
- Compare installed and available versions, highlight the changed segments, and flag recognized kernel, graphics and core system packages.
- Scan on demand or on a schedule from 30 minutes to 24 hours.
- Review a plan in a floating terminal, apply updates, and review optional cleanup. Access the last saved report using `omaupdate --last-run`.
- See available, up-to-date, unavailable or failed sources and open installation prompts for supported missing tools.

## Install

Requires Omarchy with the Quattro shell and Python 3.11 or newer. Tested on Omarchy 4.5.0-3.

```sh
omarchy plugin add https://github.com/megga-ernesto/omaupdate.git --enable
```

Open the widget from the bar and select **Check** to scan immediately. The default 30-minute scan queries the installed managers over the network. Open **Settings** from the gear and select **Manual** under **Scanning** to disable automatic scans.

The icon and counter change color as the number of updates grows. Recognized kernel, graphics-driver, and core system packages are flagged as important by package name. This indicator does not evaluate security advisories.

## Appearance

Choose a finish in **Settings → Appearance**.

| Finish | Appearance |
|---|---|
| **Base** | Uses the active Omarchy popup colors, transparency and compositor rules. |
| **Glass** | Adds a translucent vertical gradient using 6%, 3% and 0% of the theme accent from top to bottom. |
| **Blur** | Uses the Glass gradient and asks Hyprland to soften the wallpaper and windows behind the panel. |

If Hyprland cannot apply Blur, the panel displays Glass and explains why in Appearance.

![OmaUpdate appearance and scan frequency settings](docs/appearance-settings.webp)

## Terminal command

The widget works without a command on your `PATH`. To make `omaupdate` available in an existing terminal, install an optional user-level link. The command below leaves any existing `~/.local/bin/omaupdate` in place.

```sh
mkdir -p "$HOME/.local/bin"
ln -s -- "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/elmegga.omaupdate/omaupdate" "$HOME/.local/bin/omaupdate"
```

If `~/.local/bin` is on your `PATH`, run:

```sh
omaupdate
omaupdate --last-run
```

## Updates, permissions, and cleanup

- The widget scans pacman with `checkupdates` (`pacman-contrib`), AUR with `yay`, and mise with `mise`. Flatpak and Snap are queried when their tools are installed. AppImage support is a local inventory only.
- **Update** presents a plan before running Flatpak user and system updates, Snap refresh, and `omarchy update`. Omarchy handles pacman, AUR, mise, and its own migrations. Missing managers are reported and processing continues.
- **Install** offers the relevant Omarchy package command for a missing manager. Installing Snap uses AUR and enables the snapd socket. Install and update commands can ask for administrator privileges in the terminal.
- Cleanup is offered after the update commands finish without errors. It can prune older pacman cache entries, remove unused Flatpak references, and clear mise caches or remove unused tool versions. Local Steam libraries are only offered for review when Steam appears to be absent. Moving a library to the Trash and permanently emptying the Trash are separate choices.
- The interactive selector uses Gum when available. **Yes** is highlighted by default for updates and other prompts. **No** is highlighted when permanently emptying the Trash. Use the arrow keys to change the selection before pressing Enter.
- The panel follows the language set in Omarchy, and the terminal follows the session locale. Both include English and Spanish translations. The last update report is saved to `${XDG_STATE_HOME:-$HOME/.local/state}/omaupdate/last-run.txt`.

The plugin is an independent community project. It uses Omarchy and the selected package managers on the local machine. Its own code does not send the update report to a remote service.

## Update or remove the plugin

Update the plugin itself from GitHub with `omarchy plugin update elmegga.omaupdate`. To remove it:

```sh
omarchy plugin remove elmegga.omaupdate
```

If you created the optional command link, remove that specific link:

```sh
cli="$HOME/.local/bin/omaupdate"
target="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/elmegga.omaupdate/omaupdate"
if [ "$(readlink -- "$cli")" = "$target" ]; then
  unlink -- "$cli"
fi
```

The saved report is kept in your state directory after removal.

## Credits and license

OmaUpdate code is licensed under the [MIT License](LICENSE). The terminal banner includes a rendering of the Omarchy icon from the [Omarchy project](https://github.com/omacom/omarchy), attributed in [NOTICE](NOTICE.md). Omarchy marks belong to their respective owner. The banner lettering is rendered from JetBrains Mono Nerd Font.
