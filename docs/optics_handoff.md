# Optics handoff — DMD photostimulation, merged arm (rev 5, 2026-08-19)

**Generated** by `python -m configs.dmd_handoff` in the `TF optics simulator`
repo (commit `1216736`) — **regenerate rather than edit**; hand-edits are
overwritten. Build: `5.0mm Ra/Rb 250/200 f7 300 f6 80 p1 100`, the trade study's pinned labelled default
(`configs.merged_arm.recommended()`).

## Which build this describes — read this before using any number

This document is **design intent for the MERGED ARM**: the DMD
temporal-focusing front end relayed through the existing 3D-SHOT back end,
with the **Meadowlark SLM at the pupil as a remote focus** and the **CARBIDE
at 1038 nm**. Chain: CARBIDE → expander → DMD → 4f →
grating → 4f → f7 → SLM → f6 → periscope → PBS → Nikon
200 mm tube → Nikon CFI Plan Apo Lambda D 10X/0.45 (dry).

**It does not describe the rig this control software drives today** (FS-50
laser, DLP7000 option, the isotropic µm-per-pixel scales in `configs/*.yaml`).
Those numbers are current-rig calibration and stay authoritative until the
merged arm is physically built and calibrated. When it is, §5 is the expected
starting point — reached by a fresh affine fit, never by pasting.

Machine-readable constants for the tripwire test are in the appendix; keys
under `build: merged_arm` are void for any other build.

---

## 0. What changed since rev 3 — 2026-07-30 — read this first

**The arm itself changed, not a lens.** rev 3 described the
standalone bring-up arm — no SLM, walk uncorrectable. That standalone arm was superseded [USER 2026-08-08]: the
6 × 4 ft table cannot hold it beside 3D-SHOT, so the DMD front end is relayed
into 3D-SHOT's surviving back end and **the SLM stays in the path as a remote
focus**. Every difference below follows from that merge and from the laser's
factory test certificate; the deltas are not tweaks to the old design.

**The scale constants moved by +15% and +11%.** If any fixture carries the previous µm-per-pixel figures, it is wrong now — and the two axes did **not** move together, so a single scalar correction will not rescue them.

| | rev 3 — 2026-07-30 | **this revision (rev 5)** |
|---|---|---|
| Arm | standalone bring-up arm — no SLM, walk uncorrectable | **merged into the 3D-SHOT back end, SLM remote focus** |
| Laser | CARBIDE CB3-40W, 1030 nm, 200 fs, 9.00 nm — all datasheet | **1038 nm, 205 fs, 9.6 nm — all `[CERT]` for this unit** |
| Back end | periscope 150 → 250 mm (proposed swap), Olympus 180 mm tube | **f7 300 → SLM → f6 80 → peri 100/200 → Nikon 200 mm tube** |
| New lenses | L1a 75 / L1b 400 / La 200 / Lb 60 | **L1a 80 / L1b 400 / Ra 250 / Rb 200** |
| Field | 926 × 1108 µm | **1067 × 1228 µm** |
| **µm/px, groove axis** | 2.0000 | **2.3040** |
| **µm/px, dispersion axis** | 2.3935 | **2.6528** |
| Anamorphic factor | 1.1968 | **1.1514** |
| Axial FWHM | 16.3 µm (scaling law) | **33.2 µm (diffraction table; the law now says 24.4)** |
| Depth walk (peak-to-peak) | 32.0 µm | **34.9 µm** |
| Depth walk status | cancelled by the sample tilt stage — see §6 | **SLM-correctable, per target group — see §6** |
| Depth gradient dz/dx | 0.02888 | **0.02843** |
| DMD patch | Ø5 mm / 463 px | **Ø5 mm / 463 px** |
| Illumination on chip | Ø12.0 mm (3× expander) | **Ø7.0 mm (1.75× expander, NOT a catalogue GBE)** |
| Patch edge intensity | 0.71 | **0.36** |
| Safe pulse energy | 75 µJ | **89 µJ** |
| Rep rate | ≥111 kHz REQUIRED — 100 kHz sat at 0.90× margin | **100 kHz usable, 1.04× margin at the relay pupil** |

**⚠ The scale below assumes 2 lens swaps that have not happened yet:** f7 (Fourier) 500 -> 300 mm; f6 (SLM relay) 150 -> 80 mm [vs the bench of record, USER 2026-08-08]. Until they do, the merged arm does not exist at these numbers — and a calibration fitted against today's unswapped back end would measure **1.1250× the µm-per-pixel figures in §5** (not a calibration error, a different instrument). Confirm the swaps before trusting any expected value here.

**The DMD patch is unchanged at Ø5 mm / 463 px**.

**The edge-to-centre dwell correction moved 1.41× → 7.70×** — and most of that is not the optics: **the rule itself changed, from 1/I to 1/I²**. Dwell compensates two-photon excitation, which goes as I², so a 1/I correction flattens the illumination but leaves the excitation centre-bright; rev 3 under-corrected every off-centre target. (The edge intensity also moved, 0.71 → 0.36, with the derived expander.) §8 has the corrected relation. **If you carry a precomputed dose table, this is a code change, not a recalibration:** applying the old 1.41× where 7.70× is needed delivers an edge target only 18% of its intended dose.

**The 45° clocking and the coordinate-transform *structure* are unchanged.**
Every equation in §5 still holds as written; it is the numbers fed into them
that moved — and §6 changed in kind, not degree: the depth walk went from a
fact to report to a quantity the SLM corrects.

**What this means for the control code:**

* **Refit the scale when the merged arm is built.** Both µm-per-pixel
  constants changed, by different amounts, because the anamorphic factor
  moved too (1.1968 → 1.1514). §5 has the
  new pair; §9 says why you should fit rather than paste them.
* **The SLM enters the control problem.** Target groups get a per-group
  defocus (§6); the all-ON alignment power cap is now a modulator-protection
  number (42 mW, §7), separate from the air-breakdown rule.
* **Re-derive any precomputed dose table — the exponent changed, not just
  the Gaussian.** Dwell scales as 1/I², not the 1/I of rev 3 and earlier
  (§8): an edge target needs 7.70× the dwell of a centre target,
  not 1.41×.
* **The 50% ON-fraction cap is unchanged and not negotiable** at any margin
  (§7).

---

## 1. The three things that will bite you

**The chip is mounted clocked 45° about its own normal.** Not square to the
bench. The DLP650LNIR's mirrors hinge about the chip's 45° diagonal, and
clocking is what lays that diagonal in the table plane so the illumination and
the grating both stay flat. Consequence: **every sample↔DMD coordinate
transform carries a 45° rotation**, and the optical axes of interest run along
the chip's *diagonals*, not its rows and columns.

**The sample-plane scale is anisotropic**, 1.1514× — and the
anisotropy is along the chip **diagonal**, because that is where the grating
disperses. A circle drawn in DMD pixels lands as an **ellipse** at the sample.

**A uniform all-ON pattern at full laser power is a hardware hazard twice
over** — air breakdown at the DMD relay's pupil, and a focused spectral line
on the SLM's liquid crystal. See §7. There are now **two programmable devices
in the path** (DMD amplitude, SLM phase), and the all-ON state is the
dangerous one for both.

---

## 2. The devices the control software drives

| | |
|---|---|
| Part | TI DLP650LNIR |
| Array | 1280 × 800 |
| Pitch | 10.8 µm |
| Active area | 13.824 × 8.640 mm |
| Mirror tilt | ±12°, hinge on the 45° diagonal |
| Binary frame rate | 12,500 Hz → **80 µs** per binary frame |
| Illumination incidence | 24.06° off the chip normal, in the plane of the blaze diagonal |

**The modulator seat** (pupil plane, remote focus). The Meadowlark is the
pinned choice; the TI PLM passes every gate in the same seat and differs only
in the rows below, so both are handed over:

| | Meadowlark 1024 x 1024 (HSP1K class) (pinned) | TI NIR PLM (0.67 in) (alternate) |
|---|---|---|
| Array | 1024 × 1024, 17.0 µm | 904 × 800, 16.2 × 10.8 µm |
| Phase | continuous (LC) | 32 states (sinc² loss 0.3%) |
| Max update | 1436 Hz | **1400 Hz hard cap** [USER 2026-08-08 — the 5.6 kHz burst mode is not available on the units in hand] |
| Load blanking | none (LC) | **100 µs per load = 14% duty at 1400 Hz — gate the DMD during loads, §6** |
| CW ceiling on the device | 30 W/cm² | 40 W/cm² |
| All-ON alignment cap (§7) | **42 mW** | 56 mW |
| Targets/plane at 1 µW/µm² | ~1098 | ~1273 |

**The laser** is the CARBIDE CB3-40W at 100 kHz,
400 µJ max per pulse. If the control software ever drives its rep
rate (external sync via XS13), note the regen amplifier **refuses these
bands** and silently jumps away from them: **255–258, 342–346, 500–528, 570–580, 765–783 kHz**.

## 3. The optical train that produces these numbers

Every constant in §5 and §6 falls out of this chain. It is here so that when
someone swaps a lens, it is obvious that the control code's calibration is now
stale — the failure is otherwise silent.

**New optics** (bought for this arm; all relays are 4f, so the spacings are
forced by the focal lengths and are not adjustable):

| # | Element | Part | f (mm) | Ø | Beam there | Role |
|---|---|---|---|---|---|---|
| 1 | L1a | AC254-080-B-ML | 80 | 1″ | 12.7 mm | DMD relay, first. Its length also sets the illumination clearance past its own barrel |
| 2 | L1b | ACT508-400-B-ML | 400 | 2″ | 32.7 mm | DMD relay, second. **M1 = 5.00×** |
| 3 | TF grating | Newport 33010FL01-530R | — | 50 × 50 mm | 34.6 × 25.0 mm lit | 1200 g/mm, 1000 nm blaze. **In 43.7°, out 33.7°** — sets the anamorphic factor and the depth tilt |
| 4 | Ra | ACT508-250-B-ML | 250 | 2″ | 37.1 mm | Grating-side relay, first |
| 5 | Rb | ACT508-200-B-ML | 200 | 2″ | 31.3 mm | Grating-side relay, second. **m_x = 0.800×** to the merge point I0 |

Plus a **1.75× beam expander** delivering Ø7.0 mm on the chip, a
λ/2 + polarizer (the grating runs 79% in s-pol against 50% in p, so this
is not optional), and fold flats.

**The expander is NOT a catalogue GBE**, and that matters to §8 rather than to
the parts list: it is two lenses of your choosing at 1.75×. Substituting the
nearest stock part, a GBE02-B, gives Ø7.8 mm on the chip instead of
Ø7.0 mm, which lifts the patch edge from 0.36 to
0.44 of centre — flatter, but it spends
more of the beam outside the patch. **If a GBE02-B is fitted, §8's dwell
correction becomes 5.09× rather than 7.70×** (dwell goes as
1/I², §8). Ask which is installed before computing a dose table.


**The existing 3D-SHOT back end** (from the merge point I0 on; chain of
record [USER 2026-08-08], with the 2 swaps this build asks for marked):

| Element | Value | Note |
|---|---|---|
| f7 (Fourier) | **300 mm** | bench carries 500 mm — SWAP (ACT508-300-B-ML). Beam 35.4 mm |
| SLM | Meadowlark 1024 x 1024 (HSP1K class) | at the pupil, 12.4 × 7.2 mm footprint on 17.4 × 17.4 mm (71% worst-axis fill) |
| f6 (SLM relay) | **80 mm** | bench carries 150 mm — SWAP (AC508-080-B-ML). Beam 18.5 mm |
| Periscope | 100 → 200 mm | as on the bench; the 200 sits INSIDE the periscope and is shared with 3D-SHOT — never treated as swappable |
| PBS | — | joins the imaging path, no power |
| Tube lens | **Nikon 200 mm (ITL200-class)** | [USER 2026-08-05] Not the Olympus 180 mm on the camera path — this arm passes the Nikon. Alternate candidate: Pacific Optica Ventana TL (same 200 mm, published Ø20 mm pupil / ±5° acceptance, AR 780–1350 nm) [VEN 2026-08-10] |
| Objective | Nikon CFI Plan Apo Lambda D 10X/0.45 (dry) | EFL 20.0 mm — the large-field configuration; the Nikon 16×/0.8 (design of record on the MOM) is a different solve, not this build rescaled |

**Layout**, DMD to the f7 lens — 2.16 m of new table:

```
DMD --80-- L1a --480-- L1b --400-- GRATING --250-- Ra --450-- Rb --200-- I0 --300-- f7 --300-- SLM --80-- f6 --80-- I1 -> periscope -> PBS -> tube -> objective
```

### How the scale is built

```
M1     = f_L1b / f_L1a                     = 400 / 80   = 5.0000
m_x    = f_Rb  / f_Ra                      = 200 / 250  = 0.8000
m_i0_s = (f6/f7) * (peri2/peri1) * (EFL_obj/f_tube)
       = (80/300) * (200/100) * (20.0/200) = 0.05333

M_gs   = 1 / (m_x * m_i0_s)                                = 23.437   (grating -> sample demag)
groove-axis scale     = pitch * M1 / M_gs                  = 2.3040 µm/px
dispersion-axis scale = that * cos(beta)/cos(alpha)        = 2.6528 µm/px
```

### What invalidates the calibration

Each scales the µm-per-pixel numbers in §5 directly. Swap any one and multiply.

| Change | Effect on µm/px |
|---|---|
| f_L1a (80 mm) | ∝ 1 / f_L1a |
| f_L1b (400 mm) | ∝ f_L1b |
| f_Ra (250 mm) | ∝ 1 / f_Ra |
| f_Rb (200 mm) | ∝ f_Rb |
| f7 (300 mm) | ∝ 1 / f7 |
| f6 (80 mm) | ∝ f6 |
| periscope lenses | ∝ peri2 / peri1 |
| tube lens | ∝ 1 / f_tube |
| objective | ∝ EFL_obj |
| grating incidence angle | changes the **dispersion axis only**, via cos(beta)/cos(alpha) |

The grating is the odd one out: it does not touch the groove-axis scale at
all, but it sets the 1.1514× anisotropy **and** the depth tilt in
§6. A grating remounted at a different angle changes both. The SLM does not
appear in this table at all — it sits at a **pupil**, so its phase moves focus
(§6), never the lateral scale.

## 4. The usable patch

The illumination is a raw Gaussian (no πShaper), so only the middle of the
chip is used. **Write nothing outside the patch** — mirrors outside it must be
OFF.

| | |
|---|---|
| Design patch | **Ø5.0 mm = 463 px diameter**, centred |
| Illumination on chip | Ø7.0 mm 1/e² Gaussian (1.75× expander, not a catalogue GBE — see §3) |
| Resulting field | **1067 × 1228 µm** ellipse at the sample |

Every buildability gate (lens apertures, grating ruling, SLM fill) was checked
**at this patch diameter**; the trade study swept Ø4.0 mm as the only smaller
alternative. Nothing larger is verified — a bigger patch is a new sweep, not a
bigger bitmap.

A **square** patch is a bad idea and a bigger one than it looks: written in
row/column coordinates its *diagonal* is what the grating sees, so a square
presents √2 of its side to the grating and the SLM fill. Prefer a disc, or an
ellipse (see §5).

## 5. Coordinate mapping

Let `(dc, dr)` be a pixel offset from the patch centre, in DMD columns and
rows. The optical axes are the chip diagonals:

```
d_disp   = (dc + dr) / sqrt(2)      # along the grating's dispersion axis
d_groove = (dc - dr) / sqrt(2)      # along the grooves
```

Then at the sample, in µm:

```
x_disp   = d_disp   * 2.6528     # µm per pixel, DISPERSION axis
y_groove = d_groove * 2.3040     # µm per pixel, GROOVE axis
```

| Axis | Magnification | µm per DMD pixel |
|---|---|---|
| Groove | 0.213333 | **2.3040** |
| Dispersion | 0.245629 | **2.6528** |

Inverse: `dc = (x_disp/2.6528 + y_groove/2.3040)/sqrt(2)`,
`dr = (x_disp/2.6528 - y_groove/2.3040)/sqrt(2)`.

**To place a round spot at the sample**, draw an ellipse on the DMD compressed
by 1.1514× along the `(1, 1)` diagonal. Drawing a circle in pixels
gives a sample spot 1.15× longer along the dispersion axis.

**Sign conventions are NOT specified here.** Which diagonal is `+disp`, and
which way `x_disp` runs at the sample, depend on how the grating and the folds
are actually installed. Determine both on the bench with a two-point
calibration; the magnitudes above are what should be recovered. One DMD pixel
is 5.2 per 12 µm target, so the
fit has real resolution to work with.

## 6. Depth: a tilted plane the SLM can now chase

The excitation surface is a plane tilted along the dispersion axis — that is
unchanged physics. What changed: **there is a phase modulator at the pupil**,
so the control software can refocus onto it, per target group.

| | |
|---|---|
| Surface tilt | 1.628°, entirely along the **dispersion** axis |
| Depth gradient | **0.02843 µm of depth per µm** across the field |
| ... per DMD pixel | 0.07542 µm per pixel along the `(1, 1)` diagonal |
| Total walk across the patch | **34.9 µm** peak-to-peak |
| Axial FWHM | **33.2 µm**, at a 12 µm target |
| SLM remote focus, 80% blaze | **±908 µm = 52× the walk half-range** |
| Walk correction phase cost | 1.25 wrapped waves across the pupil |

So `z_um ≈ x_disp * 0.02843` (sign from calibration), and the correction
the SLM writes is the defocus that cancels it at the targets being stimulated.
**A pupil phase is field-independent: it refocuses the whole field at once, so
it corrects the walk SEQUENTIALLY — group targets by depth, write the group's
defocus, stimulate, move on.** It can never flatten the tilted plane in a
single frame. The walk is 1.1× the axial FWHM across the
full field, so two targets at opposite edges are **not in the same plane**
without a group refocus between them — worth surfacing in the UI. Objective
field curvature contributes 1.37 µm here and is negligible.

**Timing the correction (control-software rules):**

* Meadowlark (pinned): LC response 3.4 ms — budget it
  between depth groups; no load blanking.
* TI PLM (alternate): mirrors revert toward flat for
  ~100 µs during **every** data load
  (14% duty at its 1400 Hz cap) — the whole
  field snaps back to the native plane during that window, so **gate the DMD
  (all mirrors OFF) while the PLM loads**.

**The zero-order ghost, and the block that must come OUT.** The SLM's
unmodulated fraction images the full field at the native plane when a defocus
is commanded — two-photon contrast 2.8e-03 relative
to the refocused image. Unlike 3D-SHOT's focused DC spot, this ghost is a
full-field image: a separating tilt carrier would need
0.80 px/fringe (< 2 = unwritable), so the ghost is
**accepted, not blocked — and the 3D-SHOT zero-order block parked at I1 must
be REMOVED**, because where it sits it shadows the middle of the merged field.

**Where that FWHM comes from, because the number has changed meaning.** It is
interpolated from a **scalar-diffraction table** over the (target, spectral
NA, objective NA) grid — 33.2 µm at this build's NA_spectral
0.162 and groove-resolution factor η = 1.00. Earlier
revisions quoted `physics.axial_fwhm_um`, a scaling law tagged `[LOW ±40%]`
which for this build says 24.4 µm; it runs low against the
field calculation and is now used only to prune sweeps, never to quote.

## 7. Power, and the real hazards

### 7a. Air breakdown at the DMD relay's pupil

**Every 4f relay of a collimated DMD forms a real focus at its pupil.** With a
*uniform* ON patch the whole pulse lands in one ~33 µm
spot in air there. At the full 400 µJ the CARBIDE delivers at
100 kHz that is 2.3e+14 W/cm² —
**5× over** the ~5e+13 W/cm² where air ionises for a
205 fs pulse.

* **Keep the pulse energy under ~89 µJ**
  (8.9 W at
  100 kHz) whenever a large fraction of the patch is ON.
* Raise the **rep rate**, never the pulse energy — minding the CARBIDE's
  denied bands (255–258, 342–346, 500–528, 570–580, 765–783 kHz, §2).
* **Sparse patterns are far safer**: the pupil peak scales with the square of
  the pattern's mean, so a few-percent fill is orders of magnitude below a
  full-field frame. The dangerous case is precisely the all-ON alignment
  pattern.

**Why this plane and not a later one.** L1a's pupil sits *upstream of the
grating*, so the full bandwidth arrives at one spot there. Every pupil after
the grating — Ra's, f7's, the SLM itself — has the spectrum smeared into a
line, and at any point on that line only a slice of the bandwidth is present,
so the local pulse is transform-limited to a duration
~192× longer (grooves lit by the patch over twice the
grooves needed to resolve the pulse; the focal length cancels, so the factor
is identical at every post-grating pupil). Peak intensity there falls as 1/L²,
not 1/L. So the interlock is set upstream of the grating, and **no lens change
after the grating moves it** — swapping Ra, Rb, f7 or f6 re-scales the field,
not the hazard.

### THE RULE FOR THE CONTROL SOFTWARE: never illuminate more than 50% of the chip

**Cap the ON fraction at 50%.** [USER 2026-07-28] The chip is never run
anywhere near full-on in practice, and this makes that a property of the
software rather than of operator discipline.

Why 50% is the right number, and why it is sufficient rather than arbitrary.
For a contiguous ON region the pupil intensity scales as the SQUARE of the ON
fraction — power rises with the lit area while the DC spot AREA falls as its
inverse — so:

| ON fraction | relative pupil intensity | at the 8.5 W operating point | vs the 5e+13 W/cm² threshold |
|---|---|---|---|
| 100% (alignment) | 1.00× | 4.8e+13 W/cm² | 1× under |
| 70% | 0.49× | 2.4e+13 W/cm² | 2× under |
| **50%** | **0.25×** | **1.2e+13 W/cm²** | **4× under** |
| 10% | 0.01× | 4.8e+11 W/cm² | 104× under |

A 50% cap buys **4× against the all-ON frame** — that factor is structural,
since the intensity goes as the square of the fraction. **The cap exists
because the laser knob is independent of the pattern**: run the same all-ON
frame at the laser's full 40 W and the pupil sees
2.3e+14 W/cm², 5× over — so the cap must hold
at any power the operator dials, not just the operating point.

**Implementation notes.** Count ON mirrors over the WHOLE chip and refuse to
load a frame above the cap — one comparison per frame, not per target. The cap
is conservative for sparse patterns and tight for solid ones: the quantity
that actually concentrates light is the largest CONTIGUOUS ON region, not the
total. A frame that is 50% ON as scattered cell-sized targets is orders of
magnitude safer than one that is 50% ON as a single filled block. If a solid
alignment target is ever wanted, keep it under 50% AND drop the laser power.

Routine operation is inside this bound, but not far inside it: holding
1 µW/µm² at the *field edge* with everything on needs **8.5 W**
of laser (end to end 18.2%), which at 100 kHz is
**85 µJ per pulse against the ~89 µJ
ceiling — a 1.04× margin**, i.e. 100 kHz usable, 1.04× margin at the relay pupil. Whole-field-at-once is the
worst case and not how the instrument is used, but it is close enough that the
interlock is worth having rather than optional.

> **Open flag — the ~89 µJ ceiling is
> conservative, and nobody has measured by how much.** The DMD is itself a
> blazed grating (`physics.dmd_blaze`, tagged `[LOW]`), and its own dispersion
> would smear the relay-pupil spot the same way the TF grating does
> downstream, plausibly raising this ceiling by more than an order of
> magnitude. Deliberately NOT folded in: trading a conservative bound for an
> unverified one is the wrong direction on a safety interlock.

### 7b. The SLM's liquid crystal — the alignment cap

3D-SHOT's rotating diffuser used to spread the light across the SLM. The
merge deletes it, and the SLM sits at a **Fourier plane of the DMD pattern**:
how concentrated the light is on the LC depends on what the DMD displays.

* **All-ON / uniform patch (the alignment state): the hazard.** Every
  colour's uniform disc focuses to a diffraction-limited core sheared into a
  spectral **line** of ~0.1 mm² on the LC.
  Against the 30 W/cm² ceiling
  ([USER 2026-08-08] survived floor: 12-18 W incident, 30-45 W/cm^2 peak, undamaged in 3D-SHOT operation; true threshold unknown), that means: **cap alignment power at
  42 mW at the grating arm whenever the pattern is all-ON or
  near-uniform.**
* **Sparse operating patterns: benign.** One 12 µm target's
  light spreads over ~2.8 mm on the LC, and
  targets overlap incoherently. At 1 µW/µm² the field fills with somata
  (~1098 targets/plane) before the LC
  ceiling binds.

### 7c. The grating

3.7 W/cm² at the FULL 40 W laser —
75× under the 280 W/cm² that has actually burned
the 3D-SHOT grating [USER 2026-08-08]. Not a software rule; recorded so the
number that IS the anchor travels with the caps derived from it.

## 8. Illumination non-uniformity, and how to correct it

No πShaper, so the patch sits inside a Gaussian. As a function of radius in
pixels from the patch centre:

```
I(r) / I0 = exp(-2 * r_px**2 / 324.1**2)
```

| r (px) | Relative intensity |
|---|---|
| 0 | 1.00 |
| 116 | 0.77 |
| 231 (patch edge) | **0.36** |

**Correct it in time, not in optics — and the correction is 1/I², not 1/I.**
The DMD is binary at 12,500 Hz, so per-target dose
is set by how many 80 µs frames the target is ON. Two-photon
excitation goes as I², so equal 2p dose needs each target's dwell scaled by
`1 / I(r)**2`:

| | at patch centre | at patch edge |
|---|---|---|
| Relative intensity I | 1.000 | 0.3604 |
| 2p signal ∝ I² | 1.000 | 0.1299 |
| **Dwell correction 1/I²** | 1.000 | **7.70×** |
| ~~1/I (wrong)~~ | ~~1.000~~ | ~~2.77×~~ |

> **Corrected since rev 3.** rev 3 and
> every revision before it said `1/I`, i.e. 2.77× at the patch edge
> instead of 7.70×. A 1/I correction flattens the
> *illumination* but not the *excitation* — it leaves an edge target at
> 36% of its intended two-photon dose, a smooth centre-bright gradient
> that reads as a real biological effect, not as a calibration error.

Budget for it: a target at the edge needs 7.70× the dwell of
one at centre for the same dose — size a stimulation epoch by the worst case,
not the mean.

## 9. Do not hard-code these

Every number above is **design intent**, not calibration. In particular:

* **The lens swaps are the open item with the most leverage.**
  The scale below assumes 2 lens swaps that have not happened yet: f7 (Fourier) 500 -> 300 mm; f6 (SLM relay) 150 -> 80 mm [vs the bench of record, USER 2026-08-08]. Until they do, the merged arm does not exist at these numbers — and a calibration fitted against today's unswapped back end would measure 1.1250× the µm-per-pixel figures in §5 (not a calibration error, a different instrument). Confirm the swaps before trusting any expected value here.
* **f6 has a documented ambiguity**: the bench reading of 150 mm
  [USER 2026-08-08, unconfirmed] may actually be Mardinly's 300 mm (setup
  2/3). It does not change this build — f6 is replaced either way — but a
  ten-minute bench check settles it before ordering.
* The anamorphic factor follows from the grating's installed incidence angle;
  a degree of mounting error moves it.
* The laser's 1038 nm is a **measured** central wavelength
  [CERT s/n C264570], not the 1030 nm setpoint the front panel reads. Every
  grating angle derives from it. (The current rig's FS-50 numbers are a
  different laser on a different build — see "Which build", above.)
* The chip Scheimpflug tilt is 7.6° and **its
  sign is OPPOSITE the bring-up arm's instructions** — the merged chain adds
  a fourth inverting relay. Getting it backwards DOUBLES the pattern/pulse
  split instead of removing it. An installation fact rather than a software
  constant, but it decides whether §6's numbers are real.

**The control code should fit its own affine map** (scale, rotation, shear,
offset) from a measured calibration grid, and use §5 only as the expected
starting point and a sanity check. If the fitted scale disagrees with
2.3040 / 2.6528 µm per pixel by more than a few percent,
something is installed differently from this document — §3 lists the
suspects.

---

## Appendix — machine-readable constants

Parsed by `tfp.util.readHandoffConstants` and asserted against the control
repo's hardware classes by `tests/test_optics_handoff_constants.m`. Flat
`key: value` lines; `#` starts a comment. Keys in the *merged-arm design
intent* group are void until that build exists (see "Which build", above);
the *device geometry* group is build-independent fact.

```handoff-constants
handoff_rev: 5
handoff_rev_date: 2026-08-19
generator_commit: 1216736
build: merged_arm
build_label: 5.0mm Ra/Rb 250/200 f7 300 f6 80 p1 100

# -- device geometry: build-independent [DS] facts --
dmd_part: DLP650LNIR
dmd_cols: 1280
dmd_rows: 800
dmd_pitch_um: 10.8
dmd_mirror_tilt_deg: 12.0
dmd_binary_rate_hz: 12500
plm_cols: 904
plm_rows: 800
plm_pitch_disp_um: 16.2
plm_pitch_cross_um: 10.8
plm_phase_states: 32
plm_max_update_hz: 1400
plm_load_blank_us: 100
slm_cols: 1024
slm_rows: 1024
slm_pitch_um: 17.0
slm_max_frame_hz: 1436

# -- merged-arm design intent: void for any other build --
wavelength_nm: 1038.0
pulse_fwhm_fs: 205.0
rep_rate_khz: 100.0
denied_rep_rate_khz: 255-258, 342-346, 500-528, 570-580, 765-783
patch_diameter_mm: 5.0
patch_diameter_px: 463
um_per_px_groove: 2.3040
um_per_px_disp: 2.6528
anamorphic: 1.1514
axis_rotation_deg: 45
depth_gradient_um_per_um: 0.02843
axial_fwhm_um: 33.2
walk_um: 34.9
remote_focus_um: 908
dwell_exponent: 2
patch_edge_intensity: 0.3604
dwell_correction_edge: 7.70
safe_pulse_energy_uJ: 89

# -- safety caps the control software enforces --
on_fraction_cap: 0.50
slm_alignment_cap_mW: 42
```

---

*Optical design, the trade study that produced it, and the model live in the
`TF optics simulator` repo: `docs/merged_arm.md`,
`python -m configs.merged_arm`, `python -m configs.merged_arm_verify`.
Regenerate this file with `python -m configs.dmd_handoff` there.*
