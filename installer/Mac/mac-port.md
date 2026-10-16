# Recoil on macOS (Apple Silicon)

This port runs Recoil, and with it Beyond All Reason, natively on Apple Silicon
Macs with macOS 26 or later. It is used for online games on the official BAR
servers. Replays recorded on x86 Linux/Windows play back on it without desyncs.

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
Mesa (26.2.4) with these patches:

| Patch | Status |
|---|---|
| 0001 Zink: refetch the pipeline on a vertex input change (fixes vanishing display-list text and purple stripes) | Upstream as mesa!45132, contained in 26.2.5 |
| 0002 KosmicKrisp: fix the double init in the Metal bridge (leaked a descriptor array per render pass) | Backport of upstream e4174f891a8c (Mesa 26.3) |
| 0003 KosmicKrisp: drop command allocators that outgrew their use (30-70 GB footprint after a few games) | Ours, not upstream |

Mesa 26.3 / main is currently slower on this workload, because KosmicKrisp ends
the render encoder for every compute dispatch and unrolls draws for flat
shading. That is why the version is pinned.

## Building and releasing

- Dependencies come from Homebrew; CI installs them in
  `.github/workflows/bar-mac-app.yml`. The compiler is Homebrew GCC,
  like the upstream Linux/Windows builds.
- `installer/Mac/make-mesa.sh` builds the Mesa prefix.
- `installer/Mac/make-bar-engine.sh` assembles `Engine.app`, bundles the dylibs
  (`bundle-dylibs.py`), signs it and packs `recoil_<version>_arm64-macos.7z` in
  the layout BAR's launcher expects.
- CI builds every `macos-port-*` push. A `bar-mac-v*` tag builds, notarizes and
  publishes a release in the fork.

Players install the macOS build of the BAR launcher from
github.com/leonseemann/spring-launcher (branches `mac-support` and `bar-mac`).
The launcher downloads this engine from the fork's releases.

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

- Sync: x86 replays of online games played back on the Mac build with 0 sync
  errors, with both the Apple Clang and the GCC builds. For
  2026.09.01, for which no online replays existed, the reference was a BARb vs
  BARb game recorded with the official amd64-linux engine in Docker.
- Online play on the official servers, lobby/game cycles,
  long games for memory growth, and a 150-unit and a 650-unit benchmark.

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
  of the BAR launcher (separate repository).
- **Verification tooling**: the replay sync rig (including the Docker x86
  reference) and the benchmark and lobby-cycle rigs.
- **Cleanup (2026-10-16)**: an audit of the whole port; three bug fixes (DDS
  BC4/5/7 decoded as DXT1, the HardwareCursor setting ignored at startup, stale
  wide line width); rewriting the history as this linear series; trimming the
  bridge setup, keyboard, CpuTopology and DDS code (about 100 lines); simpler
  build tooling (required `MESA_PREFIX`, a fixed minimum macOS, the engine
  version taken from the release tag instead of a `VERSION_OVERRIDE` option).
  Tested with the benchmark, a CI-built engine and the keyboard aliases by
  hand.
