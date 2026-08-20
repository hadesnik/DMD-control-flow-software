"""SLM-plane irradiance with a 1200 l/mm vs a 600 l/mm temporal-focusing grating.

WHY THIS COMPARISON EXISTS
--------------------------
The grating is the one element that decides how hard the SLM is driven. The
SLM sits at a *post-grating* pupil, so what lands on the liquid crystal is the
Fourier transform of the DMD pattern **convolved along dispersion with the
laser spectrum** -- the "spectral line" of handoff section 7a. A weaker grating
smears less, which concentrates the same power into a shorter line.

Halving the groove density does NOT halve the dispersion. Holding the
incidence angle fixed, the grating equation

    sin(alpha) + sin(beta) = m * lambda * g

moves the diffracted order as well, and the angular dispersion is

    dbeta/dlambda = m * g / cos(beta)

so the cos(beta) term claws some dispersion back. At 1038 nm with alpha =
the installed incidence angle the 1200 l/mm grating diffracts at the beta the
handoff BOM states, while 600 l/mm swings the order across the normal, where
cos(beta) is near 1. Net: ~2.4x, not 2x. Both angles are read from the
handoff, never quoted, because rev 5 re-angled the grating.

PATTERNS SHOWN
--------------
Four real patterns, geometry copied from the code that actually projects them
rather than re-invented:

  * 300 soma-sized spots (sized by DIAMETER, default Ø7 px ~= 14 um) -- the experiment.
  * scripts/alignmentTarget.m -- the bench alignment GUIDE: rings every 40 px
    out to 400 px radius (deliberately PAST the Ø463 px patch, because finding
    where the illumination really ends is its whole purpose), both chip
    diagonals, and an asymmetric fiducial that kills rotation/flip ambiguity.
  * tfp.patterns.alignmentTarget -- the DOWNSTREAM target, confined to the
    patch: edge ring, centre cross, long dispersion ticks / short groove ticks.
  * Plain crosshairs, for continuity with the first figure.

WHAT TO READ OFF IT
-------------------
All eight SLM panels share one normalisation, so brightness is directly
comparable: the 600 l/mm row is genuinely hotter, not just differently scaled.

STATED ASSUMPTIONS -- see slm_plane_profiles.py for the full model and its
validation. The one added here: the 600 l/mm grating is assumed to be a
straight swap into the same mount at the SAME installed incidence. Re-angling
the mount (e.g. toward Littrow) changes beta and therefore every ratio below.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "fig_util"))
sys.path.insert(0, str(REPO / "sim"))

from figure_helpers import apply_style, justified_legend, panel_label, savefig  # noqa: E402
from slm_plane_profiles import (  # noqa: E402
    CANVAS_MM,
    SLM_APERTURE_MM,
    SOMA_DIAM_PX,
    Rig,
    _chip_grid,
    build_rig,
    illumination,
    random_spots,
    slm_plane,
)

# Incidence angle, read from the handoff rather than quoted: rev 5 re-angled
# the grating (42.8/34.5 -> 43.7/33.7) at the same time as the lens swap.
ALPHA_DEG = build_rig().grating_alpha_deg   # held fixed across both gratings
GRATINGS = (1200e3, 600e3)


def rig_for_grating(base: Rig, lines_per_m: float) -> Rig:
    """Clone the rig with a different grating, solving for the diffracted angle.

    beta comes from the grating equation rather than being quoted, which is
    what makes the 600 l/mm case honest: its order lands on the far side of
    the normal and cos(beta) -- not just g -- sets the dispersion.
    """
    alpha = math.radians(ALPHA_DEG)
    sin_beta = base.wavelength_m * lines_per_m - math.sin(alpha)
    if not -1.0 <= sin_beta <= 1.0:
        raise ValueError(f"{lines_per_m/1e3:.0f} l/mm has no propagating order at this angle")
    beta = math.asin(sin_beta)
    return Rig(**{**base.__dict__,
                  "grating_lines_per_m": lines_per_m,
                  "grating_beta_deg": math.degrees(beta)})


# ---------------------------------------------------------------------------
# Patterns -- geometry mirrored from the projecting code, not re-invented.
# ---------------------------------------------------------------------------

def pattern_spots(rig: Rig, n: int = 300, diam_px: int = SOMA_DIAM_PX) -> np.ndarray:
    """n soma-sized discs over the patch. Sized by DIAMETER, from the shared
    helper so both figures cannot drift apart on what "a spot" means."""
    return random_spots(rig, n=n, diam_px=diam_px, seed=300)


def pattern_guide_target(rig: Rig, step: int = 40, ring_thick: int = 6,
                         fid_size: int = 34, fid_radius: int = 200) -> np.ndarray:
    """scripts/alignmentTarget.m -- the bench alignment guide.

    Rings run out to min(cx,cy) = 400 px, i.e. well beyond the Ø463 px patch;
    that overrun is deliberate in the original (it is how the real footprint
    radius gets measured), and it is why this pattern is the one that lights
    mirrors the aperture budget never covered.
    """
    x, y = _chip_grid(rig)
    r = np.hypot(x, y)
    img = np.zeros(x.shape, dtype=bool)

    max_r = min((rig.cols + 1) / 2.0, (rig.rows + 1) / 2.0)
    for k in range(1, int(max_r // step) + 1):
        t = ring_thick * 2 if k % 5 == 0 else ring_thick   # every 5th doubled
        img |= np.abs(r - k * step) <= t / 2.0

    # The two chip diagonals ARE the dispersion and groove axes (45° clocking).
    img |= np.abs(x - y) / math.sqrt(2) <= ring_thick / 2.0
    img |= np.abs(x + y) / math.sqrt(2) <= ring_thick / 2.0

    # Asymmetric fiducial: filled square on +(1,1), short bar on +(1,-1).
    f = fid_radius / math.sqrt(2)
    img |= (np.abs(x - f) <= fid_size / 2) & (np.abs(y - f) <= fid_size / 2)
    img |= (np.abs(x - f) <= fid_size) & (np.abs(y + f) <= fid_size / 6)
    return img


def pattern_downstream_target(rig: Rig, ring_w: float = 5, cross_half: float = 60,
                              line_w: float = 5, tick_disp: float = 40,
                              tick_grv: float = 20) -> np.ndarray:
    """tfp.patterns.alignmentTarget -- patch-confined downstream target."""
    x, y = _chip_grid(rig)
    r = np.hypot(x, y)
    R = rig.patch_diameter_px / 2.0
    u = (x + y) / math.sqrt(2)     # dispersion diagonal
    v = (x - y) / math.sqrt(2)     # groove diagonal

    ring = np.abs(r - R) <= ring_w / 2
    cross = ((np.abs(x) <= line_w / 2) & (np.abs(y) <= cross_half)) | \
            ((np.abs(y) <= line_w / 2) & (np.abs(x) <= cross_half))
    inner = R - ring_w
    d_tick = (np.abs(v) <= line_w / 2) & (np.abs(u) >= inner - tick_disp) & (np.abs(u) <= inner - 3)
    g_tick = (np.abs(u) <= line_w / 2) & (np.abs(v) >= inner - tick_grv) & (np.abs(v) <= inner - 3)
    return (ring | cross | d_tick | g_tick) & (r <= R + ring_w / 2)


def pattern_crosshair(rig: Rig, bar: int = 6) -> np.ndarray:
    x, y = _chip_grid(rig)
    patch = np.hypot(x, y) <= rig.patch_diameter_px / 2.0
    return ((np.abs(x) <= bar) | (np.abs(y) <= bar)) & patch


FLOOR_DB = -6.0


def line_extent_mm(img: np.ndarray, mm_per_px: float, frac: float) -> float:
    """Width of the dispersion-axis profile at ``frac`` of its peak."""
    n = img.shape[0]
    ax = (np.arange(n) - n / 2 + 0.5) * mm_per_px
    prof = img.sum(axis=0)
    sel = ax[prof > prof.max() * frac]
    return float(sel.max() - sel.min()) if sel.size else 0.0


def main() -> Path:
    apply_style()
    base = build_rig()
    illum = illumination(base)

    cases = [
        (f"300 spots, Ø{SOMA_DIAM_PX} px", pattern_spots(base)),
        ("Alignment guide\n(scripts/, rings to 400 px)", pattern_guide_target(base)),
        ("Downstream target\n(tfp.patterns, in-patch)", pattern_downstream_target(base)),
        ("Crosshairs", pattern_crosshair(base)),
    ]
    rigs = {g: rig_for_grating(base, g) for g in GRATINGS}

    # Compute every panel first: the shared normalisation has to see them all,
    # otherwise the 600 l/mm concentration is hidden by per-panel autoscaling.
    grid: dict = {}
    for g in GRATINGS:
        for label, pat in cases:
            img, mm = slm_plane(pat, rigs[g], illum)
            grid[(g, label)] = (img, mm)
    ref = max(img.max() for img, _ in grid.values())

    ncol = len(cases)
    fig = plt.figure(figsize=(13.6, 11.6))
    gs = fig.add_gridspec(
        4, ncol, height_ratios=[1.0, 1.32, 1.32, 1.05],
        left=0.075, right=0.885, top=0.955, bottom=0.275, hspace=0.46, wspace=0.14,
    )
    half = CANVAS_MM / 2.0
    extent = [-half, half, -half, half]

    # --- row 1: the frames written on the chip ------------------------------
    for i, (label, pat) in enumerate(cases):
        ax = fig.add_subplot(gs[0, i])
        ax.imshow(pat, cmap="Greys", origin="lower", interpolation="nearest", aspect="equal")
        ax.set_xticks([]); ax.set_yticks([])
        ax.set_title(label, fontsize=8.5, pad=3)
        panel_label(ax, "ABCD"[i], x=-0.02, y=1.34)
        if i == 0:
            ax.set_ylabel("DMD chip", fontsize=9)

    # --- rows 2-3: what the LC sees, one row per grating --------------------
    letters = {1200e3: "EFGH", 600e3: "IJKL"}
    for row, g in enumerate(GRATINGS, start=1):
        rg = rigs[g]
        for i, (label, _) in enumerate(cases):
            img, mm = grid[(g, label)]
            ax = fig.add_subplot(gs[row, i])
            with np.errstate(divide="ignore"):
                db = np.log10(np.maximum(img / ref, 1e-30))
            im = ax.imshow(db, cmap="inferno", origin="lower", extent=extent,
                           vmin=FLOOR_DB, vmax=0.0, interpolation="nearest", aspect="equal")
            ax.add_patch(Rectangle((-SLM_APERTURE_MM / 2, -SLM_APERTURE_MM / 2),
                                   SLM_APERTURE_MM, SLM_APERTURE_MM,
                                   fill=False, ec="#39d0ff", lw=1.0, ls="--"))
            ax.set_xticks([-8, 0, 8]); ax.set_yticks([-8, 0, 8])
            ax.tick_params(labelsize=8)
            panel_label(ax, letters[g][i], x=-0.02, y=1.04)
            if i == 0:
                ax.set_ylabel(f"{g/1e3:.0f} l/mm  (β = {rg.grating_beta_deg:+.1f}°)\n"
                              "groove axis (mm)", fontsize=9)
            else:
                ax.set_yticklabels([])
            if row == 2:
                ax.set_xlabel("dispersion (mm)", fontsize=8.5)

    cax = fig.add_axes([0.898, gs[2, 0].get_position(fig).y0, 0.012,
                        gs[1, 0].get_position(fig).y1 - gs[2, 0].get_position(fig).y0])
    cb = fig.colorbar(im, cax=cax)
    cb.set_label("log₁₀ irradiance, common scale across all eight panels", fontsize=9)
    cb.ax.tick_params(labelsize=8)

    # --- row 4: the number the comparison is about --------------------------
    axm = fig.add_subplot(gs[3, :])
    xs = np.arange(ncol)
    w = 0.34
    fw = {g: [line_extent_mm(grid[(g, l)][0], grid[(g, l)][1], 0.5) for l, _ in cases]
          for g in GRATINGS}
    axm.bar(xs - w / 2, fw[1200e3], w, label="1200 l/mm", color="#c1443c")
    axm.bar(xs + w / 2, fw[600e3], w, label="600 l/mm", color="#3c6fc1")
    for xi, (a, b) in enumerate(zip(fw[1200e3], fw[600e3])):
        axm.text(xi, max(a, b) + 0.22, f"{a/b:.2f}× longer", ha="center", va="bottom",
                 fontsize=8.5, fontweight="bold")
    axm.set_xticks(xs)
    axm.set_xticklabels([l.replace("\n", " ") for l, _ in cases], fontsize=8.5)
    axm.set_ylabel("line length,\nFWHM (mm)", fontsize=9)
    axm.set_ylim(0, max(fw[1200e3]) * 1.45)   # headroom so the ratio labels clear the key
    axm.tick_params(labelsize=8)
    axm.legend(fontsize=8.5, frameon=False, loc="upper right", ncol=2)
    axm.set_xlim(-0.6, ncol - 0.4)
    panel_label(axm, "M", x=-0.028, y=1.13)

    peak_ratio = np.mean([grid[(600e3, l)][0].max() / grid[(1200e3, l)][0].max()
                          for l, _ in cases])
    ratio = np.mean([a / b for a, b in zip(fw[1200e3], fw[600e3])])

    kern = rigs[1200e3].smear_fwhm_m / rigs[600e3].smear_fwhm_m
    b12, b6 = rigs[1200e3].grating_beta_deg, rigs[600e3].grating_beta_deg
    title = (f"A 600 l/mm grating shortens the spectral line {min(ratio_list:=[a/b for a, b in zip(fw[1200e3], fw[600e3])]):.1f}–"
             f"{max(ratio_list):.1f}× — and brightens the liquid crystal by the same factor.")
    body = (
        f"Scalar Fourier propagation to the Meadowlark HSP1K at the bench-confirmed f7 = 300 mm, with the grating as the only variable. "
        f"β is solved from sin α + sin β = mλg at a fixed α = {ALPHA_DEG}° incidence, i.e. a straight swap into the same mount; the "
        f"1200 l/mm case returns β = {b12:+.1f}°, reproducing the handoff BOM, while 600 l/mm throws the order to β = {b6:+.1f}°, "
        f"across the normal. "
        f"(A–D) The frames written on the chip: 300 targets of Ø{SOMA_DIAM_PX} px (≈{SOMA_DIAM_PX*2.039:.0f} µm at the sample); the bench alignment guide from scripts/alignmentTarget.m, whose rings "
        "deliberately run to 400 px radius, outside the Ø463 px patch, because locating the true illumination edge is its purpose; the "
        "patch-confined downstream target from tfp.patterns.alignmentTarget (edge ring, centre cross, long dispersion ticks, short groove "
        "ticks); and plain crosshairs. (E–H) Irradiance on the LC with the 1200 l/mm grating. (I–L) The same four frames with 600 l/mm. "
        "All eight share one log₁₀ colour scale normalised to the brightest panel and identical ±11 mm axes, so the 600 l/mm row being "
        "visibly hotter is a real difference, not autoscaling; dashed cyan square is the 17.4 mm aperture. Chip-aligned features sit on the "
        f"diagonals because the chip is clocked 45° and each transform is rotated into the lab frame. (M) Spectral-line length, measured as "
        f"the FWHM of the dispersion-axis profile, paired per pattern. Mean shortening is {ratio:.2f}×, against {peak_ratio:.2f}× higher peak "
        f"irradiance — the same power in a shorter line. The underlying smear kernel shortens by {kern:.2f}×; measured lines fall below that "
        f"because each pattern's own transform has finite width along dispersion, most visibly for the 300 spots ({ratio_list[0]:.2f}×), whose "
        f"broad envelope dominates the convolution. Because angular dispersion is m·g/cos β, halving the groove density gives {kern:.2f}× rather "
        f"than 2×: cos β rises from {math.cos(math.radians(b12)):.3f} to {math.cos(math.radians(b6)):.3f} and returns some of what halving g "
        f"took away. Caveat: re-angling the mount instead of swapping in place changes β and every ratio here."
    )
    justified_legend(fig, title, body)

    return savefig(
        fig, "slm_grating_compare", outdir="figures/slm_plane",
        functions=[main, rig_for_grating, pattern_spots, pattern_guide_target,
                   pattern_downstream_target, pattern_crosshair, line_extent_mm,
                   slm_plane, illumination, justified_legend, panel_label],
    )


if __name__ == "__main__":
    print(f"\nwrote {main()}")
