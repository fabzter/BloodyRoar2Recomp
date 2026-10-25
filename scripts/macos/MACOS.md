# macOS build (local overlay)

Upstream (novapowers0/BloodyRoar2Recomp) ships Windows + Linux releases only.
This overlay adds a native **macOS arm64** build that survives upstream pulls.

## TL;DR

```bash
# one-time deps (compiler only — libraries are fetched by CMake)
xcode-select --install
brew install cmake ninja python3

# build (also first-time: emitters + OpenBIOS C)
scripts/macos/build-macos.sh

# brew-free binary (runs on any Mac; emoji render as outlines)
scripts/macos/build-macos.sh --portable

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

## Dependencies — what CMake downloads vs. what it borrows

Every URL dependency resolves through the framework's three-tier scheme
(`psxrecomp/cmake/psx_dependency_archive.cmake`): a pre-extracted tree
(`FETCHCONTENT_SOURCE_DIR_*`) → a vendored archive in `psxrecomp/third_party/`
→ the upstream URL. All pins live in `psxrecomp/third_party/deps.manifest`
with SHA256 hashes, so a download is verified exactly like a vendored copy.

| Dep | Source | Notes |
|---|---|---|
| **SDL3 3.4.10** | **fetched + built static** (default) | `--system-deps` prefers Homebrew instead. Static means the binary has no `libSDL3` runtime dep. |
| zlib 1.3.1 | system (macOS SDK) | fetched only if absent (`PSX_ZLIB_FETCH=ON` default) |
| libchdr | fetched (pinned) | CHD disc support |
| libjuice | fetched (pinned, via recomp-net) | netplay NAT traversal |
| FreeType / HarfBuzz | **optional, system** | color emoji only; missing ⇒ outline glyphs, build still succeeds. `--portable` skips them entirely. |
| CMake / Ninja / clang | host | also satisfiable by the retcomm `cmake-clang-v1` pack (cmake+ninja) + Xcode CLT clang |

Flags:

| Flag | Effect |
|---|---|
| *(default)* | pinned static SDL3 + color emoji if Homebrew has freetype/harfbuzz |
| `--system-deps` | prefer Homebrew SDL3 (faster incremental builds, but the binary then needs `brew install sdl3`) |
| `--portable` | disable freetype/harfbuzz too ⇒ **zero non-Apple dylibs** (`otool -L` clean) |
| `--offline` | `PSX_DEPS_OFFLINE=ON`: never download, fail fast unless archives are vendored (`psxrecomp/tools/ci/vendor_deps.sh`) |

Verify what a binary needs:

```bash
otool -L build-macos/BloodyRoar2_Recompiled | grep -vE '/usr/lib|/System'
#  default   -> freetype + harfbuzz (brew)
#  --portable-> (nothing)
```

### Why SDL3 is fetched by default

Homebrew upgrades move Cellar paths; a cached `SDL3_DIR` /
`PkgConfig::HARFBUZZ` include dir then points into a deleted directory and
configure fails (`Imported target ... includes non-existent path`, or a bare
`hb.h: file not found`). Pinning SDL3 to the FetchContent path makes the build
immune to that class of breakage, and static linking removes the dependency
from the *binary* too. The cache sanitizer (below) still covers the optional
deps.

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

## Packaging a double-clickable .app

```bash
scripts/macos/package-app.sh --usa     # -> dist/Bloody Roar II Recompiled (USA).app
scripts/macos/package-app.sh           # EU, or USA automatically if that build exists
```

Why bundle at all: a bare Mach-O inherits its TCC identity from the terminal that
launched it, so **Input Monitoring** (needed for HID input and for rumble output
reports) must be granted to that terminal, per terminal, forever. A bundle with
its own `CFBundleIdentifier` is granted once, for the game.

Layout — two lookup roots, and both matter:

- the **runtime** anchors every sidecar (game `*.toml`, `bios/`, `mods/`,
  `assets/`, settings, saves) to the executable's own directory, so the payload
  lives in `Contents/MacOS/`;
- the **launcher** resolves its own art and fonts through `SDL_GetBasePath()`,
  which is bundle-aware on macOS and returns `Contents/Resources/`.

So `Contents/Resources/assets` is created as a **symlink** to `../MacOS/assets`
— one payload, both roots. Without it the game still runs, but the launcher
silently falls back to a monospace font and draws no controller artwork, which
looks like a broken build. User state (`settings.toml`, `disc.cfg`, saves) is
deliberately **not** copied — the bundle starts clean.

Signing: the executable is signed ad-hoc; the *container* cannot be sealed
because codesign refuses the mod catalog's dotted package directories
(`br2.enhancement.turbo` etc. look like sub-bundles). The app still launches
(verified). Distributing it to another machine would need a Developer ID
signature plus notarisation.

## Region targets

`scripts/macos/build-macos.sh --usa` builds the USA target
(`psx-runtime-us` → `build-macos/BloodyRoar2_Recompiled_USA`) from game C you
generate with `game_us.toml`:

```bash
python3 psxrecomp/psxrecomp_cli.py generate --config game_us.toml \
  --project-root . --disc "disc/Bloody Roar II (USA).cue"
scripts/macos/build-macos.sh --usa
```

Each region owns its own setup-wizard config (`codegen_setup.c` for EU,
`codegen_setup_us.c` for USA). Before that split, the USA exe carried the
EU-pinned wizard: the sources probe looked for `generated/SLES_017.22_dispatch.c`,
so first-run setup was forced on every launch and then rejected the US disc as
"wrong dump".

## Rumble (DS4-compatible pads over Bluetooth)

Two separate problems, both fixed:

1. **The pad was a digital SCPH-1080.** `game_us.toml` had
   `[controller] default_mode = "digital"` + `lock_mode = true`, and a plain
   digital pad has no config-mode protocol — rumble is only carried by the
   DualShock `0x43`/`0x4D` handshake. Now `analog` with `lock_mode = false`.

2. **SDL's effects write is ignored by these pads.** SDL/hidapi passes the
   Bluetooth effects report id *separately* from the payload; the pad accepts
   that write (`IOReturn 0`) and does nothing. The convention it obeys
   (verified variant by variant — F rumbles, G and H do not) is report id `0`
   with the id inside a 78-byte buffer:
   `frame[0]=0x11, frame[1]=0xC0, frame[3]=0x03, frame[6]=small,
   frame[7]=large`, CRC32 over `0xA2` + `frame[0..73]` at `frame[74..77]`.
   Implemented in `src/platform/psx_macos_hid_rumble.cpp` (title-owned, linked
   on Apple targets by `br2_macos_hid_rumble()` in `CMakeLists.txt`).

The runtime forwarder also holds effects for 250 ms and re-arms them while
motors are active (BR2 pulses `small=1,0,1,0` at 60 Hz, which used to produce
~16 ms blips), with an explicit `rumble_stop_pending` flag so a stop frame is
always sent. Trace with `PSX_RUMBLE_TRACE=1`: expect
`rumble-hw: … via=hid` on a hit and `… via=hid (stop)` after it.

**Writes must not run on the frame loop.** `IOHIDDeviceSetReport` is a
synchronous Bluetooth write: measured 5–20 ms per call, peaking at 78–142 ms,
and at 25–31 writes/s the game lost most of its frame budget whenever the pad
was vibrating (30–90 ms frames). All writes now happen on a dedicated writer
thread fed by a one-slot mailbox, and rapid pulses are coalesced to one write
per 100 ms with start/stop still sent immediately. `PSX_RUMBLE_TRACE=1` also
prints the writer's cost per second:

```
psxrecomp hid-rumble: 8 writes/s, avg 6.2 ms, max 41.0 ms (writer thread)
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
