# DLSS 5 for Foundry Nuke - ACES fork

> **This is a fork of [KJzzzKJ/DLSS5-for-Nuke](https://github.com/KJzzzKJ/DLSS5-for-Nuke).**
>
> It adds an invertible ACES colour pipeline so the node can be used inside an
> ACES comp without shifting colour. Everything else is upstream's work.
> See **[docs/ACES.md](docs/ACES.md)** for the detail, or
> [What the fork changes](#what-the-fork-changes) for the short version.


[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Experimental-F59E0B.svg)](https://github.com/KJzzzKJ/DLSS5-for-Nuke/releases)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(x64)-0078D6.svg)](https://www.microsoft.com/windows)
[![Nuke Versions](https://img.shields.io/badge/Nuke-15.0%20%7C%2017.0-F9A01B.svg)](https://www.foundry.com/products/nuke)
[![Hardware](https://img.shields.io/badge/GPU-NVIDIA%20RTX-76B900.svg)](https://www.nvidia.com)

## What the fork changes

Upstream hands Nuke's pixels to the neural model unchanged. The DLSS models are
trained on display-referred Rec.709/sRGB frames in a nominal `0-1` range, and
Nuke's ACES working space is scene-linear with AP1 primaries and no upper bound,
so four mismatches land at once: wrong primaries, wrong transfer function, values
far past `1.0`, and negative components on saturated colour. Hue drifts, skin
desaturates, and highlights come back flat.

This fork wraps the neural pass in a colour transform and its exact inverse:

```
ACEScg -> exposure -> Rec.709 primaries -> gamut compress
       -> highlight roll-off -> sRGB curve -> [ DLSS ] -> inverse of all of it
```

Every stage has a closed-form inverse, so with the neural pass bypassed the round
trip is the identity. The node can only change the picture by as much as DLSS
changed it; the colour management contributes nothing of its own. That is checked
numerically on every commit, over a spread of real ACES values and every
combination of knobs:

```powershell
powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
```

No Nuke NDK, GPU or NVIDIA runtime needed to run it.

Summary of the changes:

- `src/AcesColor.h` - new, dependency-free colour pipeline (primaries matrices
  derived from chromaticities, ACES reference gamut compression, invertible
  highlight roll-off, sRGB / Rec.709 / gamma 2.2 / ACEScct transfer functions).
- `src/DLSS5Live.cpp` - an **ACES Color Management** knob group, and a rewritten
  pixel path that converts on the way in and inverts on the way out.
- `worker/DLSSWorker.cpp` - clears the NGX `IsHDR` flag when the node has already
  encoded to a display-referred signal. Wire-compatible with an upstream worker,
  so rebuilding it is optional.
- `tests/` - round-trip verification, a wire-format guard, and a compile check
  for the node against a mock DDImage.
- `install/install.bat` - rewritten so a Release ZIP installs with no compiler,
  and so it removes any previous install (upstream's included) without touching
  the NVIDIA runtime you supplied.
- `tools/build_and_install.bat` - one-step build and install from source.
- `installer/setup_stub.cpp` + `tools/make_installer_exe.ps1` - the one-click
  `Setup.exe`, so a user needs nothing but the download.

Colour management is **on by default**. Set **Enable Color Management** off to get
upstream behaviour back, bit for bit.

Experimental, unofficial native plug-in for using DLSS Neural Rendering in
Foundry Nuke. `DLSS5Live` supports still images and temporal sequences through
a native Nuke node and an isolated background worker process.

> **Experimental warning**
>
> This project uses observed, undocumented runtime behavior. It is not
> affiliated with, endorsed by, or supported by NVIDIA or Foundry. Compatibility
> can change with Nuke, GPU driver, and user-supplied runtime versions.

## What it does

`DLSS5Live` processes a Nuke image stream with neural reconstruction controls,
optional temporal history, and optional guide inputs. It is intended for
Windows systems with an NVIDIA RTX GPU.

Under the hood, `DLSS5Live` integrates a two-pass neural execution pipeline:
1. **Pass 1 (DLSS-NR / Feature 18)**: Evaluates neural reconstruction at native
   `1.0x` resolution into an intermediate linear `RGBA16F` texture, applying
   neural tuning and style controls.
2. **Pass 2 (DLSS-SR / Feature 1)**: When upscaling (> `1.0x`) is requested,
   evaluates AI Super Resolution on Tensor Cores to upscale the intermediate
   texture to the target resolution. When `1.0x (DLAA)` is chosen, this pass is
   bypassed for zero overhead.

The node supports single images, temporal sequences, and experimental CG
multi-pass workflows.

## Requirements

| Component | Requirement |
| --- | --- |
| Operating system | Windows 10 or Windows 11, 64-bit |
| GPU | NVIDIA RTX GPU |
| Nuke | Nuke 15.0 or Nuke 17.0 build matching the supplied plug-in DLL |
| Runtime | A compatible runtime obtained and configured legally by the user |

Nuke point releases require their own compatible plug-in build. Do not assume a
DLL built for Nuke 15.0 is automatically compatible with Nuke 15.1 or 15.2.

## Installation

Three paths. Pick the first unless you are changing the code.

### A. One-click installer — download and run

1. Download `DLSS5-for-Nuke-ACES-<version>-Setup.exe` from the Releases page.
2. Run it.
3. Restart Nuke, press **Tab**, create `DLSS5Live`.

That is all. No ZIP to extract, no Visual Studio, no CMake, no Nuke NDK, and no
Visual C++ redistributable — the installer is a single self-contained
executable that unpacks itself and does the work.

It is unsigned, so a freshly downloaded copy trips SmartScreen: **More info →
Run anyway**.

`Setup.exe /uninstall` and `Setup.exe /y` are passed straight through to the
installer, and the install leaves a `DLSS5Live-uninstall.bat` beside the plug-in
folder in `~/.nuke/`.

### B. From a Release ZIP

Same thing, if you would rather see the files first: extract the ZIP and run
`install.bat`. Identical behaviour and the same options.

Either way, the installer removes any previous installation before installing,
including one made by upstream's installer:

- old `DLSS5Live.dll` files, for every Nuke version, so no stale build can be
  loaded by accident;
- a stray DLL in `~/.nuke/` or `~/.nuke/DLSS5Live/`, which would shadow the
  versioned one and load the wrong ABI into Nuke;
- upstream's `init.py` registration, replaced with an equivalent one that has
  an end marker so `/uninstall` can remove it cleanly later.

**Your NVIDIA runtime is never touched.** Only the two files this project owns
(`DLSS_Nuke_Worker.exe` and the `nvngx.dll` shim) are replaced under `runtime/`;
anything else you put there stays. Your `~/.nuke/init.py` is backed up with a
timestamp before any edit, and only one clearly-marked block is ever added or
removed.

| Option | Effect |
| --- | --- |
| `/keep-versions` | Keep DLLs for Nuke versions this package does not ship. By default they are removed, and the installer tells you which ones before doing it. |
| `/uninstall` | Remove the plug-in and the `init.py` registration. |
| `/y` | Do not wait for a keypress at the end. |

### C. From source

Needs **Visual Studio 2022 or newer with "Desktop development with C++"** (CMake
and Ninja come with its "C++ CMake tools for Windows" component) and at least one
**Nuke install**, because the plug-in links against `DDImage` from the NDK — and
the NDK ships inside Nuke, not as a separate download.

```bat
git clone https://github.com/guidogonzalezc/DLSS5-for-Nuke-ACES.git
cd DLSS5-for-Nuke-ACES
tools\build_and_install.bat
```

It finds the toolchain, finds every Nuke install carrying an NDK, verifies the
colour pipeline, compiles `DLSS5Live.dll` for each Nuke major version found,
compiles the worker, and installs into `~/.nuke/DLSS5Live/`. Any Nuke version is
handled, not just the two upstream publishes.

| Option | Effect |
| --- | --- |
| `/nuke "PATH"` | Point at a Nuke install explicitly. Repeat for several versions. |
| `/skip-tests` | Skip the colour pipeline verification. |
| `/skip-worker` | Do not build `DLSS_Nuke_Worker.exe` and the caller shim. |
| `/build-only` | Compile into `bin\` without installing. |
| `/uninstall` | Same as the installer's. |

### Then supply the NVIDIA runtime

Neither path produces, ships or downloads NVIDIA binaries. Put your own legally
obtained copies into `~/.nuke/DLSS5Live/runtime/`:

| File | Where it comes from |
| --- | --- |
| `_nvngx.dll` | NGX core. **You supply this.** Note the leading underscore. |
| `nvngx_dlssnr.dll` | DLSS-NR model. **You supply this.** |
| `nvngx.dll` | This project's caller shim. **Installed for you** — a different file from NVIDIA's `_nvngx.dll`; do not overwrite it. |
| `DLSS_Nuke_Worker.exe` | This project's worker. **Installed for you.** |

The installer prints which of these are present and which are missing when it
finishes.

### First run

1. Start Nuke, press **Tab**, create `DLSS5Live`.
2. The node header should read **v1.1.0-aces**. If it says `v1.0.0`, an older DLL
   is still being picked up from elsewhere on the plug-in path.
3. Set **nvngx.dll (Worker) Path** to
   `~/.nuke/DLSS5Live/runtime/DLSS_Nuke_Worker.exe` (or set the
   `NUKE_DLSS5_WORKER_PATH` environment variable).
4. Under **ACES Color Management**, set **Working Space** to match your Nuke
   working space.

To sanity-check colour: set **Upscaling Mode** to `1.0x (DLAA)` and `Merge
(difference)` the node against its own input. You should see the neural
difference only — no overall cast, no shift along a grey ramp. Toggling **Enable
Color Management** shows the upstream behaviour for comparison.

### Producing a Release (maintainers)

Everything users download is built once, on a machine with Nuke:

```powershell
tools\build_and_install.bat /build-only
powershell.exe -ExecutionPolicy Bypass -File tools\package_release.ps1 -CreateZip
powershell.exe -ExecutionPolicy Bypass -File tools\make_installer_exe.ps1
```

`package_release.ps1` collects every `bin\Nuke*` DLL that was built, the worker,
the installer and the docs, stamps `VERSION.txt` to match the string compiled
into the node header, refuses to package third-party runtime binaries, and
rejects batch files with LF line endings.

`make_installer_exe.ps1` serialises that folder into `installer/setup_stub.cpp`
as a resource and links it statically, producing the one-click `Setup.exe`.
Building the installer needs MSVC; running it does not.

> IExpress, which ships with Windows, was the obvious way to build the .exe.
> Its `AppLaunched` step fails with `0x80070002` on current Windows builds even
> for a minimal one-file package — the payload extracts and nothing ever runs —
> so the stub replaces it. It is ~200 lines of Win32 with no dependencies.

**Batch files must stay CRLF.** `cmd.exe` tracks its position in a running
`.bat` by byte offset; with LF-only endings it mis-seeks after returning from
`call :label` and silently skips the following line — no error, no output, the
statement simply never runs. `.gitattributes` pins this, and
`package_release.ps1` fails the build if it slips through.

## Runtime policy

The public v1.0 release policy is deliberately narrow:

- The Release ZIP includes project-authored installation files and project-built
  Nuke plug-in DLLs.
- It does **not** include or redistribute NVIDIA, NGX, DLSS, ReShade, RenoDX,
  or other third-party runtime binaries.
- Users must obtain any required runtime from a source and under terms that
  permit their use. Do not attach proprietary runtime DLLs to issues or pull
  requests.

The repository's MIT license applies only to project-authored code and does not
relicense third-party software, SDKs, models, or trademarks.

## Using DLSS5Live

### Inputs

| Input | Label | Use |
| --- | --- | --- |
| 0 | `Source` | Required source image stream. |
| 1 | `motion` | Optional external motion-vector stream when External Input 1 is selected. |
| 2 | `depth` | Optional depth guide for CG Multi-pass (`depth.Z`, `red`, or `alpha`). |
| 3 | `mask` | Optional control-mask guide for CG Multi-pass (`alpha` or `red`), dynamically bound to `DLSSNR.ControlMask` (e.g. Roto or object mask). |

### Pipeline modes

- **Single Frame (Default)** evaluates each frame independently and resets
  temporal history every frame. This is the recommended default for stills,
  timeline scrubbing, and matte painting work to prevent temporal ghosting.
- **Sequence** keeps temporal history across consecutive forward frames. Use a
  consistent frame order and reset history when the sequence changes.
- **CG Multi-pass** exposes the depth and control-mask inputs in addition to
  source and motion. The interface is present, but its output difference has
  not yet been fully validated; use it as an experimental workflow.

### Motion Vector Source

In **Sequence** and **CG Multi-pass**, choose one of these sources:

| Source | Behavior | When to use it |
| --- | --- | --- |
| **Auto Flow (OpenCV DIS)** | Calculates dense optical flow from consecutive Source frames in the background. | A normal image sequence without a separate motion-vector pass. |
| **External Input 1** | Reads motion vectors from input 1. | A compositing or CG workflow that already provides a suitable motion-vector pass. |
| **None / Zero Motion** | Sends zero motion and does not use external vectors. | Stills, a deliberate no-motion test, or content where no usable vectors exist. |

#### OpenCV DIS Presets

When **Auto Flow (OpenCV DIS)** is active:

| Preset | Resolution | Speed | Intended Use |
| --- | --- | --- | --- |
| **Fast Preview** | 480p | ~2 ms | 24 fps interactive viewer playback. |
| **Balanced (Default)** | 640p | ~6 ms | Standard production balance between accuracy and performance. |
| **High Quality** | 960p | ~15 ms | High-frequency detail and complex foreground motion. |
| **Extreme** | 1280p | ~40 ms | Offline final rendering. |
| **Custom** | User-defined | Varies | Manually specify **Flow Width** and **Iterations**. |

#### External Motion Vector Knobs

When **External Input 1** is active:
- **MV Channels**: Selects 2 channels for U (X) and V (Y) displacement (defaults to `forward`, `motion`, or RG).
- **MV Scale X / Y**: Multiplier for vector magnitude.
- **Invert X / Y**: Inverts horizontal or vertical vector directions.

## Node Controls

### DLSS Resolution & Model

- **Upscaling Mode**:
  - `1.0x (DLAA / Native)`: Pure Neural Reconstruction at native resolution.
  - `1.5x (Quality)`, `1.72x (Balanced)`, `2.0x (Performance)`, `3.0x (Ultra Performance)`:
    Two-pass pipeline (DLSS-NR + DLSS-SR).
- **DLSS Model Preset**: Model architecture presets (`Default`, `J`, `K`, `L`, `M`).
  Preset `J` is optimized for neural reconstruction.
- **NR Style**: Neural reconstruction style profile:
  - `Default`: Balanced neural enhancement.
  - `Natural`: Organic, soft detail retention.
  - `Cinematic`: Film-grade texture and grain preservation.
- **NR Preset**: Tuning profile (`Default`, `Preset #1`, `Preset #2`, `Preset #3`).
- **Automatic Mask**: Automatically masks out non-neural UI or static elements.

### Neural Tuning

- **Intensity** (`0.0` - `2.0`, default `1.0`): Global Neural Reconstruction strength.
- **Local Tone** (`0.0` - `2.0`, default `1.0`): Local tone mapping and dynamic contrast adjustment.
- **Local Structure** (`0.0` - `2.0`, default `1.0`): Local structural detail and texture enhancement.
- **Skin Structure** (`-1.0` - `2.0`, default `-1.0`): Specialized skin and facial detail enhancement.
  The default `-1.0` automatically inherits the value of **Local Structure**. Values from `0.0` to `2.0`
  override and independently adjust skin fidelity.

### ACES Color Management

Full reference: **[docs/ACES.md](docs/ACES.md)**.

- **Enable Color Management** (default on): wrap the neural pass in the
  invertible transform. Off reproduces upstream behaviour exactly.
- **Working Space**: the colour space arriving at input 0. Must match your Nuke
  working space - `ACEScg` with a standard OCIO ACES config. Also supports
  ACES2065-1 (AP0), ACEScct, ACEScc, Linear Rec.709/sRGB and Linear P3-D65.
- **DLSS Encoding**: what the model is shown. `sRGB Display (Rec.709)` is the
  default and gives the best reconstruction. `ACEScct Log (AP1)` trades a little
  reconstruction quality for flat precision across the range - use it for fire,
  explosions and practicals above ~30.
- **Highlight Roll-off**: `Extended Reinhard` (default, invertible for any
  value), `ACES Filmic (Narkowicz)` for more mid contrast, or `None`.
- **Pre-Exposure**: stops applied before the neural pass and removed after it.
  Never reaches the output; use it to place a dark plate where the model works.
- **Auto White Point** (default on) / **White Point**: the scene-linear value
  that maps to `1.0` for the model. Auto tracks the frame maximum, and latches it
  for the length of a temporal run so the model does not see exposure flicker.
- **Gamut Compress** (default on): ACES reference gamut compression, undone
  afterwards, so saturated AP1 colour does not reach the model as negatives.

Highlight precision is the one real trade-off: a display encoding packs
everything above the white point into the last sliver of the `0-1` range, so
round-trip error grows with the white point (~0.8% of pixel magnitude at `16`,
~4% at `128`, ~0.4% with the ACEScct encoding). The test suite prints these
figures on every run.

### Color & Dynamic Range

- **Color Bit Depth**:
  - `16-bit Half Float (Scene-Linear, Recommended)` (Default): Preserves full scene-linear
    dynamic range through the IPC transport.
  - `8-bit Integer (SDR Legacy)`: Legacy compatibility path where RGB is clamped to `0-1`
    and quantized to 8-bit in both directions. With colour management on, this now carries a
    display-encoded signal, which is what 8-bit is actually suited to.
- **Enable HDR Range** / **HDR Range Scale**: the upstream stopgap for the same
  problem the colour pipeline now solves properly, so these only appear when
  **Enable Color Management** is off. When enabled, RGB is divided by the ratio
  before DLSS-NR (Feature 18) and multiplied back afterward. Alpha, motion
  vectors, depth and mask guides are not scaled.

### Scanline Layout Alignment

Nuke natively indexes image scanlines from the bottom up (row `y = 0` at the bottom).
DirectX 12 and the worker operate with top-down textures (row `y = 0` at the top).
`DLSS5Live` automatically converts scanline coordinates for the main image, motion
vectors, depth, and control masks before transfer, and aligns the worker output back
into Nuke's row cache, eliminating vertical flip and orientation issues.

## Build from source

[Installation](#installation) covers the normal path. What follows is for
driving the underlying scripts directly.

Building requires Visual Studio 2022 with Desktop development with C++, CMake,
Ninja, and a local Nuke NDK installation matching the target DLL. Build the
Nuke plug-in and worker with the repository scripts, then package only the
publicly approved files for a Release.

```powershell
powershell.exe -ExecutionPolicy Bypass -File tools/build_multi.ps1
powershell.exe -ExecutionPolicy Bypass -File worker/build.ps1
```

The colour pipeline can be verified without any of that:

```powershell
powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
```

It needs only MSVC - no Nuke NDK, no GPU, no NVIDIA runtime - and checks that the
colour round trip is the identity, that the two copies of `VideoHeader` still
agree, and that `src/DLSS5Live.cpp` still compiles.


### Build for an unlisted Nuke version

The repository includes the C++ source, CMake files, and build scripts needed
to compile `DLSS5Live.dll` against a local Nuke installation. If your Nuke
version is not listed in a Release, build the plug-in against that version's
own NDK instead of renaming an existing DLL.

For example, a Nuke 15.2 installation can be supplied to the Nuke 15 build
argument:

```powershell
powershell.exe -ExecutionPolicy Bypass -File tools/build_multi.ps1 `
    -Nuke15Dir "C:\Program Files\Nuke15.2v1"
```

The result is written to `bin/Nuke15/DLSS5Live.dll`. Back up any existing
local DLL, then copy this result to the corresponding `bin/Nuke15/` folder
under your `~/.nuke/DLSS5Live/` installation. Use `-Nuke17Dir` in the same way
for a Nuke 17 installation.

Building the project-owned DLL does not provide NVIDIA or other third-party
runtime files. You remain responsible for supplying a compatible runtime under
its applicable terms. A successful compilation is not proof that an unlisted
Nuke version or runtime combination has been tested by this project.

Packaging and uploading a Release are maintainer-controlled actions. The public
CI checks source code; it does not publish Releases or bundle third-party
runtimes automatically.

## License and disclaimer

Project-authored source is licensed under [MIT](LICENSE), which this fork keeps unchanged; the upstream project and its authors retain credit for everything outside the colour pipeline. NVIDIA, DLSS, NGX,
Foundry, and Nuke are trademarks or registered trademarks of their respective
owners. This project does not claim ownership of their SDKs, runtimes, or
trademarks.
