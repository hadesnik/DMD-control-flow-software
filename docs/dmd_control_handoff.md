# DMD control — optical handoff spec

**Generated** from the optical model by `python -m configs.dmd_handoff` in the
`TF optics simulator` repo. Regenerate rather than edit. Build:
`33010FL01-530R 3.5mm 50/400 250/60`.

This describes the **bring-up** temporal-focusing photostimulation arm: no PLM,
no πShaper, CARBIDE 1030 nm → DMD → 4f → grating → 4f → existing 3D-SHOT
periscope / PBS / Olympus 180 mm tube / Nikon CFI75 LWD 16×/0.8 W.

---

## 0. What changed since rev 2 — 2026-07-26 — read this first

**The scale constants moved by +54% and +40%.** If your calibration or any
test fixture carries the previous µm-per-pixel figures, they are wrong now — and
the two axes did **not** move together, so a single scalar correction will not
rescue them.

**One cause, and it is the one this document has warned about since rev 1: the
periscope order was measured.** The beam meets the
150 mm lens first, not the 200 mm, so the periscope
*magnifies* by 1.333× where every previous revision assumed it demagnified
by 0.750×. That is a factor of 1.78 in M_gs, and it re-picked the
optimum lens set underneath it. Nothing about the laser changed from rev 2.

| | rev 2 — 2026-07-26 | **this revision** |
|---|---|---|
| Laser | CARBIDE CB3-40W, 200 fs, 9.00 nm (specified) | **CARBIDE CB3-40W, 200 fs, 9.00 nm (specified)** — unchanged |
| **Periscope** | 200 → 150 mm, order **ASSUMED**, 0.75× (demagnifying) | **150 → 200 mm, order MEASURED 2026-07-27, 1.333× (magnifying)** |
| Lenses | L1a 60 / L1b 250 / La 150 / Lb 80 | **L1a 50 / L1b 400 / La 250 / Lb 60** |
| Field | 694 × 882 µm | **622 × 719 µm** |
| **µm/px, groove axis** | 1.2500 | **1.9200** |
| **µm/px, dispersion axis** | 1.5871 | **2.2193** |
| Anamorphic factor | 1.2697 | **1.1559** |
| Axial FWHM | 11.0 µm | **7.1 µm** |
| Depth walk (peak-to-peak) | 19.0 µm | **13.9 µm** |
| Depth gradient dz/dx | 0.02152 | **0.01929** |
| DMD patch | Ø6 mm / 556 px | **Ø4 mm / 324 px** |
| Illumination on chip | Ø12.00 mm (3× expander) | **Ø12.0 mm (3× expander)** |
| Patch edge intensity | 0.61 | **0.84** |
| Safe pulse energy | 33 µJ | **68 µJ** |
| Rep rate | ≥200 kHz required — 100 kHz sat above air breakdown | **≥104 kHz REQUIRED — see §7** |
| Depth walk status | cancelled by the sample tilt stage — see §6 | **cancelled by the sample tilt stage — see §6** — unchanged |

**The DMD patch has CHANGED — Ø6 mm → Ø4 mm, 556 px → 324 px.** Any fixture that writes a patch-sized bitmap needs regenerating.

**The 45° clocking and the coordinate-transform *structure* are unchanged.**
Every equation in §3 and §4 still holds as written; it is the numbers fed into
them that moved.

**What this means for the control code:**

* **Refit the scale.** Both µm-per-pixel constants changed, by different amounts,
  because the anamorphic factor moved too (1.2697 → 1.1559). §5 has the new
  pair; §9 says why you should fit rather than paste them.
* **Regenerate any patch-sized bitmap.** The patch went Ø6 mm → Ø4 mm,
  so a fixture that hard-codes 556 px across will now overfill the disc the
  optics actually pass.
* **The pupil hazard eased but did not go away.** rev 2 needed ≥200 kHz; at the
  new magnification the working point sits at 0.96× margin at 100 kHz. That is
  headroom, not comfort — §7 still governs, and the all-ON alignment pattern is
  still the dangerous case.

---

## 1. The three things that will bite you

**The chip is mounted clocked 45° about its own normal.** Not square to the
bench. The DLP650LNIR's mirrors hinge about the chip's 45° diagonal, and
clocking is what lays that diagonal in the table plane so the illumination and
the grating both stay flat. Consequence: **every sample↔DMD coordinate transform
carries a 45° rotation**, and the optical axes of interest run along the chip's
*diagonals*, not its rows and columns.

**The sample-plane scale is anisotropic**, 1.1559× — and the
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
| 1 | L1a | AC254-050-B-ML | 50 | 1″ | 8.3 mm | DMD relay, first. Its length also sets the illumination clearance past its own barrel |
| 2 | L1b | ACT508-400-B-ML | 400 | 2″ | 32.8 mm | DMD relay, second. **M1 = 8.00×** |
| 3 | TF grating | Newport 33010FL01-530R | — | 50 × 50 mm | 38.7 × 28.0 mm lit | 1200 g/mm, 1000 nm blaze. **In 43.6°, out 33.1°** — sets the anamorphic factor and the depth tilt |
| 4 | La | ACT508-250-B-ML | 250 | 2″ | 38.6 mm | Front relay, first |
| 5 | Lb | AC508-060-B-ML | 60 | 2″ | 14.0 mm | Front relay, second. **4.17× demag** |

Plus a Ø12 mm GBE03-B Galilean expander, a λ/2 + polarizer
(the grating runs 79% in s-pol against 50% in p, so this is not optional),
and UM20-45B / UM10-45B fold flats.

**Layout**, DMD to the periscope input image plane — 1.52 m total:

```
DMD --50-- L1a --450-- L1b --400-- GRATING --250-- La --310-- Lb --60--> periscope
```

**Already on the microscope** (not bought, and the source of most of the risk in
these numbers — see §9):

| Element | Value | Note |
|---|---|---|
| Periscope 4f | 150 → 200 mm | order **measured on the bench 2026-07-27** — the 150 mm is first, so it magnifies by 1.333× |
| PBS | — | joins the imaging path, no power |
| Tube lens | Olympus 180 mm | measured, re-confirm |
| Objective | Nikon CFI75 LWD 16×/0.8 W | EFL 12.5 mm, FN 22, T ≈ 69% at 1030 nm |

### How the scale is built

```
M1     = f_L1b / f_L1a                     = 400 / 50   = 8.0000
m_front= f_Lb  / f_La                      = 60 / 250  = 0.2400
m_peri = f_peri2 / f_peri1                 = 200 / 150 = 1.3333
m_back = EFL_obj / f_tube                  = 12.5 / 180 = 0.06944

M_gs   = 1 / (m_front * m_peri * m_back)                   = 45.000
groove-axis scale     = pitch * M1 / M_gs                  = 1.9200 µm/px
dispersion-axis scale = that * cos(beta)/cos(alpha)        = 2.2193 µm/px
```

### What invalidates the calibration

Each scales the µm-per-pixel numbers in §5 directly. Swap any one and multiply.

| Change | Effect on µm/px |
|---|---|
| f_L1a (50 mm) | ∝ 1 / f_L1a |
| f_L1b (400 mm) | ∝ f_L1b |
| f_La (250 mm) | ∝ 1 / f_La |
| f_Lb (60 mm) | ∝ f_Lb |
| periscope, if reversed | **× 0.562** |
| tube lens | ∝ 1 / f_tube |
| objective | ∝ EFL_obj |
| grating incidence angle | changes the **dispersion axis only**, via cos(beta)/cos(alpha) |

The grating is the odd one out: it does not touch the groove-axis scale at all,
but it sets the 1.1559× anisotropy **and** the depth tilt in §6. A
grating remounted at a different angle changes both.

## 4. The usable patch

The illumination is a raw Gaussian (no πShaper), so only the middle of the chip
is used. **Write nothing outside the patch** — mirrors outside it must be OFF.

| | |
|---|---|
| Design patch | **Ø3.5 mm = 324 px diameter**, centred |
| **Hard maximum** | **Ø7.12 mm = 659 px** — beyond this the beam clips lens La and the grating ruling |
| Illumination on chip | Ø12.0 mm 1/e² Gaussian (GBE03-B expander) |
| Resulting field | **622 × 719 µm** ellipse at the sample |

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
x_disp   = d_disp   * 2.2193     # µm per pixel, DISPERSION axis
y_groove = d_groove * 1.9200     # µm per pixel, GROOVE axis
```

| Axis | Magnification | µm per DMD pixel |
|---|---|---|
| Groove | 0.177778 | **1.9200** |
| Dispersion | 0.205494 | **2.2193** |

Inverse: `dc = (x_disp/2.2193 + y_groove/1.9200)/sqrt(2)`,
`dr = (x_disp/2.2193 - y_groove/1.9200)/sqrt(2)`.

**To place a round spot at the sample**, draw an ellipse on the DMD compressed
by 1.1559× along the `(1, 1)` diagonal. Drawing a circle in pixels
gives a sample spot 1.16× longer along the dispersion axis.

**Sign conventions are NOT specified here.** Which diagonal is `+disp`, and
which way `x_disp` runs at the sample, depend on how the grating and the folds
are actually installed. Determine both on the bench with a two-point
calibration; the magnitudes above are what should be recovered.

## 6. Depth: the field is a tilted plane

There is **no PLM in this build**, so the excitation surface tilt cannot be
corrected — but it is deterministic and the control code should report it.

| | |
|---|---|
| Surface tilt | 1.105°, entirely along the **dispersion** axis |
| Depth gradient | **0.01929 µm of depth per µm** across the field |
| ... per DMD pixel | 0.04282 µm per pixel along the `(1, 1)` diagonal |
| Total across the patch | **13.9 µm** |
| Axial FWHM | **7.1 µm** `[LOW ±40%]` |

So `z_um ≈ x_disp * 0.01929` (sign from calibration). The walk is comparable
to one axial FWHM across the full field, so a target at one edge and a target at
the other are **not in the same plane** — worth surfacing in the UI rather than
hiding. There is no groove-axis component; objective field curvature contributes
0.47 µm and is negligible here.

## 7. Power, and the one real hazard

**Every 4f relay of a collimated DMD forms a real focus at its pupil.** With a
*uniform* ON patch the whole pulse lands in one ~29 µm
spot in air there. At the full 400 µJ
the CARBIDE delivers at 100 kHz that is
2.9e+14 W/cm², above where air ionises for a
200 fs pulse.

* **Keep the pulse energy under ~68 µJ**
  (6.8 W at
  100 kHz) whenever a large fraction of the patch is ON.
* Raise the **rep rate**, never the pulse energy.
* **Sparse patterns are far safer**: the pupil peak scales with the square of the
  pattern's mean, so a few-percent fill is orders of magnitude below a full-field
  frame. The dangerous case is precisely the all-ON alignment pattern.

### THE RULE FOR THE CONTROL SOFTWARE: never illuminate more than 50% of the chip

**Cap the ON fraction at 50%.** [USER 2026-07-28] The chip is never run anywhere
near full-on in practice, and this makes that a property of the software rather
than of operator discipline.

Why 50% is the right number, and why it is sufficient rather than arbitrary. For a
contiguous ON region the pupil intensity scales as the SQUARE of the ON fraction —
power rises with the lit area while the DC spot AREA falls as its inverse — so:

| ON fraction | relative pupil intensity | at the 7.1 W operating point |
|---|---|---|
| 100% (alignment) | 1.00× | 5.2e+13 W/cm² — **over the ~5e13 threshold** |
| 70% | 0.49× | 2.5e+13 W/cm² |
| **50%** | **0.25×** | **1.3e+13 W/cm² — ~4× margin** |
| 10% | 0.01× | 5.2e+11 W/cm² |

So a 50% cap buys about **4× of margin** at the operating power, and the only
condition it forbids is the alignment frame nobody needs at full power.

**Implementation notes.** Count ON mirrors over the WHOLE chip and refuse to load a
frame above the cap — it is one comparison per frame, not per target, so it costs
nothing. Note the cap is conservative for sparse patterns and tight for solid ones:
the quantity that actually concentrates light is the largest CONTIGUOUS ON region,
not the total. A frame that is 50% ON as scattered cell-sized targets is orders of
magnitude safer than one that is 50% ON as a single filled block. If a solid
alignment target is ever wanted, keep it under 50% AND drop the laser power.

* This supersedes the softer "sensible interlock" wording of earlier revisions.

Routine operation is inside this bound, but not far inside it: holding 1 µW/µm²
over the *whole* field at once needs **7.06 W** of the
40 W available (end to end 4.3%), which at
100 kHz is **71 µJ per pulse against the ~68 µJ ceiling — a
0.96× margin**. Whole-field-at-once is the worst case and not how the
instrument is used, but it is close enough that the interlock above is worth
having rather than optional.

## 8. Illumination non-uniformity, and how to correct it

No πShaper, so the patch sits inside a Gaussian. As a function of radius in
pixels from the patch centre:

```
I(r) / I0 = exp(-2 * r_px**2 / 555.6**2)
```

| r (px) | Relative intensity |
|---|---|
| 0 | 1.00 |
| 81 | 0.96 |
| 162 (patch edge) | **0.84** |

**Correct it in time, not in optics.** The DMD is binary at
12,500 Hz, so per-target dose is set by how many
80 µs frames the target is ON. Scale each target's dwell by
`1 / I(r)`; the worst-case correction at the patch edge is
**1.19×**. Budget for it: a target at the edge needs
1.19× the dwell of one at centre for the same dose.

This is also why the patch is a disc rather than a square — a square's corners
sit at √2 further out, where the Gaussian has fallen to
0.71 of centre.

## 9. Do not hard-code these

Every number above is **design intent**, not calibration. In particular:

* The periscope on the scope is a 150/200 pair, and **which lens the beam
  meets first was measured on the bench on 2026-07-27**: the
  150 mm is first. That is now an input, not an assumption —
  but it is the single highest-leverage one, because mounting it the other way
  round moves M_gs by 0.56× and every µm-per-pixel figure in §5 with it.
  If the arm is ever rebuilt, re-measure it.
* The Olympus 180 mm tube lens is measured but should be re-confirmed.
* The anamorphic factor follows from the grating's installed incidence angle; a
  degree of mounting error moves it.

**The control code should fit its own affine map** (scale, rotation, shear,
offset) from a measured calibration grid, and use §5 only as the expected
starting point and a sanity check. If the fitted scale disagrees with
1.9200 / 2.2193 µm per pixel by more than a few percent,
something is installed differently from this document.

---

*Optical design, the sweep that produced it, and the independent ray-trace check
live in the `TF optics simulator` repo: `docs/bringup_design.md`,
`python -m configs.bringup`, `python -m configs.bringup_verify`.*
