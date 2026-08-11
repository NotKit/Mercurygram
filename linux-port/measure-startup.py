#!/usr/bin/env python3
"""Start-up and memory measurement: HotSpot vs native image, one definition.

Driven by measure-startup.sh, which sources env.sh and exports the paths this
reads (PORT_OUT, ATLAS_OUT, JAVA_HOME, PORT_IMAGE_LIB, PORT_MEASURE_OUT).

One run = drop the page cache, exec the launcher directly (the same argv run.sh
builds, so nothing of run.sh's own is being timed), and timestamp

  - every launcher/liblog stderr line, which is what dates the boot markers;
  - the X root window, sampled every ~100 ms with `xwd -root`.

Two pixel events are recorded separately, because conflating them flatters the
number by 2.8-3.4 s:

  window_mapped  the first sample with >=1% non-black pixels. That is GLFW's
                 empty white window, not the app.
  first_frame    the next sample whose pixels differ from that blank window,
                 i.e. the first thing the app painted. This is the headline
                 number. Both .xwd files are written out so the split can be
                 checked by eye.

RSS/PSS are read from /proc/<pid> at a fixed wall clock (the run length), not at
a marker, because both runtimes keep growing after the chat list appears.

Usage: measure-startup.py DISPLAY ROUNDS SECONDS DATA_DIR
       one round is one hotspot run then one image run, alternated so drift
       hits both. NO_DROP=1 skips the page-cache drop (warm runs).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time

# Empty defaults so `--summary` works without env.sh; a measuring run needs them
# and measure-startup.sh exports them.
OUT = os.environ.get("PORT_OUT", "")
ATLAS = os.environ.get("ATLAS_OUT", "")
IMAGE_LIB = os.environ.get("PORT_IMAGE_LIB", OUT + "/image/libmercurygram.so")
TMP = os.environ.get("PORT_MEASURE_OUT", OUT + "/measure")

MARKERS = [
    ("vm_created", re.compile(r"^JVM launched successfully")),
    ("app_created", re.compile(r"^boot: application created")),
    ("providers", re.compile(r"^boot: content providers created")),
    ("app_oncreate", re.compile(r"^boot: Application\.onCreate returned")),
    ("activity", re.compile(r"boot: main activity started")),
    ("dialogs", re.compile(r"loaded folderId 0 loadType 1 count [0-9]+")),
]


def drop_caches():
    if os.environ.get("NO_DROP"):
        return
    subprocess.run(["sudo", "-n", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"],
                   check=True)


def sample_root(display):
    p = subprocess.run(["xwd", "-root", "-silent"], capture_output=True,
                       env=dict(os.environ, DISPLAY=display))
    b = p.stdout
    if not b:
        return None, None, None
    # xwd: header + colourmap, then raw 32bpp pixels. Skip a generous header.
    px = b[4096:]
    nz = len(px) - px.count(0)
    return nz / max(1, len(px)), hashlib.md5(px).hexdigest(), b


def run_once(backend, display, seconds, data_dir):
    launcher = "%s/android-translation-layer-%s" % (ATLAS, backend)
    env = dict(os.environ)
    env["DISPLAY"] = display
    env["ANDROID_APP_DATA_DIR"] = data_dir
    env["ATL_NO_GPU"] = "1"
    env["ANDROID_LOG_TAGS"] = "*:V"
    if backend == "image":
        env["LD_LIBRARY_PATH"] = os.path.dirname(IMAGE_LIB) + ":" + ATLAS
    else:
        env["LD_LIBRARY_PATH"] = env["JAVA_HOME"] + "/lib/server:" + ATLAS

    argv = [launcher,
            "--api-impl-jar", ATLAS + "/api-impl.jar",
            "--framework-res", ATLAS + "/framework-res.apk",
            "--natives-dir", ATLAS,
            "--classpath", OUT + "/shim.jar:" + OUT + "/classpath/*",
            "--library-path", OUT,
            "--launch-activity", "org.telegram.ui.LaunchActivity",
            "-X", "-Dtmessages.native.path=" + OUT + "/libtmessages.so"]
    if backend == "image":
        argv += ["--vm-library", IMAGE_LIB]
    else:
        argv += ["-X", "-XX:ErrorFile=" + TMP + "/hs_err_pid%p.log"]
    argv += ["-X", "-Dtmessages.tldump=0", OUT + "/app.apk"]

    drop_caches()
    time.sleep(2)

    base, _, _ = sample_root(display)
    res = {"backend": backend, "baseline_nonblack": base, "marks": {}, "frames": []}

    tag = "%s-%d" % (backend, int(time.time()))
    log = open("%s/startup-%s.log" % (TMP, tag), "w")
    t0 = time.monotonic()
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=1,
                            universal_newlines=True, errors="replace")

    def reader():
        for line in proc.stdout:
            t = time.monotonic() - t0
            log.write("%8.3f %s" % (t, line))
            for name, rx in MARKERS:
                if name not in res["marks"] and rx.search(line):
                    res["marks"][name] = t
    th = threading.Thread(target=reader, daemon=True)
    th.start()

    window = None
    window_hash = None
    content = None
    deadline = t0 + seconds
    while time.monotonic() < deadline:
        f, h, raw = sample_root(display)
        t = time.monotonic() - t0
        res["frames"].append([round(t, 3), f, h])
        if window is None and f is not None and f >= 0.01:
            window = t
            window_hash = h
            res["marks"]["window_mapped"] = t
            open("%s/shot-%s-window.xwd" % (TMP, tag), "wb").write(raw)
        elif window is not None and content is None and h != window_hash:
            content = t
            res["marks"]["first_frame"] = t
            open("%s/shot-%s-frame.xwd" % (TMP, tag), "wb").write(raw)
        # Stop sampling a few seconds after the chat list is up: 10 xwd captures
        # a second of a 960x540 root window is real load, and the memory phase
        # below has to read RSS off an app nobody is poking.
        if content is not None and "dialogs" in res["marks"] and t - content > 3:
            break
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    res["tag"] = tag

    # Settle: stop touching the X server and follow memory to the end of the
    # window, so "RSS at the chat list" is read at a fixed wall clock on both.
    res["mem"] = []
    while time.monotonic() < deadline and proc.poll() is None:
        t = time.monotonic() - t0
        rss = 0
        try:
            with open("/proc/%d/status" % proc.pid) as fh:
                for l in fh:
                    if l.startswith("VmRSS:"):
                        rss = int(l.split()[1])
        except Exception:
            break
        res["mem"].append([round(t, 1), rss])
        time.sleep(2)

    _, _, raw = sample_root(display)
    if raw:
        open("%s/shot-%s-end.xwd" % (TMP, tag), "wb").write(raw)

    try:
        with open("/proc/%d/status" % proc.pid) as fh:
            for l in fh:
                if l.startswith("VmRSS:"):
                    res["rss_kb"] = int(l.split()[1])
                if l.startswith("VmHWM:"):
                    res["hwm_kb"] = int(l.split()[1])
    except Exception as e:
        res["rss_error"] = str(e)
    try:
        res["smaps_pss_kb"] = int(subprocess.run(
            ["sh", "-c", "awk '/^Pss:/{s+=$2} END{print s}' /proc/%d/smaps" % proc.pid],
            capture_output=True, text=True).stdout.strip() or 0)
    except Exception as e:
        res["pss_error"] = str(e)

    proc.terminate()
    time.sleep(1)
    proc.kill()
    proc.wait()
    log.close()
    # The launcher ignores SIGTERM and an orphan keeps the account busy.
    subprocess.run(["pkill", "-9", "-f", "^" + launcher + " "], check=False)
    time.sleep(2)
    return res


MARKER_ORDER = ["vm_created", "app_created", "window_mapped", "app_oncreate",
                "dialogs", "activity", "first_frame"]


def summarise(paths):
    runs = []
    for p in paths:
        with open(p) as fh:
            runs += json.load(fh)
    print("%-16s %-22s %-22s %s" % ("marker", "hotspot mean [min..max]",
                                    "image mean [min..max]", "delta"))
    for m in MARKER_ORDER + ["rss_kb", "smaps_pss_kb"]:
        cells, vals = [], {}
        for backend in ("hotspot", "image"):
            xs = [r["marks"].get(m) if m in MARKER_ORDER else r.get(m)
                  for r in runs if r["backend"] == backend]
            xs = [x for x in xs if x is not None]
            if not xs:
                cells.append("%-22s" % "-")
                continue
            vals[backend] = sum(xs) / len(xs)
            fmt = "%.2f [%.2f..%.2f]" if m in MARKER_ORDER else "%.0f [%.0f..%.0f]"
            cells.append("%-22s" % (fmt % (vals[backend], min(xs), max(xs))))
        d = ("%+.2f" % (vals["image"] - vals["hotspot"])) if len(vals) == 2 else ""
        print("%-16s %s %s %s" % (m, cells[0], cells[1], d))
    print("n = %d hotspot, %d image" %
          (sum(1 for r in runs if r["backend"] == "hotspot"),
           sum(1 for r in runs if r["backend"] == "image")))


def main():
    if sys.argv[1] == "--summary":
        return summarise(sys.argv[2:])
    display, rounds, seconds, data_dir = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
    out = []
    for i in range(rounds):
        for backend in ("hotspot", "image"):
            r = run_once(backend, display, seconds, data_dir)
            r["round"] = i
            out.append(r)
            print(json.dumps({k: v for k, v in r.items() if k != "frames"}), flush=True)
            with open(TMP + "/startup-results.json", "w") as fh:
                json.dump(out, fh, indent=1)


if __name__ == "__main__":
    main()
