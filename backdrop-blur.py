"""Scope Hyprland backdrop blur to the open OmaUpdate popup."""

import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

stopping = False


def stop(_signum, _frame):
    global stopping
    stopping = True


def hyprctl(*arguments):
    return subprocess.run(
        ["hyprctl", *arguments], capture_output=True, text=True, timeout=3, check=True
    ).stdout


def evaluate(lua):
    if hyprctl("eval", lua).strip() != "ok":
        raise RuntimeError("Hyprland rejected the backdrop setting")


def set_rule(enabled):
    if enabled:
        evaluate(
            'if not omaupdateBackdropRule then '
            'omaupdateBackdropRule = hl.layer_rule({name="omaupdate-glass", '
            'match={namespace="^omarchy-omaupdate$"}, blur=true, ignore_alpha=0.3}) '
            'end; omaupdateBackdropRule:set_enabled(true)'
        )
    else:
        evaluate("if omaupdateBackdropRule then omaupdateBackdropRule:set_enabled(false) end")


def set_global(enabled):
    value = "true" if enabled else "false"
    evaluate(f"hl.config({{decoration={{blur={{enabled={value}}}}}}})")


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Share the lock with OmaPlayer and OmaVitals while changing global blur.
    lock_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "omaplayer-backdrop.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        while not stopping:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.075)
        if stopping:
            return
        already_enabled = json.loads(hyprctl("-j", "getoption", "decoration:blur:enabled"))["bool"]
        changed_global = False
        try:
            set_rule(True)
            if not already_enabled:
                changed_global = True
                set_global(True)
            while not stopping:
                time.sleep(0.075)
        finally:
            try:
                set_rule(False)
            finally:
                if changed_global:
                    set_global(False)


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"OmaUpdate backdrop blur: {error}", file=sys.stderr)
        sys.exit(1)
