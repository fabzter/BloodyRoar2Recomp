#!/usr/bin/env bash
# build-macos.sh — local macOS (arm64) build for BloodyRoar2Recomp.
#
# Keeps the working tree upstream-friendly:
#   - The psxrecomp submodule stays UNTOUCHED (no local commits).
#   - Our macOS fixes live in scripts/macos/*.patch and are re-applied to the
#     submodule working tree after every pull; `git checkout` in the submodule
#     resets them first so pulls never conflict.
#   - Everything else (generated/, build dirs) is gitignored, so `git pull`
#     stays clean without stashing.
#
# Usage:
#   scripts/macos/build-macos.sh                # default build (setup-host OR
#                                               #   full game C once generated/)
#   scripts/macos/build-macos.sh --full         # force universal (EU+USA+JP)
#   scripts/macos/build-macos.sh --pull         # pull upstream first
#   scripts/macos/build-macos.sh --regen-bios   # regenerate OpenBIOS C
#   scripts/macos/build-macos.sh --clean        # wipe build dirs
#
# One-time prep (already done if build-recompiler/ exists):
#   git submodule update --init --recursive
#   psxrecomp/tools/ci/build_emitters.sh
#   (cd psxrecomp && PSXRECOMP_BIOS_BUILD=../build-recompiler \
#      tools/regen_bios.sh --config bios/OpenBIOS.toml)
#
# Full game binary requires YOUR legally owned disc images under disc/:
#   python3 psxrecomp/psxrecomp_cli.py generate --config game.toml \
#     --project-root . --disc "disc/<EU>.cue"
#   (repeat for game_us.toml / game_japan.toml as desired, then --full)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="${BR2_BUILD_DIR:-build-macos}"
EMITTER_BUILD="build-recompiler"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

PULL=0; FULL=0; USA=0; REGEN_BIOS=0; CLEAN=0; VENDOR=1; PORTABLE=0; OFFLINE=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --full) FULL=1 ;;
    --usa) USA=1 ;;               # USA region (game_us.toml / SCUS-94424)
    --regen-bios) REGEN_BIOS=1 ;;
    --clean) CLEAN=1 ;;
    --system-deps) VENDOR=0 ;;   # prefer Homebrew SDL3 over the pinned fetch
    --portable) PORTABLE=1 ;;    # brew-free binary: no freetype/harfbuzz either
    --offline) OFFLINE=1 ;;      # never download (vendored third_party archives)
    *) echo "unknown flag: $arg (use --pull|--full|--usa|--regen-bios|--clean|--system-deps|--portable|--offline)" >&2; exit 2 ;;
  esac
done

# --- 1. upstream sync (optional) ---------------------------------------------
if [[ $PULL -eq 1 ]]; then
  echo "==> git fetch + rebase onto origin/master"
  # Drop the applied submodule patch first: it makes psxrecomp "dirty", which
  # blocks both rebase and submodule update. It is re-applied below.
  git -C psxrecomp checkout -- . 2>/dev/null || true
  git fetch origin
  # autostash: uncommitted overlay edits are stashed, the branch is rebased,
  # and the edits are restored afterwards — no need to commit before pulling.
  git -c rebase.autoStash=true rebase origin/master
  echo "==> git submodule update (framework pins move with the repo)"
  git submodule update --init --recursive
fi

# --- 2. reset submodule working tree, then re-apply local macOS patches ------
# git submodule update (above) may leave our patch applied; reset so the
# patch applies cleanly against whatever revision the repo pins. The patches
# are in the GAME repo (not the submodule), so they survive the reset.
echo "==> applying local macOS patches to psxrecomp submodule"
git -C psxrecomp checkout -- . 2>/dev/null || true
git -C psxrecomp submodule update --init --recursive
for patch in scripts/macos/*.patch; do
  [[ -e "$patch" ]] || { echo "no patches found in scripts/macos/" >&2; exit 1; }
  echo "    $(basename "$patch")"
  if ! git -C psxrecomp apply --check "$ROOT/$patch" 2>/dev/null; then
    if git -C psxrecomp apply --check --reverse "$ROOT/$patch" 2>/dev/null; then
      echo "    already applied — skipping"
      continue
    fi
    echo "ERROR: patch $patch no longer applies — upstream changed the code." >&2
    echo "Re-create it with: git -C psxrecomp diff > scripts/macos/$(basename "$patch")" >&2
    exit 1
  fi
  git -C psxrecomp apply "$ROOT/$patch"
done

# --- 3. emitters (psxrecomp-game / psxrecomp-bios) ---------------------------
if [[ ! -x "$EMITTER_BUILD/psxrecomp-game" || ! -x "$EMITTER_BUILD/psxrecomp-bios" ]]; then
  echo "==> building recompiler emitters (first time only)"
  bash psxrecomp/tools/ci/build_emitters.sh --jobs "$JOBS"
fi

# --- 4. OpenBIOS generated C (bundled, MIT — no dump needed) -----------------
if [[ $REGEN_BIOS -eq 1 || ! -f psxrecomp/generated/OpenBIOS_full.c ]]; then
  echo "==> regenerating OpenBIOS C (requires emitters)"
  (cd psxrecomp && PSXRECOMP_BIOS_BUILD=../build-recompiler \
     bash tools/regen_bios.sh --config bios/OpenBIOS.toml)
fi

# --- 4b. guard: controller config that silently disables rumble --------------
# A digital seat is emulated as an SCPH-1080, which has no config-mode handshake
# and therefore cannot receive rumble. Two independent switches cause it, and
# the persisted one wins: [controller] in game*.toml, and p1_mode/p2_mode in the
# settings.toml next to the exe.
python3 - "$BUILD_DIR" "$([[ $USA -eq 1 ]] && echo game_us.toml || echo game.toml)" <<'GUARD_EOF'
import re, sys
from pathlib import Path

build_dir = Path(sys.argv[1])
cfg = sys.argv[2]
problems = []

f = Path(cfg)
if f.exists():
    text = f.read_text(errors="replace")
    block = re.search(r"^\[controller\](.*?)(?=^\[|\Z)", text, re.S | re.M)
    if block:
        body = block.group(1)
        mode = re.search(r'^\s*default_mode\s*=\s*"([^"]+)"', body, re.M)
        lock = re.search(r"^\s*lock_mode\s*=\s*(true|false)", body, re.M)
        if mode and mode.group(1) == "digital" and lock and lock.group(1) == "true":
            problems.append(cfg + ": [controller] default_mode=digital + lock_mode=true")

settings = build_dir / "settings.toml"
if settings.exists():
    s = settings.read_text(errors="replace")
    for key in ("p1_mode", "p2_mode"):
        m = re.search(r'^\s*' + key + r'\s*=\s*"([^"]+)"', s, re.M)
        if m and m.group(1) == "digital":
            problems.append(str(settings) + ": " + key + "=digital (overrides game*.toml)")

if problems:
    print("WARNING: rumble is disabled by controller configuration:", file=sys.stderr)
    for prob in problems:
        print("  - " + prob, file=sys.stderr)
    print("  A digital seat has no DualShock config handshake, so the game cannot", file=sys.stderr)
    print("  send motor values. Use default_mode=\"analog\" + lock_mode=false, and", file=sys.stderr)
    print("  set p1_mode/p2_mode=analog in the staged settings.toml.", file=sys.stderr)
GUARD_EOF

# --- 5. configure + build ----------------------------------------------------
CMAKE_ARGS=(-S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release)
TARGET="psx-runtime"
# Dependency provenance. The framework resolves every URL dependency in three
# tiers (pre-extracted tree -> vendored third_party archive -> upstream URL,
# all SHA256-pinned in psxrecomp/third_party/deps.manifest), so "CMake
# downloads the dependencies" is already the supported model — SDL3, zlib,
# libchdr and libjuice all have pinned fetch paths.
#
# What the fetches buy us: a Homebrew upgrade (or removal) cannot break the
# build, and a statically built SDL3 also removes the brew dylib from the
# BINARY's runtime dependencies. Without this, a `brew upgrade sdl3` between
# builds invalidates cached include/lib paths (seen with harfbuzz 14.4.0 ->
# 14.6.0).
if [[ $VENDOR -eq 1 ]]; then
  # Force the pinned FetchContent path even though brew ships SDL3: the
  # framework then builds SDL3 3.4.10 static and links it in.
  CMAKE_ARGS+=(-DCMAKE_DISABLE_FIND_PACKAGE_SDL3=ON -DPSX_SDL3_FETCH=ON)
else
  # Explicit OFF: these are cache vars, so leaving them out would silently
  # keep a previous --vendor run's value.
  CMAKE_ARGS+=(-DCMAKE_DISABLE_FIND_PACKAGE_SDL3=OFF)
  echo "==> using system deps (Homebrew SDL3 preferred)"
fi
if [[ $PORTABLE -eq 1 ]]; then
  # Color-emoji providers are optional upstream (outline glyphs when absent).
  # Skipping them removes libfreetype/libharfbuzz from the binary's deps so the
  # result runs on a clean Mac with no Homebrew packages at all.
  CMAKE_ARGS+=(-DCMAKE_DISABLE_FIND_PACKAGE_Freetype=ON -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON)
  echo "==> portable mode: freetype/harfbuzz disabled (emoji render as outlines)"
else
  CMAKE_ARGS+=(-DCMAKE_DISABLE_FIND_PACKAGE_Freetype=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=OFF)
fi
if [[ $OFFLINE -eq 1 ]]; then
  # Hard-fails instead of hanging on a download; needs psxrecomp/third_party
  # archives staged with psxrecomp/tools/ci/vendor_deps.sh.
  CMAKE_ARGS+=(-DPSX_DEPS_OFFLINE=ON)
  echo "==> offline mode: vendored archives only, no downloads"
else
  CMAKE_ARGS+=(-DPSX_DEPS_OFFLINE=OFF)
fi
if [[ $FULL -eq 1 ]]; then
  CMAKE_ARGS+=(-DBR2_BUILD_UNIVERSAL=ON)
  TARGET="psx-runtime-universal"
  if ! ls generated/ 2>/dev/null | grep -q .; then
    echo "WARNING: --full needs game C under generated/ (generate from your" >&2
    echo "         discs first — see header of this script). Building anyway." >&2
  fi
fi
if [[ $USA -eq 1 ]]; then
  if [[ $FULL -eq 1 ]]; then
    echo "error: --usa and --full are mutually exclusive (universal links all regions)" >&2
    exit 2
  fi
  TARGET="psx-runtime-us"
  EXE_NAME="BloodyRoar2_Recompiled_USA"
  if [[ ! -f generated/SCUS_944.24_dispatch.c ]]; then
    echo "error: USA game C is missing — generate it first:" >&2
    echo "  python3 psxrecomp/psxrecomp_cli.py generate --config game_us.toml \\" >&2
    echo "    --project-root . --disc \"disc/Bloody Roar II (USA).cue\"" >&2
    exit 1
  fi
fi

# Homebrew upgrades delete old Cellar/<pkg>/<version> paths, and pkg-config
# results are cached in CMakeCache.txt. A brew upgrade between builds then
# makes configure fail with "Imported target ... includes non-existent path".
# Drop cache lines whose Homebrew Cellar paths no longer exist; pkg-config
# entries re-resolve on the next configure while compiled objects survive.
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  python3 - "$BUILD_DIR/CMakeCache.txt" <<'PYEOF'
import re, sys
from pathlib import Path
cache = Path(sys.argv[1])
pat = re.compile(r"/opt/homebrew/Cellar/[^/;\s:]+/[^/;\s:]+")
text = cache.read_text(errors="replace")
lines = text.splitlines(keepends=True)
kept, dropped, poisoned = [], 0, False
for line in lines:
    if any(not Path(p).exists() for p in pat.findall(line)):
        dropped += 1
        poisoned = True
        continue
    kept.append(line)
if poisoned:
    kept = [l for l in kept if not l.startswith("prefix_result:")]
# A half-purged pkg-config cache is worse than either state: if the resolved
# <PREFIX>_INCLUDE_DIRS entry is gone but __pkg_config_checked_<PREFIX> remains,
# pkg_check_modules() skips re-resolution and the imported target ends up with
# NO include dirs (symptom: fatal error 'hb.h' file not found). Keep the two in
# lockstep — drop the checked flag whenever its resolved values are absent.
have = {l.split(":", 1)[0] for l in kept if ":" in l}
final = []
for line in kept:
    m = re.match(r"__pkg_config_checked_(\w+):", line)
    if m and (m.group(1) + "_INCLUDE_DIRS") not in have \
            and (m.group(1) + "_CFLAGS") not in have:
        dropped += 1
        continue
    final.append(line)
kept = final
if dropped:
    cache.write_text("".join(kept))
    print(f"    cache: dropped {dropped} stale Homebrew/pkg-config entr(y/ies)")
PYEOF
fi

echo "==> cmake configure"
cmake "${CMAKE_ARGS[@]}"

echo "==> building $TARGET"
cmake --build "$BUILD_DIR" --target "$TARGET" -j "$JOBS"

# --- 6. clean (optional) -----------------------------------------------------
if [[ $CLEAN -eq 1 ]]; then
  echo "==> removing build dirs"
  rm -rf "$BUILD_DIR" "$EMITTER_BUILD"
fi

echo "==> done: $BUILD_DIR/${EXE_NAME:-BloodyRoar2_Recompiled}"
echo "    binary: $BUILD_DIR/${EXE_NAME:-BloodyRoar2_Recompiled}"
echo "    (mods/ bios/ assets/ are staged next to it; disc goes in disc/)"
