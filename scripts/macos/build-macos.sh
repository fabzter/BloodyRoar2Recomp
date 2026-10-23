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

PULL=0; FULL=0; REGEN_BIOS=0; CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --full) FULL=1 ;;
    --regen-bios) REGEN_BIOS=1 ;;
    --clean) CLEAN=1 ;;
    *) echo "unknown flag: $arg (use --pull|--full|--regen-bios|--clean)" >&2; exit 2 ;;
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

# --- 5. configure + build ----------------------------------------------------
CMAKE_ARGS=(-S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release)
TARGET="psx-runtime"
if [[ $FULL -eq 1 ]]; then
  CMAKE_ARGS+=(-DBR2_BUILD_UNIVERSAL=ON)
  TARGET="psx-runtime-universal"
  if ! ls generated/ 2>/dev/null | grep -q .; then
    echo "WARNING: --full needs game C under generated/ (generate from your" >&2
    echo "         discs first — see header of this script). Building anyway." >&2
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

echo "==> done: $BUILD_DIR/$(grep -o 'OUTPUT_NAME[^:]*' /dev/null 2>/dev/null || true)"
echo "    binary: $BUILD_DIR/BloodyRoar2_Recompiled"
echo "    (mods/ bios/ assets/ are staged next to it; disc goes in disc/)"
