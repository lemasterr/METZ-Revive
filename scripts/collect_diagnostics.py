#!/usr/bin/env python3
"""Bounded, read-only ADB snapshots; raw results stay in ignored local storage."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 262144
PROPERTIES = (
    "ro.product.manufacturer ro.product.model ro.product.device ro.product.board "
    "ro.board.platform ro.hardware ro.soc.manufacturer ro.soc.model "
    "ro.product.cpu.abilist ro.build.version.release ro.build.version.sdk "
    "ro.build.version.security_patch ro.build.fingerprint ro.build.display.id "
    "ro.build.type ro.build.tags ro.vendor.build.fingerprint ro.boot.hardware "
    "ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.slot_suffix "
    "ro.build.ab_update ro.config.low_ram ro.boot.dynamic_partitions"
)
BASELINE = [
    ("identity", "id; uname -a; getenforce; for p in " + PROPERTIES + "; do echo \"$p=$(getprop $p)\"; done"),
    ("cpu", "cat /proc/cpuinfo; cat /sys/devices/system/cpu/present; cat /sys/devices/system/cpu/online; for d in /sys/devices/system/cpu/cpufreq/policy*; do echo $d; for f in scaling_driver scaling_governor scaling_available_governors scaling_available_frequencies scaling_min_freq scaling_max_freq scaling_cur_freq cpuinfo_max_freq; do echo $f; cat $d/$f; done; done"),
    ("memory", "cat /proc/meminfo; cat /proc/swaps; for f in /sys/block/zram0/disksize /sys/block/zram0/mm_stat /sys/block/zram0/stat /proc/sys/vm/swappiness /proc/pressure/memory /proc/pressure/cpu /proc/pressure/io; do echo $f; cat $f; done"),
    ("storage", "df -k; cat /proc/partitions; cat /proc/mounts; ls -l /dev/block/by-name /dev/block/platform/*/by-name; for f in /sys/block/mmcblk0/device/name /sys/block/mmcblk0/device/type /sys/block/mmcblk0/device/life_time /sys/block/mmcblk0/device/pre_eol_info; do echo $f; cat $f; done"),
    ("thermal", "dumpsys thermalservice; for d in /sys/class/thermal/thermal_zone*; do echo $d; for f in type temp mode trip_point_0_temp trip_point_0_type; do echo $f; cat $d/$f; done; done"),
    ("cpu_load", "dumpsys cpuinfo; top -b -n 2 -d 2 -m 10"),
    ("load_interval", "echo BEGIN; cat /proc/uptime /proc/stat /proc/vmstat /proc/diskstats; sleep 3; echo END; cat /proc/uptime /proc/stat /proc/vmstat /proc/diskstats"),
    ("memory_processes", "dumpsys meminfo"),
    ("services", "dumpsys -l; service list"),
    ("packages", "pm list packages -f -U; echo SYSTEM; pm list packages -s; echo USER; pm list packages -3; echo DISABLED; pm list packages -d; echo HOME; cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"),
    ("display", "wm size; wm density; dumpsys display; dumpsys SurfaceFlinger"),
    ("media", "dumpsys media.metrics | tail -n 120; for f in /vendor/etc/media_codecs.xml /vendor/etc/media_codecs_performance.xml /vendor/etc/media_codecs_c2.xml /vendor/etc/media_codecs_google_video_le.xml; do echo $f; cat $f; done"),
    ("audio_flinger", "dumpsys media.audio_flinger"),
    ("audio_policy", "dumpsys media.audio_policy"),
    ("audio_service", "dumpsys audio; cat /proc/asound/cards; cat /proc/asound/pcm"),
    ("power", "dumpsys power"),
    ("network", "ip -s link show wlan0; ip -s link show eth0; ip route; dumpsys wifi | head -n 140; dumpsys connectivity | head -n 100; cat /proc/net/wireless"),
    ("hdmi", "dumpsys hdmi_control; dumpsys tv_input"),
    ("recovery", "ls -l /system/bin/*recovery* /system/bin/*update* /vendor/bin/*ota* /vendor/etc/*recovery* /system/etc/*recovery*; pm list packages | grep -iE 'ota|update|recovery'; ls -ld /cache/recovery /metadata/ota /data/ota_package"),
    ("events", "logcat -d -b events -t 300 -v threadtime"),
    ("errors", "logcat -d -b main -b system -b crash -t 600 -v threadtime '*:W'"),
    ("kernel", "dmesg | tail -n 100"),
]
AUDIO = [(name, command) for name, command in BASELINE if name in {
    "identity", "audio_flinger", "audio_policy", "audio_service", "power", "cpu_load", "memory", "errors"
}]
VIDEO = [(name, command) for name, command in BASELINE if name in {
    "identity", "cpu_load", "load_interval", "memory", "thermal", "media", "network", "errors"
}]
REMOTE = [(name, command) for name, command in BASELINE if name in {
    "identity", "power", "errors"
}] + [
    ("memory", "cat /proc/meminfo"),
    ("load_interval", "echo BEGIN; cat /proc/uptime /proc/stat; sleep 3; echo END; cat /proc/uptime /proc/stat"),
    ("foreground", "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|mFocusedApp'"),
    ("input_dispatch", "dumpsys input"),
    ("last_anr", "dumpsys activity lastanr"),
    # The helper can run as a shell process outside ActivityManager's app registry.
    ("phone_helper", "dumpsys package dev.vodik7.atvtoolsserver; ps -A -o USER,PID,PPID,NAME | grep -E 'vodik|adbd'; for pid in $(pidof dev.vodik7.atvtoolsserver:i); do dumpsys meminfo $pid; done"),
    ("wifi_status", "cmd wifi status"),
    ("home_frames", "dumpsys gfxinfo com.google.android.tvlauncher framestats"),
]


def capture(arguments, timeout=20):
    started = time.monotonic()
    started_utc = datetime.now(timezone.utc).isoformat()
    deadline = started + timeout
    timed_out = False
    truncated = False
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(arguments, timeout)
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                available = MAX_BYTES - len(buffer)
                truncated |= len(chunk) > available
                buffer.extend(chunk[:available])
        process.wait(timeout=max(0.001, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        process.wait()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        selector.close()
        process.stdout.close()
        process.stderr.close()
    return {
        "started_utc": started_utc,
        "duration_seconds": round(time.monotonic() - started, 3),
        "returncode": None if timed_out else process.returncode,
        "timed_out": timed_out,
        "truncated": truncated,
        "stdout": buffers["stdout"].decode("utf-8", "replace"),
        "stderr": buffers["stderr"].decode("utf-8", "replace"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Explicit ADB target; never stored in public configuration")
    parser.add_argument("--profile", choices=("baseline", "audio", "video", "remote"), default="baseline")
    parser.add_argument("--label", required=True, help="Local snapshot name, e.g. normal or distorted-audio")
    args = parser.parse_args()
    if not args.label or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-_" for c in args.label):
        parser.error("label must contain lowercase ASCII letters, digits, hyphens or underscores")
    adb = shutil.which("adb")
    if not adb:
        parser.error("adb is not installed; no installation will be attempted")
    state = capture([adb, "-s", args.serial, "get-state"], timeout=10)
    if state["returncode"] != 0 or state["stdout"].strip() != "device":
        parser.error("target is not authorized and connected; check adb devices before collecting")
    os.umask(0o077)
    folder = ROOT / "local" / "diagnostics"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = folder / (args.label + ".json")
    if destination.exists():
        parser.error("snapshot already exists; choose a distinct condition label to preserve evidence")
    commands = {"baseline": BASELINE, "audio": AUDIO, "video": VIDEO, "remote": REMOTE}[args.profile]
    snapshot = {"profile": args.profile, "label": args.label, "started_utc": datetime.now(timezone.utc).isoformat(), "results": {}}
    with destination.open("x", encoding="utf-8") as output:
        os.chmod(destination, 0o600)
        for name, command in commands:
            snapshot["results"][name] = capture([adb, "-s", args.serial, "shell", command])
            result = snapshot["results"][name]
            print(f"{name}: exit={result['returncode']} timeout={result['timed_out']} truncated={result['truncated']}", flush=True)
            output.seek(0)
            json.dump(snapshot, output, ensure_ascii=False, indent=2)
            output.write("\n")
            output.truncate()
            output.flush()
    print(f"Saved private snapshot: local/diagnostics/{destination.name}")


if __name__ == "__main__":
    main()
