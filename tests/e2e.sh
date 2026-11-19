#!/usr/bin/env bash
# aequalyn-install --test: scripted end-to-end self-test of the installer UI.
#
# Runs the REAL Installer.qml on the live session, driven by harness.qml
# at the repo root (a same-directory component, like shell.qml uses it): a window pops up, the wizard parks
# on Review, Install is pressed through the button's own handler, the apply
# FAILS, the Retry runs and SUCCEEDS. At every phase the title-bar Close ✕
# corner is screenshotted and the state machine asserted, so the ✕ gating
# (blocked mid-install, re-activated on Failure and Success) is verified end
# to end and pixel by pixel. Nothing touches a disk: config, log, geometry
# and the shots all land in the sandbox dir, AEQUALYN_E2E_SANDBOX or
# /tmp/aequalyn-installer-e2e by default. Needs a graphical session plus
# hyprctl, grim, magick, jq and python3.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
S="${AEQUALYN_E2E_SANDBOX:-/tmp/aequalyn-installer-e2e}"
export AEQUALYN_E2E_DIR="$SELF_DIR"
export AEQUALYN_E2E_SANDBOX="$S"
mkdir -p "$S"

rm -f "$S/qs.log" "$S"/raw-*.png "$S"/shot-*.png "$S"/crop-*.png "$S"/zoom-*.png \
      "$S/apply-count" "$S/apply.log" "$S/install.toml" "$S/geometry.conf"

stdbuf -oL qs -n -p "$ROOT/harness.qml" > "$S/qs.log" 2>&1 &
QPID=$!
echo "[driver] qs pid $QPID, window should appear on screen now"
sleep 1.2
found=$(hyprctl clients -j | jq -r --argjson pid "$QPID" \
    '.[] | select(.pid == $pid) | "at \(.at[0]),\(.at[1]) size \(.size[0])x\(.size[1])"' | head -n1)
if [ -n "$found" ]; then echo "[driver] window check: $found"; else echo "[driver] WARNING: no window for pid $QPID yet"; fi

snap() {
    local tag="$1" geom origin WX WY WW WH OX OY
    # strictly by pid: never grab some other installer window by title
    geom=$(hyprctl clients -j | jq -r --argjson pid "$QPID" \
        '.[] | select(.pid == $pid)
         | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -n1)
    if [ -z "$geom" ]; then
        echo "[driver] snap $tag: window not found, skipping"
        return
    fi
    # layout origin: grim's full-layout image is anchored at the top-left of
    # the outputs' bounding box, not at the global 0,0
    origin=$(hyprctl monitors -j | jq -r '"\(([.[].x] | min) // 0) \(([.[].y] | min) // 0)"')
    read -r WX WY WW WH <<< "$geom"
    read -r OX OY <<< "$origin"
    grim "$S/raw-$tag.png" || { echo "[driver] snap $tag: grim failed"; return; }
    python3 - "$WX" "$WY" "$WW" "$WH" "$OX" "$OY" "$S" "$tag" <<'PY'
import subprocess, sys
wx, wy, w, h, ox, oy = map(int, sys.argv[1:7])
S, tag = sys.argv[7:9]
s = max(0.7, min(3.0, min(w / 1336, h / 728)))
def magick(*args):
    subprocess.run(["magick", *args], check=True)
lx, ly = wx - ox, wy - oy          # window position inside the grabbed image
# full installer window
magick(f"{S}/raw-{tag}.png", "-crop", f"{w}x{h}+{lx}+{ly}", "+repage", f"{S}/shot-{tag}.png")
# the Close ✕ corner: the box is 30x30 with an 18px right margin, vertically
# centered in the 64px titlebar, everything scaled by s
x0 = round(lx + w - 56 * s); y0 = round(ly + 13 * s)
cw = round(46 * s); ch = round(38 * s)
magick(f"{S}/shot-{tag}.png", "-crop", f"{cw}x{ch}+{x0 - lx}+{y0 - ly}", "+repage", f"{S}/crop-{tag}.png")
magick(f"{S}/crop-{tag}.png", "-filter", "point", "-resize", "600%", f"{S}/zoom-{tag}.png")
print(f"[driver] snap {tag}: window {wx},{wy} {w}x{h} layout origin {ox},{oy} scale {s:.3f} corner {cw}x{ch}")
PY
}

# stream markers, snapshot each phase; tail exits once qs does
tail -n +1 -f --pid="$QPID" "$S/qs.log" | while IFS= read -r line; do
    case "$line" in
        *"[phase]"*|*"[assert]"*|*"[result]"*) echo "$line" ;;
    esac
    case "$line" in
        *"[phase] pre-install"*)     snap pre ;;
        *"[phase] install-pressed"*) snap pressed ;;
        *"[phase] mid-apply"*)       snap mid ;;
        *"[phase] success"*)         snap success ;;
        *"[phase] retry-pressed"*)   snap retry ;;
        *"[phase] failure"*)         snap failure ;;
        *"[phase] done"*)           break ;;
    esac
done
wait "$QPID" 2>/dev/null
echo "[driver] qs exited"

echo
echo "[driver] --- corner crops: pixel stddev (the ✕ glyph is in frame if > 0) ---"
for f in "$S"/crop-*.png; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f"): $(magick "$f" -format '%[fx:standard_deviation*255]' info:)"
done

echo
echo "[driver] --- RMSE between ✕ corners (0 = identical rendering) ---"
for pair in "pre mid" "pre failure" "pre success" "mid failure" "mid success" "retry mid" "retry success"; do
    set -- $pair
    if [ -f "$S/crop-$1.png" ] && [ -f "$S/crop-$2.png" ]; then
        echo "  crop-$1 vs crop-$2: $(compare -metric RMSE "$S/crop-$1.png" "$S/crop-$2.png" NULL: 2>&1)"
    fi
done

echo
grep '\[assert\]' "$S/qs.log" | sed 's/^/[driver] /'
echo
echo "[driver] result: $(grep '\[result\]' "$S/qs.log" | tail -n1)"
grep -q '\[result\] ALL PASS' "$S/qs.log"
