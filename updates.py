#!/usr/bin/env python3
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import fcntl
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import textwrap
import tomllib

HOME = Path.home()
LIMIT = 300
APPLICATION_DIRS = (HOME / "Applications", HOME / "AppImages", HOME / ".local/bin")
INSTALL_ACTIONS = {
    "flatpak": ("Flatpak", (("omarchy", "pkg", "add", "flatpak"),)),
    "snap": ("Snap", (
        ("omarchy", "pkg", "aur", "add", "snapd"),
        ("sudo", "systemctl", "enable", "--now", "snapd.socket"),
    )),
    "mise": ("mise", (("omarchy", "pkg", "add", "mise"),)),
    "yay": ("yay", (("omarchy", "pkg", "add", "yay"),)),
    "checkupdates": ("checkupdates", (("omarchy", "pkg", "add", "pacman-contrib"),)),
}
INSTALL_BY_SOURCE = {
    "Flatpak": "flatpak", "Snap": "snap", "mise": "mise", "AUR": "yay", "pacman": "checkupdates",
}


def message_language():
    locale = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or "C"
    if locale.split(".", 1)[0] in {"C", "POSIX"}:
        return "en"
    for candidate in [*os.environ.get("LANGUAGE", "").split(":"), locale]:
        language = candidate.lower().replace("-", "_").split("_", 1)[0].split(".", 1)[0].split("@", 1)[0]
        if language in {"en", "es"}:
            return language
    return "en"


def load_messages():
    directory = Path(__file__).with_name("i18n")
    messages = {}
    for language in dict.fromkeys(("en", message_language())):
        try:
            messages.update(json.loads((directory / f"{language}.json").read_text(encoding="utf-8")))
        except (OSError, ValueError):
            continue
    return messages


MESSAGES = load_messages()


def t(key, **values):
    return MESSAGES.get(key, key).format(**values)


def query(command, accepted=(0,), extra_env=None):
    env = {**os.environ, "LC_ALL": "C", **(extra_env or {})}
    result = subprocess.run(
        ["timeout", "--kill-after=3s", "75s", *command],
        cwd=HOME, env=env, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, errors="replace",
    )
    if result.returncode not in accepted:
        detail = result.stderr.strip() or result.stdout.strip() or str(result.returncode)
        raise ValueError(detail[-600:])
    return result.stdout


VERSION_TOKENS = re.compile(r"[0-9]+|[A-Za-z]+|.")
NUMERIC_VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
PACKAGE_UPDATE = re.compile(r"^(\S+)\s+(\S+)\s+(?:->|→)\s+(\S+)\s*$")


KERNEL_PACKAGE = re.compile(
    r"linux(?:-(?:lts|zen|hardened|rt|rt-lts|cachyos(?:-[a-z0-9]+)*|tkg(?:-[a-z0-9]+)*|xanmod(?:-[a-z0-9]+)*))?(?:-headers)?"
)
GRAPHICS_PACKAGE = re.compile(
    r"(?:lib32-)?(?:nvidia(?:-[0-9]+xx)?(?:-(?:open|dkms|lts|utils))*"
    r"|mesa(?:-git)?|vulkan-(?:radeon|intel|nouveau|swrast|icd-loader)|xf86-video-(?:amdgpu|intel|nouveau))"
)
CORE_PACKAGES = {
    "amd-ucode", "intel-ucode", "glibc", "openssl", "systemd", "systemd-libs",
    "pacman", "archlinux-keyring", "archlinuxarm-keyring", "omarchy-keyring",
    "mkinitcpio", "dracut", "booster", "limine", "grub", "cryptsetup", "lvm2",
}


def package_priority(name):
    if KERNEL_PACKAGE.fullmatch(name):
        return "kernel"
    if GRAPHICS_PACKAGE.fullmatch(name):
        return "graphics"
    if name in CORE_PACKAGES or name == "linux-firmware" or name.startswith("linux-firmware-"):
        return "system"
    return ""


def version_parts(current, available):
    old = VERSION_TOKENS.findall(current)
    new = VERSION_TOKENS.findall(available)
    prefix = 0
    while prefix < min(len(old), len(new)) and old[prefix] == new[prefix]:
        prefix += 1
    suffix = 0
    while suffix < min(len(old), len(new)) - prefix and old[-1 - suffix] == new[-1 - suffix]:
        suffix += 1

    def split(tokens):
        end = len(tokens) - suffix
        return ["".join(tokens[:prefix]), "".join(tokens[prefix:end]), "".join(tokens[end:])]

    return split(old), split(new)


def version_kind(current, available, arch):
    if not current or not available or current == available:
        return ""
    if arch:
        old_epoch, _, old_version = current.rpartition(":")
        new_epoch, _, new_version = available.rpartition(":")
        if (old_epoch or "0") != (new_epoch or "0"):
            return ""
        old_core, old_sep, old_release = old_version.rpartition("-")
        new_core, new_sep, new_release = new_version.rpartition("-")
        if old_sep and new_sep and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", old_release) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", new_release):
            if old_core == new_core and old_release != new_release:
                return "revision"
            current, available = old_core, new_core
        else:
            current, available = old_version, new_version
    old = NUMERIC_VERSION.fullmatch(current)
    new = NUMERIC_VERSION.fullmatch(available)
    if old and new:
        if any(1900 <= int(match[1]) <= 2199 and 1 <= int(match[2]) <= 12 for match in (old, new)):
            return ""
        for index, kind in enumerate(("major", "minor", "patch"), 1):
            if old[index] != new[index]:
                return kind
    return ""


def version_update(name, current="", available="", *, arch=False, change=None):
    current = (current or "")[:160]
    available = (available or "")[:160]
    old, new = version_parts(current, available) if current and available else (
        [current, "", ""], [available, "", ""],
    )
    return {
        "name": name[:300], "current": old, "available": new,
        "kind": change or version_kind(current, available, arch),
        "priority": package_priority(name) if arch else "",
    }


def package_update(line):
    match = PACKAGE_UPDATE.fullmatch(line.strip())
    return version_update(*match.groups(), arch=True) if match else version_update(line.strip())


def row(source, status, items=(), detail="", group=""):
    items = sorted(items, key=lambda item: not item.get("priority"))
    return {
        "source": source, "status": status, "count": len(items),
        "important": any(item.get("priority") for item in items),
        "items": items[:LIMIT],
        "detail": detail[:600], "group": group,
        "install": INSTALL_BY_SOURCE.get(source, "") if status == "missing" else "",
    }


def check(source, executable, group, get_items):
    if not shutil.which(executable):
        return row(source, "missing")
    try:
        items = get_items()
        return row(source, "pending" if items else "current", items, group=group)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        return row(source, "error", detail=str(error))


def system():
    if not shutil.which("checkupdates"):
        return [row("Omarchy", "missing"), row("pacman", "missing")]
    try:
        updates = query(["checkupdates", "--nocolor"], (0, 2)).splitlines()
    except (OSError, ValueError) as error:
        return [row(source, "error", detail=str(error)) for source in ("Omarchy", "pacman")]

    packages, omarchy = [], []
    for item in filter(str.strip, updates):
        target = omarchy if item.split()[0] in {"omarchy", "omarchy-dev"} else packages
        target.append(package_update(item))
    pacman = row("pacman", "pending" if packages else "current", packages, group="system")
    checkout = os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")
    try:
        if Path(checkout).resolve() != Path("/usr/share/omarchy"):
            upstream = query(["git", "-C", checkout, "rev-parse", "--abbrev-ref", "@{upstream}"]).strip()
            query(["git", "-C", checkout, "fetch", "--quiet"], extra_env={"GIT_TERMINAL_PROMPT": "0"})
            commits = int(query(["git", "-C", checkout, "rev-list", "--count", "HEAD.." + upstream]))
            if commits:
                omarchy.append(version_update(f"{upstream} (+{commits})"))
    except (OSError, ValueError) as error:
        return [row("Omarchy", "error", omarchy, str(error), "system"), pacman]
    return [row("Omarchy", "pending" if omarchy else "current", omarchy, group="system"), pacman]


def aur():
    names = set(query(["pacman", "-Qemq"], (0, 1)).splitlines()) - {"gcc14", "gcc14-libs"}
    if not names:
        return []
    output = query(["yay", "-Qua", "--color", "never"])
    return [package_update(line) for line in output.splitlines() if line.split() and line.split()[0] in names]


def mise():
    output = query(
        ["mise", "outdated", "--global", "--json"],
        extra_env={"MISE_MINIMUM_RELEASE_AGE": "0"},
    )
    return [
        version_update(entry["name"], entry["current"], entry["latest"])
        for entry in json.loads(output).values()
        if entry.get("current") and entry.get("latest")
    ]


def flatpak(scope):
    columns = "--columns=ref,version,origin"
    available = query(["flatpak", scope, "remote-ls", "--updates", columns]).splitlines()
    if not available:
        return []
    installed = {}
    for line in query(["flatpak", scope, "list", columns]).splitlines():
        fields = line.split("\t")
        if len(fields) >= 3:
            ref, version, origin = fields[:3]
            installed[(ref, origin)] = version

    items = []
    for line in available:
        fields = line.split("\t")
        if len(fields) < 3:
            items.append(version_update(line))
            continue
        ref, version, origin = fields[:3]
        items.append(version_update(ref, installed.get((ref, origin)), version))
    return items


def snap():
    output = query(["snap", "refresh", "--list"])
    if "All snaps up to date." in output:
        return []
    lines = output.splitlines()
    if lines and lines[0].split()[:2] != ["Name", "Version"]:
        raise ValueError(output[-600:])
    if len(lines) <= 1:
        return []

    installed = {}
    for line in query(["snap", "list"]).splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 3:
            installed[fields[0]] = tuple(fields[1:3])
    items = []
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < 3:
            continue
        name, version, revision = fields[:3]
        old_version, old_revision = installed.get(name, ("", ""))
        if old_version == version and old_revision != revision:
            items.append(version_update(name, f"{version} [{old_revision}]", f"{version} [{revision}]", change="revision"))
        else:
            items.append(version_update(name, old_version, version))
    return items


def appimages():
    files = []
    for directory in APPLICATION_DIRS:
        if directory.is_dir():
            files.extend(
                path.name for path in directory.iterdir()
                if path.suffix.lower() == ".appimage" and path.is_file()
            )
    return row("AppImage", "manual", map(version_update, sorted(files, key=str.casefold)))


def scan():
    with ThreadPoolExecutor(max_workers=7) as pool:
        jobs = [
            pool.submit(system),
            pool.submit(check, "AUR", "yay", "system", aur),
            pool.submit(check, "mise", "mise", "system", mise),
            pool.submit(check, "flatpak-user", "flatpak", "flatpak-user", lambda: flatpak("--user")),
            pool.submit(check, "flatpak-system", "flatpak", "flatpak-system", lambda: flatpak("--system")),
            pool.submit(check, "Snap", "snap", "snap", snap),
            pool.submit(appimages),
        ]
        packages, aur_row, mise_row, flatpak_user, flatpak_system, snap_row, images = (
            job.result() for job in jobs
        )
    flatpak_rows = [flatpak_user, flatpak_system]
    if all(source["status"] == "missing" for source in flatpak_rows):
        flatpak_rows = [row("Flatpak", "missing")]
    return [*packages, aur_row, mise_row, *flatpak_rows, snap_row, images]


UPDATE_STEPS = (
    (
        ("flatpak", "--user", "update"),
        "cli.updateFlatpakUser",
        "flatpak",
    ),
    (
        ("flatpak", "--system", "update"),
        "cli.updateFlatpakSystem",
        "flatpak",
    ),
    (
        ("sudo", "snap", "refresh"),
        "cli.updateSnap",
        "snap",
    ),
    (
        ("omarchy", "update", "-y"),
        "cli.updateOmarchy",
        "omarchy",
    ),
)


CLEANUP_STEPS = (
    (
        ("sudo", "paccache", "-ruk0", "--min-mtime", "30 days ago"),
        "cli.cleanPacman",
        "paccache",
    ),
    (
        ("flatpak", "--user", "uninstall", "--unused"),
        "cli.cleanFlatpakUser",
        "flatpak",
    ),
    (
        ("flatpak", "--system", "uninstall", "--unused"),
        "cli.cleanFlatpakSystem",
        "flatpak",
    ),
    (
        ("mise", "prune", "--configs"),
        "cli.cleanMiseConfigs",
        "mise",
    ),
    (
        ("mise", "cache", "clear"),
        "cli.cleanMiseCache",
        "mise",
    ),
)


# Fixed status hues keep their meaning in monochrome themes. The light
# variants provide readable contrast on themes with a light background.
TERMINAL_COLORS = {
    "success": ("#72d6a0", "#176e3e"),
    "error": ("#ff7180", "#aa1c35"),
    "warning": ("#e8c566", "#795000"),
    "prompt": ("#80c9ff", "#115f9b"),
}


@lru_cache(maxsize=1)
def terminal_uses_light_theme():
    try:
        theme = HOME / ".local/state/omarchy/current/theme/colors.toml"
        with theme.open("rb") as stream:
            return tomllib.load(stream).get("mode") == "light"
    except (OSError, ValueError):
        return False


def terminal_color(tone):
    return TERMINAL_COLORS[tone][terminal_uses_light_theme()]


def styled(text, tone):
    if not tone or not os.isatty(1) or os.environ.get("TERM") == "dumb":
        return text
    hex_color = terminal_color(tone)
    red, green, blue = (int(hex_color[index:index + 2], 16) for index in (1, 3, 5))
    return f"\033[1;38;2;{red};{green};{blue}m{text}\033[0m"


def wait_to_close():
    try:
        input("\n" + styled(t("cli.closeHint"), "prompt"))
    except (EOFError, KeyboardInterrupt):
        pass


def report_path():
    state = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state")
    return state / "omaupdate" / "last-run.txt"


class Report:
    def __init__(self):
        self.path = report_path()
        self.entries = [
            (t("cli.summaryHeading"), "prompt"),
            (datetime.now().astimezone().isoformat(timespec="seconds"), ""),
        ]
        self.current = ""
        self.finished = False
        self.warned = False
        self.save()

    def save(self):
        pending = []
        if self.current:
            pending.append(t("cli.summaryPending", step=self.current))
        if not self.finished:
            pending.append(t("cli.summaryUnfinished"))
        temporary = None
        try:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write("\n".join([message for message, _ in self.entries] + pending) + "\n")
            temporary.replace(self.path)
        except OSError:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass

    def begin(self, command):
        self.current = " ".join(command)
        self.save()

    def record(self, message, tone=""):
        self.entries.append((message, tone))
        self.current = ""
        self.save()

    def finish(self, status):
        if status == 130:
            key, tone = "cli.summaryStopped", "warning"
        elif status:
            key, tone = "cli.summaryWithErrors", "error"
        elif self.warned:
            key, tone = "cli.summaryWithWarnings", "warning"
        else:
            key, tone = "cli.summaryFinished", "success"
        self.finished = True
        self.record(t(key), tone)

    def display(self):
        print()
        for message, tone in self.entries:
            print(styled(message, tone), flush=True)


def apply():
    lock_path = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    with (lock_path / "omaupdate.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(styled(t("cli.locked"), "warning"))
            return 1
        report = Report()
        status = 0
        try:
            for command, _, manager in UPDATE_STEPS:
                result = run_step(command, report, manager)
                if result == 130:
                    status = result
                    break
                status = status or result
            if status:
                message = t("cli.cleanupSkipped")
                print("\n" + styled(message, "warning"))
                report.record(message, "warning")
            else:
                status = cleanup(report)
        except KeyboardInterrupt:
            report.record(t("cli.summaryInterrupted", step=report.current or t("cli.cleanupHeading")), "warning")
            status = 130
        except Exception as error:
            report.record(t("cli.commandError", error=error), "error")
            status = 1
        report.finish(status)
        report.display()
        return status


OMARCHY_LOG = Path("/tmp/omarchy-update.log")
OMARCHY_WARNINGS = {
    b"Some mise tools could not be updated": "cli.miseUpdateWarning",
    b"AUR is unavailable (so skipping updates)": "cli.aurUpdateWarning",
}


def log_stamp(info):
    return (info.st_ino, info.st_mtime_ns, info.st_size)


def omarchy_log_stamp():
    try:
        return log_stamp(OMARCHY_LOG.lstat())
    except OSError:
        return None


def omarchy_log_warnings(previous):
    try:
        fd = os.open(OMARCHY_LOG, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as log:
            info = os.fstat(log.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or log_stamp(info) == previous:
                return []
            log.seek(max(0, info.st_size - 65536))
            tail = log.read(65536)
    except OSError:
        return []
    return [t(key) for phrase, key in OMARCHY_WARNINGS.items() if phrase in tail]


def run_step(command, report=None, manager=None):
    label = " ".join(command)
    print("\n" + label, flush=True)
    if report:
        report.begin(command)
    env = None
    executable = command
    log_before = None
    if manager == "omarchy":
        log_before = omarchy_log_stamp()
        # Defer Omarchy's reboot prompt until after this terminal's summary.
        env = {**os.environ, "OMARCHY_UPDATE_UNATTENDED": "1"}
    elif manager == "snap" and not shutil.which("snap"):
        # Attempt the executable without asking for sudo on systems without Snap.
        executable = command[1:]

    try:
        result = subprocess.run(executable, cwd=HOME, env=env)
    except FileNotFoundError as error:
        if manager and error.filename == manager:
            message = t("cli.managerMissing", manager=manager)
            print(styled(message, "warning"), flush=True)
            if report:
                report.record(f"  · {label} — {message}", "warning")
            return 0
        return record_command_error(label, error, report)
    except OSError as error:
        return record_command_error(label, error, report)
    if result.returncode in (-2, 130):
        if report:
            report.record(t("cli.summaryInterrupted", step=label), "warning")
        return 130
    if result.returncode:
        print(styled(t("cli.commandStatus", code=result.returncode), "error"), flush=True)
        if report:
            report.record(t("cli.summaryFailed", step=label, code=result.returncode), "error")
        return 1
    if report:
        report.record(t("cli.summaryDone", step=label), "success")
        if manager == "omarchy":
            for warning in omarchy_log_warnings(log_before):
                report.warned = True
                report.record("  ! " + warning, "warning")
    return 0


def record_command_error(label, error, report):
    message = t("cli.commandError", error=error)
    print(styled(message, "error"), flush=True)
    if report:
        report.record(f"  ! {label} — {message}", "error")
    return 1


def run_plan(plan, report=None):
    status = 0
    for command, _ in plan:
        result = run_step(command, report)
        if result == 130:
            return result
        status = status or result
    return status


def ask(prompt, tone="prompt"):
    gum = shutil.which("gum")
    if gum and os.isatty(0) and os.isatty(1) and os.environ.get("TERM") != "dumb":
        print(t("cli.continueHint"), flush=True)
        command = [
            gum, "confirm", "--default=true", "--timeout=0s", "--no-show-help",
            "--prompt.foreground", terminal_color(tone),
            "--affirmative", t("cli.yes"), "--negative", t("cli.no"), "--", prompt,
        ]
        theme = shutil.which("omarchy-restart-gum")
        if theme:
            command = [
                "bash", "-c",
                'source "$1"; shift; '
                'export GUM_CONFIRM_SELECTED_BACKGROUND="${GUM_CONFIRM_UNSELECTED_FOREGROUND:-7}"; '
                'export GUM_CONFIRM_SELECTED_FOREGROUND="${GUM_CONFIRM_UNSELECTED_BACKGROUND:-0}"; '
                'exec "$@"',
                "omaupdate", theme, *command,
            ]
        # Gum uses the selected background to show which answer has focus.
        # Keep that contrast local to this prompt even when the parent is monochrome.
        env = os.environ.copy()
        env.pop("NO_COLOR", None)
        try:
            return subprocess.run(command, env=env).returncode == 0
        except OSError:
            return False

    try:
        answer = input(styled(prompt, tone) + " " + t("cli.confirmChoices"))
    except EOFError:
        return False
    return answer.strip().casefold() in {"", "s", "sí", "si", "y", "yes"}


def steam_may_be_installed():
    if any(shutil.which(name) for name in ("steam", "steam-native", "steam-runtime")):
        return True
    if not shutil.which("pacman") or not shutil.which("pgrep"):
        return True
    try:
        packages = query(["pacman", "-Qq"]).splitlines()
        if any(name in {"steam", "steam-native-runtime", "steam-runtime", "steam-launcher", "steam-deb", "steam-beta"} for name in packages):
            return True
        if query(["pgrep", "-u", str(os.getuid()), "-x", "steam|steamwebhelper"], (0, 1)).strip():
            return True
        if shutil.which("flatpak"):
            for scope in ("--user", "--system"):
                applications = query(["flatpak", scope, "list", "--app", "--columns=application"]).splitlines()
                if "com.valvesoftware.Steam" in applications:
                    return True
        if shutil.which("snap"):
            installed = query(["snap", "list"]).splitlines()
            if any(line.split()[:1] == ["steam"] for line in installed):
                return True
    except (OSError, ValueError):
        return True
    return False


def steam_libraries():
    data_home = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
    candidates = (
        HOME / ".local/share/Steam/steamapps",
        data_home / "Steam/steamapps",
        HOME / ".steam/steam/steamapps",
        HOME / ".steam/root/steamapps",
        HOME / ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps",
        HOME / "snap/steam/common/.local/share/Steam/steamapps",
    )
    home = HOME.resolve()
    if not shutil.which("findmnt"):
        return {}
    try:
        raw = json.loads(query(["findmnt", "--json", "--list", "--output", "TARGET"]))
        mounts = [Path(entry["target"]) for entry in raw["filesystems"]]
    except (KeyError, OSError, TypeError, ValueError):
        return {}

    libraries = {}
    for candidate in candidates:
        try:
            library = candidate.resolve(strict=True)
            # Only real, known data paths below this home. Aliases can point to
            # one of these paths, never to a custom library or another volume.
            if not library.is_relative_to(home) or library not in candidates:
                continue
            if not library.is_dir() or any(mount.is_relative_to(library) for mount in mounts):
                continue
            info = library.stat()
            if info.st_uid == os.getuid():
                libraries[library] = (info.st_dev, info.st_ino)
        except (OSError, RuntimeError):
            continue
    return libraries


def review_steam_libraries(report):
    libraries = steam_libraries()
    if not libraries or steam_may_be_installed():
        return 0

    print("\n" + t("cli.steamHeading"))
    print(t("cli.steamContents"))
    status = 0
    for library, identity in libraries.items():
        try:
            size = query(["du", "-shx", "--", str(library)]).split("\t", 1)[0].strip()
        except (OSError, ValueError):
            size = t("cli.unknownSize")
        print(f"\n  {library!s} ({size})")
        if not ask(t("cli.steamConfirm"), "warning"):
            report.record(t("cli.summaryDeclined", step=str(library)), "warning")
            continue
        if steam_may_be_installed() or steam_libraries().get(library) != identity:
            print(styled(t("cli.steamChanged"), "warning"))
            continue
        result = run_plan([(("gio", "trash", "--", str(library)), "")], report)
        if result == 130:
            return result
        status = status or result
    return status


def cleanup(report):
    plan = [(command, description) for command, description, manager in CLEANUP_STEPS if shutil.which(manager)]
    has_mise = bool(shutil.which("mise"))
    has_trash = bool(shutil.which("gio"))
    if not (plan or has_mise or has_trash):
        report.record(t("cli.summaryNoCleanup"))
        return 0

    report.record(t("cli.cleanupHeading"), "prompt")
    print("\n" + styled(t("cli.cleanupHeading"), "prompt"))
    print(t("cli.pacmanCleanupNote"))
    status = 0
    if plan:
        for _, description in plan:
            print(f"  › {t(description)}")
        if ask("\n" + t("cli.cleanupConfirm"), "warning"):
            status = run_plan(plan, report)
            if status == 130:
                return status
        else:
            report.record(t("cli.summaryDeclined", step=t("cli.cleanupHeading")), "warning")

    if has_mise:
        print("\n" + t("cli.misePreview"))
        preview = run_plan([(("mise", "prune", "--tools", "--dry-run"), "")], report)
        if preview == 130:
            return preview
        if preview == 0:
            if ask(t("cli.miseConfirm"), "warning"):
                result = run_plan([(("mise", "prune", "--tools"), "")], report)
                if result == 130:
                    return result
                status = status or result
            else:
                report.record(t("cli.summaryDeclined", step="mise prune --tools"), "warning")
        status = status or preview

    if has_trash:
        result = review_steam_libraries(report)
        if result == 130:
            return result
        status = status or result

    if has_trash:
        if ask("\n" + t("cli.trashConfirm"), "error"):
            result = run_plan([(("gio", "trash", "--empty"), "")], report)
            if result == 130:
                return result
            status = status or result
        else:
            report.record(t("cli.summaryDeclined", step="gio trash --empty"), "warning")
    return status


def show_banner():
    try:
        columns = os.get_terminal_size().columns
        banner = Path(__file__).with_name("banner.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        columns, banner = 0, []

    if os.environ.get("TERM") == "dumb" or not banner or columns < max(map(len, banner)) + 2:
        print("\nOMAUPDATE · OMARCHY\n")
        return

    print()
    for line in banner:
        icon, title = line[:16], line[16:]
        print(f"  \033[32m{icon}\033[0m\033[1m{title}\033[0m")
    print()


def confirm_update():
    columns = max(24, min(shutil.get_terminal_size().columns, 80))
    colors = os.environ.get("TERM") != "dumb" and "NO_COLOR" not in os.environ
    bold, accent, reset = ("\033[1m", "\033[36m", "\033[0m") if colors else ("", "", "")
    indent = "  "
    print(f"{indent}{bold}{t('cli.planHeading')}{reset}")
    print(f"{indent}{accent}{'─' * (columns - len(indent))}{reset}")
    print(textwrap.fill(
        t("cli.planIntro"),
        width=columns, initial_indent=indent, subsequent_indent=indent,
    ))
    for command, description, _ in UPDATE_STEPS:
        print(f"\n{indent}{accent}›{reset} {bold}{' '.join(command)}{reset}")
        print(textwrap.fill(t(description), width=columns, initial_indent="    ", subsequent_indent="    "))
    print(textwrap.fill(
        t("cli.afterUpdate"),
        width=columns, initial_indent=indent, subsequent_indent=indent,
    ))
    print()
    return ask(indent + t("cli.updateConfirm"))


def install_manager(manager, hold):
    name, commands = INSTALL_ACTIONS[manager]
    if manager == "snap":
        try:
            apparmor = Path("/sys/module/apparmor/parameters/enabled").read_text().strip() == "Y"
        except OSError:
            apparmor = False
        if apparmor:
            commands += (("sudo", "systemctl", "enable", "--now", "snapd.apparmor.service"),)

    show_banner()
    print(t("cli.installHeading", name=name))
    for command in commands:
        print("  › " + " ".join(command))
    print("\n" + t("cli.installNote"))
    if not ask(t("cli.installConfirm")):
        return 0

    try:
        for command in commands:
            status = run_plan([(command, "")])
            if status:
                return status
        print("\n" + styled(t("cli.installDone", name=name), "success"))
        if shutil.which("omarchy-shell"):
            subprocess.run(["omarchy-shell", "-q", "elmegga.omaupdate", "rescanInstalled"], cwd=HOME)
        return 0
    finally:
        if hold:
            wait_to_close()


def main():
    parser = argparse.ArgumentParser(
        prog="omaupdate",
        description=t("cli.description"),
    )
    parser.add_argument("action", choices=("scan", "apply", "install"))
    parser.add_argument("--hold", action="store_true", help=t("cli.holdHelp"))
    parser.add_argument("--manager", choices=INSTALL_ACTIONS)
    parser.add_argument("--last-run", action="store_true", help=t("cli.lastRunHelp"))
    args = parser.parse_args()
    if args.last_run:
        try:
            print(report_path().read_text(encoding="utf-8"), end="")
        except FileNotFoundError:
            print(t("cli.noLastRun"))
            return 1
        return 0
    if (args.action == "install") != bool(args.manager):
        parser.error(t("cli.installArgument"))
    if args.action == "scan":
        print(json.dumps(scan(), ensure_ascii=False))
        return 0
    if not os.isatty(0):
        parser.error(t("cli.requiresTerminal"))

    if args.action == "install":
        try:
            return install_manager(args.manager, args.hold)
        except KeyboardInterrupt:
            return 130

    show_banner()
    try:
        if not confirm_update():
            print(styled(t("cli.updateCanceled"), "warning"))
            return 0
        return apply()
    except KeyboardInterrupt:
        return 130
    except OSError as error:
        print(styled(t("cli.commandError", error=error), "error"))
        return 1
    finally:
        if args.hold:
            wait_to_close()


if __name__ == "__main__":
    raise SystemExit(main())
