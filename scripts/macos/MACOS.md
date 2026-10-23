# macOS build (local overlay)

Upstream (novapowers0/BloodyRoar2Recomp) ships Windows + Linux releases only.
This overlay adds a native **macOS arm64** build that survives upstream pulls.

## TL;DR

```bash
# one-time deps
xcode-select --install
brew install cmake ninja sdl3 python3 ccache

# build (also first-time: emitters + OpenBIOS C)
scripts/macos/build-macos.sh

# later, after upstream moved:
scripts/macos/build-macos.sh --pull

# run
./build-macos/BloodyRoar2_Recompiled
```

The first build is a **setup host** (launcher + Generate & rebuild wizard) —
no game C exists until you feed it a disc. The wizard handles everything from
there: pick your legally-owned `.cue`/`.bin` (Step 2) → **Generate & rebuild**
(Step 3) compiles game C from your disc and produces the playable binary.
OpenBIOS (MIT, bundled) is already linked — no retail BIOS dump needed.

For the universal EU+USA+JP exe: generate game C per region first, then
`scripts/macos/build-macos.sh --full`.

## How the overlay works

| Piece | Where | Why |
|---|---|---|
| `scripts/macos/build-macos.sh` | game repo (committed on `local/macos`) | one-command build; pulls, rebases, patches, builds |
| `scripts/macos/*.patch` | game repo (committed on `local/macos`) | macOS fixes for the `psxrecomp` submodule, applied to its **working tree** — never committed inside the submodule |
| `local/macos` branch | game repo | our overlay commits; `--pull` = `git fetch` + `rebase origin/master` |

The submodule working tree is dirty while built (patch applied). `build-macos.sh`
resets it (`git -C psxrecomp checkout -- .`) before re-applying, so upstream
submodule bumps apply cleanly. If a patch stops applying, the script fails
loudly with instructions to regenerate it:

```bash
# regenerate after a conflict (patch already applied to working tree):
git -C psxrecomp diff > scripts/macos/<name>.patch
```

## Patches

### `psxrecomp-macos-system-clang.patch`
The wizard's toolchain health check (`toolchain_bin_compiler_works` in
`psxrecomp/host/psxrecomp_codegen_host.c`) demanded `bin/clang` + `bin/ld.lld`
inside the downloaded `cmake-clang-v1` pack — the **Linux** pack layout. The
macos-universal pack is `kind: cmake-ninja-system-clang`: it ships only
cmake/ninja/ccache and its own `env.sh` builds with the **system** Xcode CLT
clang. The old check quarantined every healthy macOS pack as `.broken` and
re-downloaded it in a loop. With the patch, a pack without clang validates via
`/usr/bin/clang` (and skips `-fuse-ld=lld` for it).

## Build matrix facts (2026-10-10)

- Compiler: Apple clang (`/usr/bin/cc`), arm64.
- SDL: **system SDL3 3.4.16** via Homebrew (`brew install sdl3`) — the
  framework needs ≥3.4; no fetch needed.
- Renderer: **OpenGL** (default). Vulkan builds as an inert stub — no Vulkan
  SDK headers/glslc on macOS; `SDL_Vulkan_LoadLibrary` would fail and the
  runtime falls back cleanly. `--renderer vulkan` is refused with a message.
- BIOS: bundled **OpenBIOS** generated locally (MIT; `tools/regen_bios.sh
  --config bios/OpenBIOS.toml`).
- Netplay: linked (`PSX_HAS_RECOMP_NET`) via the nested recomp-net submodule.
- Toolchain pack: `~/.local/share/retcomm/toolchains/cmake-clang-v1/1.0.14`
  (cmake 3.31.12 / ninja / ccache + python 3.12). Downloaded once by the
  wizard; accepted after the system-clang patch above.

## Files produced

- `build-macos/BloodyRoar2_Recompiled` — launcher/game exe
- `build-macos/mods/bundled/` — curated mod catalog (staged by the build)
- `build-macos/bios/openbios.bin` — bundled BIOS image
- `build-recompiler/psxrecomp-{game,bios}` — recompiler emitters
- `psxrecomp/generated/OpenBIOS_{full,dispatch}.c` — generated BIOS C
- `generated/` — game C (only after Generate; gitignored)

## Runtime notes

- The exe anchors all sidecar files (game.toml, disc.cfg, settings.toml,
  saves/) to **its own directory** — launch it from anywhere; put discs under
  `disc/` in the repo root (gitignored).
- Headless sanity check: `./BloodyRoar2_Recompiled --headless` (exits cleanly
  with a "disc needed" message).
- `--verify-disc <image>` prints the disc verdict/serial/region without GUI.

## Troubleshooting

- **Wizard wants to re-download the toolchain** — check
  `~/.local/share/retcomm/toolchains/cmake-clang-v1/` for `.broken` dirs; if
  present, the patch isn't applied (rebuild via `build-macos.sh`).
- **`Imported target ... includes non-existent path` or `hb.h` not found** —
  a `brew upgrade` moved a Cellar path the CMake cache still referenced.
  `build-macos.sh` now sanitizes the cache automatically (drops cache lines
  whose Homebrew Cellar paths are gone and forces pkg-config to re-resolve).
  If you hit it in a pre-existing tree: re-run the script, it self-heals.
- **`cannot rebase: You have unstaged changes`** — use `--pull`, which resets
  the submodule patch and autostashes overlay edits before rebasing. A manual
  `git pull` on `local/macos` needs a clean tree.
- **`SDL3 was found but does not compile`** — Homebrew SDL3 + a portable pack
  on CMAKE_PREFIX_PATH clash; don't set CMAKE_PREFIX_PATH to the pack, the
  script doesn't.
- **No game C / "setup host" in configure log** — expected before first
  Generate; not an error.
