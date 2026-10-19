# Recoil on macOS (Apple Silicon)

This port runs Recoil, and with it Beyond All Reason, natively on Apple Silicon
Macs with macOS 26 or later. Replays recorded on x86 Linux/Windows play back on
it without desyncs. Online play on the official servers is paused until an
organized test session on the BAR test server.

## How it renders

macOS has no usable OpenGL for Recoil: Apple's GL stops at 4.1 core and has no
compatibility profile. The engine therefore renders through Mesa:

```
engine GL calls -> Mesa EGL (surfaceless) -> Zink (GL on Vulkan) -> KosmicKrisp (Vulkan on Metal 4)
```

`rts/Rendering/GL/MacEGLBridge.cpp` creates the GL context offscreen in an EGL
pbuffer. On every swap it reads the frame back asynchronously through two PBOs
and presents it with SDL's Metal renderer. The SDL window itself has no GL
context.

MoltenVK cannot be used, because it lacks `robustness2.nullDescriptor`, which
Zink requires. KosmicKrisp needs Metal 4, which is where the macOS 26 minimum
comes from.

### KosmicKrisp gaps the engine works around

| Missing in KosmicKrisp | Workaround |
|---|---|
| `wideLines` (every line is 1 px) | The bridge redraws line primitives with the viewport shifted by whole pixels |
| `fillModeNonSolid` (`GL_LINE` polygon mode fills) | A runtime probe (`supportPolygonModeLine`); Lua `gl.PolygonMode` lines are emulated, and rect outlines are drawn as lines |
| Working geometry shaders (Zink exposes them, but they draw nothing) | Lua shaders with a geometry stage are refused, so BAR's widgets use their fallbacks without geometry shaders |
| GPU mipmap generation for S3TC | DDS textures that need generated mipmaps are uploaded decompressed |

Primitive restart on list primitives makes KosmicKrisp unroll every draw in a
compute pass. LuaVAO therefore enables it only for strips, fans and loops. This
was the biggest single performance gain (about 36 to 66 fps in a 150-unit
benchmark).

## Mesa

`installer/Mac/make-mesa.sh` builds EGL, Zink and KosmicKrisp from a pinned
Mesa (26.3.0-rc1). The Zink vertex input fix (mesa!45132), the KosmicKrisp
double init fix (e4174f891a8c) and renderpass tracking for KosmicKrisp
(95c504fa) are upstream, and KosmicKrisp now records one command buffer per
VkCommandBuffer, which replaces our command allocator trim. One patch is left:

- `0001` fixes `glEnd()` for line loops that continue after a vertex buffer
  wrap on drivers without native line loops (Zink): the strip took the first
  vertex of the next primitive, so consecutive `GL_LINE_LOOP` blocks got stray
  lines between them. Submitted upstream as mesa!45329.

KosmicKrisp from 26.3 on emulates GL's last-vertex provoking convention by
unrolling every draw with flat varyings. The engine asks for first-vertex
provoking on KosmicKrisp (tomjn, upstream #3532), so Mesa and engine have to be
updated together.

## Building and releasing

- Dependencies come from Homebrew; CI installs them in
  `.github/workflows/engine-build-macos.yml`. The compiler is Homebrew GCC,
  like the upstream Linux/Windows builds.
- `installer/Mac/make-mesa.sh` builds the Mesa prefix.
- `installer/Mac/make-engine.sh` assembles `Engine.app`, bundles the dylibs
  (`bundle-dylibs.py`), signs it and packs `recoil_<version>_arm64-macos.7z`,
  the macOS counterpart of the Linux and Windows engine archives.
- CI builds every `macos-port-*` push. A tag `<engine version>-mac.<n>` (e.g.
  `2026.09.01-mac.1`) builds, notarizes and publishes a release in the fork.

Games use this engine like the upstream archives. For BAR, the macOS launcher
is built from a BYAR-Chobby fork (github.com/leonseemann/BYAR-Chobby) on top of
spring-launcher's `mac-support` branch, the same way BAR builds its Linux and
Windows launchers.

## Branches

The port is one linear patch series on top of an engine tag, without merge
commits:

- `macos-port-2026.07.04` and `macos-port-2026.09.01`: the series on the engine
  versions BAR currently uses (Alpha and Engine Test). 07.04 also carries a few
  backports that 2026.09.01 already contains.
- `macos-port`: the same series on upstream master.

A fix lands as a commit on one branch and is cherry-picked to the other two.
Commits by Tom J Nowell come from his integration branch
(beyond-all-reason/RecoilEngine#3271) and are kept unchanged. The commits
"macOS: use the SDL hardware cursor", "macOS: read the hardware MAC address via
IOKit", "LuaVAO: enable primitive restart only for connected primitives" and
"Upload per-frame LOS and radar textures through PBOs" are also open as
upstream PRs (#3492, #3493, #3494, #3516).

## Verification

### Sync testing

Recoil writes a checksum of the synced game state into every demo. During
playback the engine recomputes it and logs `[DESYNC WARNING] checksum ... from
demo ... does not match our checksum` on a mismatch (`rts/Net/NetCommands.cpp`).
A replay that runs to the end without that line was simulated bit-identically
to the machine that recorded it.

Method:
- Each replay runs in its own write dir with `--isolation`, so no local
  settings or widgets interfere: `run_demo.sh <engine> <demo.sdfz> <run-name>`.
- After the run, `grep -c "DESYNC WARNING" infolog.txt` must be 0.
- Negative control: the 2026.09.01 build playing a 2026.07.04 demo logs 486
  desync warnings, so the check does catch a real mismatch.

Results:

| Engine | Reference replays | Runs | Desync warnings |
|---|---|---|---|
| 2026.07.04, GCC | 5 online games (4 Isidis Crack, 1 Rosetta) recorded on x86 Linux/Windows | 5 | 0 |
| 2026.07.04, Apple Clang | the Rosetta game | 1 | 0 |
| 2026.09.01, GCC | 2 BARb vs BARb games recorded with the official amd64-linux engine in Docker (Isidis Crack, Rosetta; the longer one about 155,000 frames) | 2 | 0 |
| 2026.09.01, GCC, with the symbol visibility fix (#45) | the same 2 BARb games | 2 | 0 |

The replays are short to medium games. They do not prove the absence of rare
desyncs, which is what an organized test session on the BAR test server is
for.

### Other checks

Lobby/game cycles, long games for memory growth, and a 150-unit and a 650-unit
benchmark.

## AI assistance

Following the project's AI usage policy, this section states how AI was used.
Most of the port's code, build tooling, CI and investigation was written with
Claude Code (Anthropic). The human contributor (Leon Seemann) set the goals,
made the decisions, reviewed the changes, and did all play testing on his Mac:
online games, the keyboard and display checks, and visual checks. Tom J Nowell's
commits are his own and were taken over unchanged.

What Claude Code did, by area:

- **Rendering bridge**: wrote MacEGLBridge (EGL/Zink context, async PBO
  readback, wide line emulation), the polygon mode and geometry shader
  workarounds, and the bundled Mesa lookup. Tested with the benchmarks above
  and screenshots.
- **Root causes in Mesa**: found and fixed the display-list text bug in Zink
  (patch 0001, upstreamed), found the KosmicKrisp descriptor and command
  allocator leaks (patches 0002, 0003) with heap snapshots, and profiled the
  render pass behaviour behind the Mesa pin.
- **Performance**: the LuaVAO primitive restart change, PBO uploads for
  LOS/radar, orphaning streamed font buffers, persistently mapped model
  uniforms and DDS decompression, each measured with the benchmark rig.
- **Platform and input**: CpuTopology, the IOKit MAC address, the hardware
  cursor, borderless fullscreen, dead keys, Command as Control, the F11/Pause
  aliases and turning off AutoFill. The human tested each one on his keyboard
  and displays.
- **Build and release**: the GCC build, the Mesa build script, engine
  packaging, notarization, CI caching and the release flow. Also the macOS port
  of spring-launcher and BAR's launcher build (separate repositories).
- **Verification tooling**: the replay sync rig (including the Docker x86
  reference) and the benchmark and lobby-cycle rigs.
- **Cleanup (2026-10-16)**: an audit of the whole port; three bug fixes (DDS
  BC4/5/7 decoded as DXT1, the HardwareCursor setting ignored at startup, stale
  wide line width); rewriting the history as this linear series; trimming the
  bridge setup, keyboard, CpuTopology and DDS code (about 100 lines); simpler
  build tooling (required `MESA_PREFIX`, a fixed minimum macOS, the engine
  version taken from the release tag instead of a `VERSION_OVERRIDE` option).
- **Outside contributions**: reviewed and tested the symbol visibility fix
  and the crash handler stack traces by yvessommer (fork PRs #44, #45),
  including the BARb sync replays above. Backported Mesa's Zink renderpass
  tracking for KosmicKrisp (patch 0004) after measuring about +3% fps.
  Tested with the benchmark, a CI-built engine and the keyboard aliases by
  hand.
- **Mesa 26.3 (2026-10-17)**: picked tomjn's first-vertex provoking change
  (#3532), moved the build to 26.3.0-rc1 and dropped all four patches. Same
  spring binary against 26.2.4 and 26.3: 150-unit benchmark 67.3/65.3 vs
  65.1/68.8 fps; 3-game lobby cycle in-game 44-48 vs 59 fps, peak GPU
  allocation 40 vs 11 GB; 650 vs 650 battle footprint ~17 GB (39 GB peak) vs
  ~9 GB. Display-list text test clean, screenshots identical.
- **Line loop stray lines (2026-10-17)**: traced the stray lines between
  `gl.BeginEnd(GL.LINE_LOOP)` blocks (upstream #3533 works around them in the
  engine) to Mesa's vbo module and wrote patch 0001. Tested with a standalone
  EGL program drawing 4000 loops on Zink over KosmicKrisp: 2-6 stray pixels at
  every vertex buffer wrap before, none after, pixel counts equal to llvmpipe.
