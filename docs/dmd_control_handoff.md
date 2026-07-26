# DMD control — optical handoff spec

**Generated** from the optical model by `python -m configs.dmd_handoff` in the
`TF optics simulator` repo. Regenerate rather than edit. Build:
`33010FL01-530R 6.0mm 80/300 150/80`.

> **%CORRECTION — manual annotation, remove on regeneration (2026-07-26).**
> §7 says the CARBIDE delivers 800 µJ at 100 kHz and quotes "80 W available".
> **The laser is 40 W** (confirmed with Hillel); 80 W is an error in the
> generator and needs fixing upstream in the `TF optics simulator` repo
> (TASKS.md T-BU-M6). Max pulse energy at 100 kHz is therefore **400 µJ**, not
> 800 µJ, and the routine-operation quote is ~2.83 W out of 40 W (~7%).
> **The ~68 µJ interlock threshold is unaffected** — it is an air-ionization
> limit at the pupil, set by the optics and the 230 fs pulse, not by the
> laser's rated power. Full-field ON still exceeds it by ~5.9×.
> Control code takes laser numbers from `configs/real.yaml`, never from §7.

This describes the **bring-up** temporal-focusing photostimulation arm: no PLM,
no πShaper, CARBIDE 1030 nm → DMD → 4f → grating → 4f → existing 3D-SHOT
periscope / PBS / Olympus 180 mm tube / Nikon CFI75 LWD 16×/0.8 W.

---

## 1. The three things that will bite you

**The chip is mounted clocked 45° about its own normal.** Not square to the
bench. The DLP650LNIR's mirrors hinge about the chip's 45° diagonal, and
clocking is what lays that diagonal in the table plane so the illumination and
the grating both stay flat. Consequence: **every sample↔DMD coordinate transform
carries a 45° rotation**, and the optical axes of interest run along the chip's
*diagonals*, not its rows and columns.

**The sample-plane scale is anisotropic**, 1.2588× — and the
anisotropy is along the chip **diagonal**, because that is where the grating
disperses. A circle drawn in DMD pixels lands as an **ellipse** at the sample.

**A uniform all-ON pattern at full laser power is a hardware hazard**, not just
a bad idea. See §7.

---

## 2. Device

| | |
|---|---|
| Part | TI DLP650LNIR |
| Array | 1280 × 800 |
| Pitch | 10.8 µm |
| Active area | 13.824 × 8.640 mm |
| Mirror tilt | ±12°, hinge on the 45° diagonal |
| Binary frame rate | 12,500 Hz → **80 µs** per binary frame |
| Illumination incidence | 23.87° off the chip normal, in the plane of the blaze diagonal |

## 3. The optical train that produces these numbers

Every constant in §5 and §6 falls out of this chain. It is here so that when
someone swaps a lens, it is obvious that the control code's calibration is now
stale — the failure is otherwise silent.

**New optics** (bought for this arm; both relays are 4f, so the spacings are
forced by the focal lengths and are not adjustable):

| # | Element | Part | f (mm) | Ø | Beam there | Role |
|---|---|---|---|---|---|---|
| 1 | L1a | AC254-080-B-ML | 80 | 1″ | 13.6 mm | DMD relay, first. Its length also sets the illumination clearance past its own barrel |
| 2 | L1b | ACT508-300-B-ML | 300 | 2″ | 30.1 mm | DMD relay, second. **M1 = 3.75×** |
| 3 | TF grating | Newport 33010FL01-530R | — | 50 × 50 mm | 32.9 × 22.5 mm lit | 1200 g/mm, 1000 nm blaze. **In 46.8°, out 30.5°** — sets the anamorphic factor and the depth tilt |
| 4 | La | AC508-150-B-ML | 150 | 2″ | 33.6 mm | Front relay, first |
| 5 | Lb | AC508-080-B-ML | 80 | 2″ | 20.3 mm | Front relay, second. **1.88× demag** |

Plus a Ø12 mm GBE03-B Galilean expander, a λ/2 + polarizer
(the grating runs 79% in s-pol against 50% in p, so this is not optional),
and UM20-45B / UM10-45B fold flats.

**Layout**, DMD to the periscope input image plane — 1.22 m total:

```
DMD --80-- L1a --380-- L1b --300-- GRATING --150-- La --230-- Lb --80--> periscope
```

**Already on the microscope** (not bought, and the source of most of the risk in
these numbers — see §9):

| Element | Value | Note |
|---|---|---|
| Periscope 4f | 200 → 150 mm | **which lens is first is UNCONFIRMED** |
| PBS | — | joins the imaging path, no power |
| Tube lens | Olympus 180 mm | measured, re-confirm |
| Objective | Nikon CFI75 LWD 16×/0.8 W | EFL 12.5 mm, FN 22, T ≈ 69% at 1030 nm |

### How the scale is built

```
M1     = f_L1b / f_L1a                     = 300 / 80   = 3.7500
m_front= f_Lb  / f_La                      = 80 / 150  = 0.5333
m_peri = f_peri2 / f_peri1                 = 150 / 200 = 0.7500
m_back = EFL_obj / f_tube                  = 12.5 / 180 = 0.06944

M_gs   = 1 / (m_front * m_peri * m_back)                   = 36.000
groove-axis scale     = pitch * M1 / M_gs                  = 1.1250 µm/px
dispersion-axis scale = that * cos(beta)/cos(alpha)        = 1.4162 µm/px
```

### What invalidates the calibration

Each scales the µm-per-pixel numbers in §5 directly. Swap any one and multiply.

| Change | Effect on µm/px |
|---|---|
| f_L1a (80 mm) | ∝ 1 / f_L1a |
| f_L1b (300 mm) | ∝ f_L1b |
| f_La (150 mm) | ∝ 1 / f_La |
| f_Lb (80 mm) | ∝ f_Lb |
| periscope, if reversed | **× 1.778** |
| tube lens | ∝ 1 / f_tube |
| objective | ∝ EFL_obj |
| grating incidence angle | changes the **dispersion axis only**, via cos(beta)/cos(alpha) |

The grating is the odd one out: it does not touch the groove-axis scale at all,
but it sets the 1.2588× anisotropy **and** the depth tilt in §6. A
grating remounted at a different angle changes both.

## 4. The usable patch

The illumination is a raw Gaussian (no πShaper), so only the middle of the chip
is used. **Write nothing outside the patch** — mirrors outside it must be OFF.

| | |
|---|---|
| Design patch | **Ø6.0 mm = 556 px diameter**, centred |
| **Hard maximum** | **Ø7.12 mm = 659 px** — beyond this the beam clips lens La and the grating ruling |
| Illumination on chip | Ø12.0 mm 1/e² Gaussian (GBE03-B expander) |
| Resulting field | **625 × 787 µm** ellipse at the sample |

A **square** patch is a bad idea and a bigger one than it looks: written in
row/column coordinates its *diagonal* is what the grating sees, so an 8 mm
square presents 11.31 mm and overruns both the grating blank and La. Prefer a
disc, or an ellipse (see §5).

## 5. Coordinate mapping

Let `(dc, dr)` be a pixel offset from the patch centre, in DMD columns and rows.
The optical axes are the chip diagonals:

```
d_disp   = (dc + dr) / sqrt(2)      # along the grating's dispersion axis
d_groove = (dc - dr) / sqrt(2)      # along the grooves
```

Then at the sample, in µm:

```
x_disp   = d_disp   * 1.4162     # µm per pixel, DISPERSION axis
y_groove = d_groove * 1.1250     # µm per pixel, GROOVE axis
```

| Axis | Magnification | µm per DMD pixel |
|---|---|---|
| Groove | 0.104167 | **1.1250** |
| Dispersion | 0.131129 | **1.4162** |

Inverse: `dc = (x_disp/1.4162 + y_groove/1.1250)/sqrt(2)`,
`dr = (x_disp/1.4162 - y_groove/1.1250)/sqrt(2)`.

**To place a round spot at the sample**, draw an ellipse on the DMD compressed
by 1.2588× along the `(1, 1)` diagonal. Drawing a circle in pixels
gives a sample spot 1.26× longer along the dispersion axis.

**Sign conventions are NOT specified here.** Which diagonal is `+disp`, and
which way `x_disp` runs at the sample, depend on how the grating and the folds
are actually installed. Determine both on the bench with a two-point
calibration; the magnitudes above are what should be recovered.

## 6. Depth: the field is a tilted plane

There is **no PLM in this build**, so the excitation surface tilt cannot be
corrected — but it is deterministic and the control code should report it.

| | |
|---|---|
| Surface tilt | 1.245°, entirely along the **dispersion** axis |
| Depth gradient | **0.02174 µm of depth per µm** across the field |
| ... per DMD pixel | 0.03079 µm per pixel along the `(1, 1)` diagonal |
| Total across the patch | **17.1 µm** |
| Axial FWHM | **17.7 µm** `[LOW ±40%]` |

So `z_um ≈ x_disp * 0.02174` (sign from calibration). The walk is comparable
to one axial FWHM across the full field, so a target at one edge and a target at
the other are **not in the same plane** — worth surfacing in the UI rather than
hiding. There is no groove-axis component; objective field curvature contributes
0.56 µm and is negligible here.

## 7. Power, and the one real hazard

**Every 4f relay of a collimated DMD forms a real focus at its pupil.** With a
*uniform* ON patch the whole pulse lands in one ~27 µm
spot in air there. At the full 800 µJ
the CARBIDE delivers at 100 kHz that is
5.9e+14 W/cm², above where air ionises for a
230 fs pulse.

* **Keep the pulse energy under ~68 µJ**
  (6.8 W at
  100 kHz) whenever a large fraction of the patch is ON.
* Raise the **rep rate**, never the pulse energy.
* **Sparse patterns are far safer**: the pupil peak scales with the square of the
  pattern's mean, so a few-percent fill is orders of magnitude below a full-field
  frame. The dangerous case is precisely the all-ON alignment pattern.
* A sensible interlock: refuse, or require an explicit override, for patterns
  with high fill fraction above a configured pulse energy.

Routine operation is nowhere near this: holding 1 µW/µm² over the *whole* field
at once needs **2.83 W** of the 80 W
available, end to end 10.8%.

## 8. Illumination non-uniformity, and how to correct it

No πShaper, so the patch sits inside a Gaussian. As a function of radius in
pixels from the patch centre:

```
I(r) / I0 = exp(-2 * r_px**2 / 555.6**2)
```

| r (px) | Relative intensity |
|---|---|
| 0 | 1.00 |
| 139 | 0.88 |
| 278 (patch edge) | **0.61** |

**Correct it in time, not in optics.** The DMD is binary at
12,500 Hz, so per-target dose is set by how many
80 µs frames the target is ON. Scale each target's dwell by
`1 / I(r)`; the worst-case correction at the patch edge is
**1.65×**. Budget for it: a target at the edge needs
1.65× the dwell of one at centre for the same dose.

This is also why the patch is a disc rather than a square — a square's corners
sit at √2 further out, where the Gaussian has fallen to
0.37 of centre.

## 9. Do not hard-code these

Every number above is **design intent**, not calibration. In particular:

* The periscope on the scope is a 200/150 pair and **which lens the beam meets
  first has not been confirmed**. If it is reversed, M_gs changes by 1.78× —
  so the µm-per-pixel figures in §5 change by the same factor.
* The 180 mm Olympus tube lens is measured but should be re-confirmed.
* The anamorphic factor follows from the grating's installed incidence angle; a
  degree of mounting error moves it.

**The control code should fit its own affine map** (scale, rotation, shear,
offset) from a measured calibration grid, and use §5 only as the expected
starting point and a sanity check. If the fitted scale disagrees with
1.1250 / 1.4162 µm per pixel by more than a few percent,
something is installed differently from this document.

---

*Optical design, the sweep that produced it, and the independent ray-trace check
live in the `TF optics simulator` repo: `docs/bringup_design.md`,
`python -m configs.bringup`, `python -m configs.bringup_verify`.*
