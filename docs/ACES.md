# ACES colour management in DLSS5Live

This fork adds an invertible colour pipeline around the neural pass so the node
can be used inside an ACES comp without shifting colour.

## The problem

The DLSS neural models were trained on game frames: Rec.709 primaries, a display
transfer function, and values that live in a nominal `0..1` range.

Nuke's ACES working space is none of those things:

| | DLSS expects | ACEScg in Nuke |
| --- | --- | --- |
| Primaries | Rec.709 (D65) | AP1 (D60) |
| Transfer | sRGB / display gamma | scene-linear |
| Range | ~0..1 | 0..65504, unbounded in practice |
| Negatives | none | routine, and meaningful |

Upstream sends Nuke's pixels to the model unchanged. All four mismatches then
land at once:

- **Wrong primaries.** The model's priors about skin, sky and foliage are tuned
  for Rec.709. Shown AP1 numbers it reads them as Rec.709, so hue and saturation
  drift — most visibly on skin.
- **Wrong transfer.** Scene-linear light is enormously non-uniform
  perceptually. Detail and local-contrast enhancement applied to linear code
  values lands almost entirely in the highlights and does nothing in the
  shadows.
- **Out of range.** A practical light at `12.0` is twelve times past anything the
  model has seen. It clamps, and the highlight comes back flat.
- **Negatives.** Saturated ACEScg colours have negative components once expressed
  in Rec.709. Neural paths handle those badly.

The upstream **HDR Range Scale** knob addresses only the third of these, and it
does so with a flat divide, which costs shadow precision to buy highlight
headroom.

## The approach

Wrap the neural pass in a transform and its exact inverse:

```
Nuke working space
      |
      v
  pre-exposure                 (stops, removed again afterwards)
      |
      v
  primaries matrix             AP1 -> Rec.709, Bradford D60 -> D65
      |
      v
  gamut compression            ACES RGC, folds negatives inside the cube
      |
      v
  highlight roll-off           extended Reinhard, white point -> 1.0
      |
      v
  transfer function            sRGB EOTF^-1
      |
      v
   [ DLSS-NR + DLSS-SR ]       <- the model sees what it was trained on
      |
      v
  inverse of every step above, in reverse order
      |
      v
Nuke working space
```

The important property is that **every stage has a closed-form inverse**. With
the neural pass bypassed, the round trip is the identity. So the node can only
ever change the picture by as much as DLSS changed it — the colour management
itself contributes nothing.

That is not a claim, it is a test. `tests/run_tests.ps1` runs the round trip over
a spread of real ACES values (mid grey, skin, saturated primaries, a practical at
12.0, fire at 60.0, a near-black noise floor, an already-negative AP1 component)
through every combination of knobs, and fails if anything comes back changed.

## Why these particular transforms

Every stage was chosen for invertibility first and appearance second.

**Extended Reinhard** rather than the ACES RRT+ODT. The real ACES output
transform is the more faithful "what the artist sees", but it clips at the top
and its inverse amplifies noise. Extended Reinhard,
`f(x) = x(1 + x/W²) / (1 + x)`, maps the white point `W` to exactly `1.0`, is
strictly increasing everywhere, and inverts with the quadratic formula. Nothing
is lost that cannot be recovered.

> The naive inverse `0.5·W²·(√D − k)` loses nearly every significant digit for
> small values: the two terms agree to ~8 digits and the difference is then
> multiplied by `W²/2`. `AcesColor.h` uses the conjugate form `2y / (√D + k)`
> below the white point instead. Without that fix the round trip is 24% off in
> the shadows — see the comment on `reinhardDecode`.

**ACES reference gamut compression** rather than a clamp. Clamping negatives
destroys them; the RGC folds them just inside the gamut and has an exact inverse,
so saturated colour survives the trip.

**Odd-symmetric transfer functions.** Every curve is extended as
`f(-x) = -f(x)`. Without it, `pow()` on a negative component produces NaN, and
clamping to zero turns saturated colour into a hard edge.

**Matrices derived, not transcribed.** `AcesColor.h` builds the primaries
matrices from published chromaticities and a Bradford adaptation at runtime. The
test asserts the result equals the canonical ACES matrix
(`1.7050516, -0.6217908, -0.0832588, …`), so a typo is impossible and the
inverse is a true inverse rather than a separately-transcribed second matrix.

## Controls

Everything lives under **ACES Color Management** in the node's properties.

### Enable Color Management

On by default. Off reproduces upstream behaviour exactly — bit-exact
passthrough, and the legacy **HDR Range Scale** knobs come back.

### Working Space

The colour space of the pixels arriving at input 0. **This must match your Nuke
working space** (Project Settings ▸ Color ▸ working space). With a standard OCIO
ACES config that is `ACEScg`.

Getting this wrong applies the wrong primaries, which is exactly the hue shift
the pipeline exists to prevent.

Supported: ACEScg (AP1), ACES2065-1 (AP0), ACEScct, ACEScc, Linear Rec.709/sRGB,
Linear P3-D65.

### DLSS Encoding

What the model is actually shown.

| Encoding | Use it when |
| --- | --- |
| **sRGB Display (Rec.709)** | Default. Closest to the model's training data, best reconstruction. |
| Rec.709 Camera OETF | Matching a pipeline that already works in BT.709 OETF. |
| Gamma 2.2 (Rec.709) | Same, with a pure power curve. |
| **ACEScct Log (AP1)** | Shots with extreme highlights — fire, explosions, practicals above ~30. |
| Linear (no encoding) | Reproducing upstream behaviour for comparison. |

`ACEScct Log` keeps AP1 primaries, so the model sees less familiar colour and
reconstruction is a little weaker. In exchange, log precision is even across the
whole range, so extreme highlights come back intact. It is the right choice when
highlight fidelity matters more than the last bit of neural detail.

### Highlight Roll-off

How values above the white point are folded into `0..1`.

- **Extended Reinhard** — gentle, monotonic, invertible for any value. Default.
- **ACES Filmic (Narkowicz)** — more mid contrast. The curve is only monotonic up
  to about `6.6`, so the input is pre-scaled by `6.5 / W`; with the white point
  tracking the frame, the whole image lands inside the invertible domain.
- **None** — no roll-off; everything above `1.0` is left for the model to clip.

Ignored for the ACEScct encoding, which carries the range itself.

### Pre-Exposure

Stops applied before the neural pass and removed after it. Purely a way to place
the image where the model works best; it never reaches the output. Raise it for
very dark plates so the reconstruction has something to grip.

### Auto White Point / White Point

The white point is the scene-linear value that maps to `1.0` for the model.

**Auto White Point** derives it from the brightest pixel in the frame, so nothing
clips into the roll-off. In **Sequence** and **CG Multi-pass** it is latched when
temporal history resets and held for the rest of the run — recomputing it every
frame would make the model see a different exposure each frame, which reads as
flicker in the accumulated history.

Set it manually when you want a value stable across shots.

### Gamut Compress

Applies the ACES reference gamut compression before the neural pass and undoes it
after. Leave it on unless you are chasing a specific look; saturated AP1 colours
otherwise arrive at the model as negative components.

## Highlight precision: the one real trade-off

A display encoding spends its fp16 mantissa evenly across `0..1`, but the tone
curve packs everything from the white point upwards into the last sliver of that
range. The higher the white point, the coarser highlights come back.

Measured over the test's sample set, as a fraction of each pixel's own magnitude:

| Setting | Worst round-trip error |
| --- | --- |
| sRGB + Reinhard, W = 16 (default) | ~0.8% |
| sRGB + Reinhard, W = 128 | ~4% |
| ACEScct Log | ~0.4% |
| Linear (upstream) | ~0.4% |

For context, DLSS itself changes those pixels by far more than 4% — that is what
it is for. But if a shot needs both extreme highlights and tight precision, use
the **ACEScct Log** encoding: it is log, so its precision is flat across the whole
range.

These figures are printed by the test suite on every run, so a regression shows
up as a number, not a vague impression.

## The worker's IsHDR flag

`DLSS.Feature.Create.Flags` carries `IsHDR`, which tells DLSS-SR the colour buffer
is scene-referred with values past `1.0`. Once the node encodes to a
display-referred signal that is no longer true, so the plug-in clears the flag via
a new `color_flags` field in the frame header and the worker honours it.

`color_flags` was carved out of the unused scene-cut reserve rather than appended,
so `VideoHeader` is still 96 bytes and mixed builds keep working:

- new plug-in + **old** worker: the field is ignored, `IsHDR` stays set (upstream
  behaviour, slightly worse SR)
- old plug-in + **new** worker: the field reads zero, `IsHDR` stays set (upstream
  behaviour)

`tests/test_protocol_abi.cpp` pins the size and the field offsets so this cannot
drift. Rebuilding the worker is therefore optional; you get slightly better
super-resolution if you do.

## Verifying it yourself

```powershell
powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
```

No Nuke NDK, no GPU and no NVIDIA runtime required. It checks three things:

1. the colour pipeline is invertible, across every knob combination
2. the two copies of `VideoHeader` still agree, and still match upstream's layout
3. `src/DLSS5Live.cpp` still compiles (against a mock DDImage in
   `tests/mock_ddimage/`, used only for this check and never shipped)

Inside Nuke, the equivalent check is a `Merge (difference)` between the plug-in
input and output with **Upscaling Mode** on `1.0x (DLAA)` and the neural tuning
at its defaults: the result should be the neural difference alone, with no
overall cast and no shift on a grey ramp.

## Where the code lives

| File | What it does |
| --- | --- |
| `src/AcesColor.h` | The whole colour pipeline. Dependency-free, unit-testable. |
| `src/DLSS5Live.cpp` | `buildColorParams()`, and the two passes in `computeFrameCache()`. |
| `worker/DLSSWorker.cpp` | Honours the display-referred flag when creating the SR feature. |
| `tests/` | The verification described above. |
