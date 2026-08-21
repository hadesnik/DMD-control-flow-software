# Plans for a "killer demo" photostim experiment

**Status: idea stage, 2026-08-21.** Design discussion only — nothing implemented, no
hardware commitment. This is the seminar/wow demo, deliberately *not* the rigorous
preliminary-data figures (those stay as listed in `CLAUDE.md` under "Driving goal").

Numbers below marked *(est.)* are back-of-envelope from the discussion and have not
been measured or computed against the handoff. Everything else is either from
`docs/optics_handoff.md` rev 5 or standard literature values.

---

## The demo

Project a real movie — faces, a Muybridge galloping horse, a logo — onto ChRmine+GCaMP
cortex or CA1 via the DMD, and read the movie back out in the GCaMP channel. The brain
is the display; the neurons are the pixels.

**Show two versions, in this order.**

1. **Filled paint.** Project the movie as a filled grayscale image, no segmentation.
   The ΔF/F field is continuous — limited by neuropil blur (~20–40 µm), *not* by cell
   density — so it looks photographic. Works in a naive mouse on day one. Pure eye candy.
2. **The constellation.** Segment somata first; sample the movie at each cell's location
   and drive only identified cells. The DMD pattern is then a meaningless scatter of
   dots; the movie appears only in the response map. Put the two side by side.

Version 2 is the one that demonstrates **per-cell addressing**, which is the capability
unique to this device. Version 1 alone shows something a 1p LED and a photomask could
roughly do — worth knowing before choosing what to put on the slide.

**Content:** a Muybridge gallop beats faces at low resolution — 12 frames, iconic,
readable at 25×25, and the *motion* is the point, which sells rapid pattern switching.
Faces are hard to recognize at low res and carry no surprise. Keep a drifting grating
written into V1 in retinotopic coordinates as the second, more scientific stimulus.

---

## Numbers

### Spatial — how many pixels

| prep | usable cells in 1 mm² *(est.)* | effective grid |
|---|---|---|
| Cortex L2/3, one plane | 400–1000 | ~20–30 per side |
| **CA1 pyramidal layer** | **3000–5000** | **~55–70 per side** |

Cortex: ~10⁵ neurons/mm³, one 2p plane samples ~20–30 µm axially → ~2000 anatomically,
then discount for ChRmine+GCaMP co-expression, segmentability, and drivability. The
original 40×40 guess is optimistic by ~2×.

**CA1 is the better prep for image quality** and is a monolayer, which suits a device
with 33.2 µm axial confinement. Costs: hard prep (cortical aspiration + chronic
cannula, variable window quality), and CA1 is far more excitable than cortex — driving
~40% of pyramidal cells synchronously every few seconds is a plausible route to
afterdischarges. Sparsify and watch for interictal activity. Also expect intrinsic
dynamics (sharp waves) to overwrite the pattern between frames — say so before the
audience does.

⚠️ **In CA1 the excitation-plane tilt goes from optional to mandatory.** The 34.9 µm
depth walk across the field is comparable to the pyramidal layer's own thickness, so
uncorrected you skim in and out of the layer and lose opposite edges of the image
(in cortex it's only a shading gradient). Either dial in the sample tilt stage or let
the SLM follow the layer — 908 µm of remote focus range against a ~35 µm correction.

### Field

A 1×1 mm movie is essentially the whole patch (1067 × 1228 µm). Consequences:

- **Edge dwell is 7.70×** the centre (quadratic, `dwell_exponent: 2`). Free in the
  stop-motion version — 3 s per movie frame at 12.5 kHz binary is ~37,500 DMD frames,
  so the correction is noise against the budget. Expensive at video rate.
- Depth tilt as above.

### Temporal — the frame-rate ladder

GCaMP6s at 0.3 Hz is a **stop-motion flipbook**, played back at 10×. Perfectly
respectable and easiest to get. jGCaMP8f (~70 ms decay half-time) buys real video.

| | multi-plane | single plane |
|---|---|---|
| **stim bottleneck** | SLM settle 3.4 ms × n depths → ~10 ms/frame at 3 depths | none — DMD switches at 12.5 kHz |
| **imaging bottleneck** | **ETL/piezo, ~7.5 Hz volume rate at 4 planes** | 30 Hz resonant |

**The SLM is not the multi-plane bottleneck — imaging is.** `configs/real.yaml` carries
`slm.settle_s: 0.0034` (Meadowlark LC response, handoff §6), and the HSP1K is
Meadowlark's *high-speed* phase line (1.4–1.7 kHz analog frame rate), not a
tens-of-ms standard nematic. Three depths costs ~10 ms of settling per movie frame:
trivial at 10 Hz, and about 30% of the budget at 30 Hz. So multi-plane stim runs
comfortably to 10–20 Hz and 30 Hz with 2–3 depths is plausible; what actually caps a
multi-plane movie is the volumetric imaging rate.

**Shortest path to something that looks like real video: CA1 (monolayer) + jGCaMP8f +
single plane + no SLM in the loop.** At 30 Hz, 8f gives ~3 frames of persistence, which
reads as motion blur, not failure.

*(This corrects an earlier claim in the source conversation that the HSP1K's LC settle
capped multi-plane stim at 5–10 Hz — off by ~10×. It also weakens, though does not
remove, the "this demo argues for the TI PLM" line: the PLM's µs switching still wins,
but the LC SLM is not the thing standing between us and a video-rate 3D movie.)*

---

## The neural LUT ("gamma correction")

Each neuron needs its own transfer curve so a movie pixel value maps to the right drive.
Implemented as **mirror PWM** — DMD duty cycle per cell.

### The structural fact that makes this tractable

**A mirror duty cycle cannot make a laser pulse dimmer — it only changes pulse count.**
At 12.5 kHz mirror switching against the 100 kHz laser, each 80 µs DMD frame carries
~8 laser pulses; duty cycle picks how many of those windows a cell participates in.
Per-pulse intensity is set globally by laser power and spot size. Three consequences:

1. **Gamma never touches the safety envelope.** `assertPulseEnergySafe` gates per-pulse
   energy at the pupil, which PWM does not move. Set global power once so every cell's
   per-pulse regime is safe; grayscale is then free. Not true if grayscale were done
   with a per-cell analog power ramp.
2. **Don't sit cells on the steep part of the sigmoid.** Put every cell at a dose that
   reliably clears threshold and fires a burst; make grayscale be *how many times* you
   do that per frame. Normalizes the sigmoid out of the problem.
3. **The LUT collapses from a curve to a scalar per cell** — the duty that reliably
   clears threshold, plus a gain to normalize ΔF/F. Afternoon of calibration, not a week.

### Bit depth is the real limit

Spike counts are quantized and jittery: **~3 bits (8 levels) per cell per frame**, not 8
bits *(est.)*. And it is time-bounded:

```
bit depth ≈ log2(frame_period / event_duration)     # event_duration ~10 ms
```

| frame rate | events/frame | usable bits |
|---|---|---|
| 0.3 Hz stop-motion | ~30 (thermally capped, not time-capped) | ~5 |
| 10 Hz | 10 | ~3 |
| 30 Hz video | 3 | ~1.5 |

So frame rate and grayscale are the same trade. At 0.3 Hz you get genuine smooth
grayscale, with GCaMP's slow integration acting as a second free PWM stage. **At 30 Hz
you are essentially binary — use spatial dithering (Floyd–Steinberg) across the cell
population.** At 60×60 in CA1 an error-diffused face looks far better than a naively
quantized one. Display engineering solved this in the 1970s; borrow it.

### Phase-stagger the PWM

The naive implementation switches every cell ON at frame start and OFF at its own duty
time — so t=0 is 100% ON regardless of image content, tripping the contiguity and
pulse-energy checks every frame. Stagger each cell's PWM phase pseudo-randomly: the
instantaneous ON count then sits flat at the frame's mean brightness. Costs nothing,
and decouples "bright image" from "safety trip."

### Measuring 600 LUTs in ten trials

Sequential per-cell sweeps are hopeless (hours). But PWM can give **every cell a
different dose in the same frame** — one trial probes all 600 cells at 600 doses at
once. Permute the dose assignment across ~10 trials, fit per-cell. Minutes.

Keep total ON fraction low during calibration so you measure direct drive rather than
network recruitment, and interleave group membership spatially so neighbours aren't
co-stimulated. Good seminar beat: the same capability that makes the demo work is what
calibrates it.

### The failure mode that will actually bite: burn-in

**ChRmine desensitizes.** In a movie, bright regions have been driven harder than dark
ones, so every cell arrives at frame *n* with a different recent history — bright areas
fade over the sequence, in a pattern tracking the movie's own brightness history. This
is display burn-in. Fix with a per-cell leaky-integrator adaptation term folded into the
commanded duty, or cheaply by keeping the frame rate low enough that recovery outpaces
accumulation. **Predict it in advance** — when it appears it looks like the whole
approach failing rather than a correctable systematic.

### Smaller LUT notes

- You don't need linearity, you need **monotonicity plus a measured inverse**. Cells
  that saturate and roll over get their range clipped to the monotonic portion.
- Keep the **neural LUT** (linearizes spikes per cell) separate from the **display
  gamma** applied when rendering the readout. Conflating them makes both untunable.
- Expect **20–40% of cells unusable** at any safe dose. Mark them dead pixels and let
  the dithering inpaint around them.

---

## Power, thermal, safety

- A filled natural image is ~40% ON **as one large contiguous blob** — precisely the
  case the 50% cap is tightest against (`CLAUDE.md`: "50% ON as one filled block" vs
  scattered targets). ~3.4 W of 40 W, ~68 µJ against the 89 µJ ceiling. Inside, but with
  no margin on the case the rule is most conservative about.
- **Time-multiplex the filled version**: decompose each movie frame into ~20 sparse
  scattered sub-frames cycling at 12.5 kHz. Same average dose, ~20× lower instantaneous
  ON area, no large contiguous blob. GCaMP's slowness pays for this — the DMD frame
  budget is enormous at 0.3 Hz.
- **Thermal is the binding constraint on video rate, not optics or indicator.** ~10 ms
  stim per 33 ms frame is 30% duty; (cells ON) × (mW/cell) × duty over 1 mm² lands in
  the few-hundred-mW average range where 1–2 °C rises start *(est. — needs computing)*.
  You buy frame rate back by sparsifying the image (edge-rendered, not filled), which
  is the constellation version anyway. **The two converge: at video rate the thermal
  budget forces you into the more impressive demo.**

---

## Imaging artifact — resolved, not a blocker

> Worked through in full in **[STIM_IMAGING_SYNC.md](STIM_IMAGING_SYNC.md)** (2026-08-21),
> which adds a better primary option — gating the stim into the resonant turnaround, where
> no pixel is being acquired — and rules out laser phase-locking on the record. **Read the
> ⚠️ there before implementing the phase dither below: dithering and turnaround-locking are
> mutually exclusive, and doing both gives the worst case.** Note also that `XS13.18`
> SYNC_OUT is a cleaner censor marker than the pick-off photodiode.

The 1038 nm stim beam does directly excite GCaMP, but at 100 kHz stim vs 80 MHz imaging
with ~100 ns pixel dwell, only **~1% of pixels** see a stim pulse. Pick off a bit of the
stim beam onto a photodiode, digitize it on a spare channel binned per-pixel like
another color channel, and censor those pixels.

- Censor a **window** (~1 µs), not the coincident pixel — a PMT hit that hard rings
  afterwards. Still only ~10% of pixels.
- **Dither the stim trigger phase** by a few µs. Fixed 100 kHz against a fixed 8 kHz
  resonant line rate will not scatter hits randomly — it lays down structured stripes.
  Dithering turns stripes into salt-and-pepper, which interpolates away invisibly.
- **The stop-motion version needs none of this.** With a 200 ms stim window per 3 s
  frame, read the image out of the frames 300 ms–2 s post-stim, when the stim laser is
  off entirely. The real signal is definitionally what outlasts the stim; the artifact
  is definitionally instantaneous. The censor channel earns its keep only in the fast
  version where stim and imaging interleave continuously.

---

## What already exists in the repo

This is composition, not new machinery: `calibratedAffine`, `multiSpot`, `powerLUT`,
`Sequencer`, `TrialSequence.generate3DEnsemble` (depth-group dedupe + LC settle is
already the right structure for multi-plane stim), `tfp.io.assignFramePlanes` for
free-run plane tagging.

## Next steps, when we come back to this

- [ ] **Thermal/feasibility script** — take a movie + a soma constellation, report
      per-frame instantaneous ON fraction, largest contiguous blob, pulse energy, and
      average power at sample, checked against `readHandoffConstants()`. This is the
      one number that decides whether video rate goes on a slide.
- [ ] Read `src/+tfp/+patterns/powerLUT.m` and decide whether the per-cell LUT extends
      it or becomes a sibling. Sketch shape:
      `{cellId, dmdXY, thresholdDuty, gain, adaptationTau, reliability, valid}` plus a
      `frameToDutySchedule` emitting the phase-staggered pattern sequence.
- [ ] Decide prep: cortex (easy, ~25×25) vs CA1 (hard prep, ~60×60, mandatory tilt
      correction, seizure risk).
- [ ] Decide indicator: 6s if the line already exists (stop-motion only), jGCaMP8f/8m
      if ordering anyway (unlocks video rate).
- [ ] Gated on the NIR DLP650LNIR arriving and build B alignment.
