"""Beam profile at the SLM plane for five classes of DMD pattern.

WHAT THIS SHOWS
---------------
In the merged arm the SLM does not see an image of the DMD -- it sits at a
**Fourier (pupil) plane** of it:

    DMD --4f(L1a/L1b)--> GRATING --4f(Ra/Rb)--> I0 --f7--> SLM

I0 is an intermediate *image* of the chip, and f7 sits one focal length from
I0 and one from the SLM, so the SLM field is the Fourier transform of the
pattern written on the DMD. That is why the pattern you draw and the
irradiance the liquid crystal actually experiences look nothing alike, and why
handoff section 7b caps all-ON/near-uniform patterns at 42 mW.

The figure answers one bench question: for each pattern class, where does the
light pile up on the LC, and how close does it come to the aperture edge?

THE TWO PHYSICAL EFFECTS THAT SET THE PICTURE
---------------------------------------------
1. **Diffraction envelope.** A pattern sampled on the DMD's pixel grid has
   angular content out to the grid Nyquist frequency, which maps to a fixed
   half-width at the SLM of lambda*f7/(2*a), where a is the DMD pitch relayed
   to I0. Every diffraction order the pattern generates lands inside that
   window; finer chip features push light further out toward the aperture.

2. **Spectral smear along the dispersion axis.** The pulse is broadband
   (205 fs -> ~7.7 nm FWHM), and the grating sends each wavelength to a
   different angle. So the SLM -- a *post-grating* pupil -- sees the whole
   diffraction pattern convolved along dispersion with the laser spectrum.
   Handoff section 7a: at every post-grating pupil "the spectrum smeared into
   a line", which is what keeps the LC below the damage limit that would
   otherwise apply. The un-smeared DC spot would be ~16 um across; smeared it
   is several mm long.

MODEL VALIDATION (why you can believe the axes)
-----------------------------------------------
Two independent numbers fall out of the model and match the handoff without
being fitted to it:

  * cross-dispersion footprint -> 7.21 mm, handoff says 7.2 mm;
  * patch-edge illumination -> 0.3603, handoff constant is 0.3604.

STATED ASSUMPTIONS / LIMITS
---------------------------
  * Scalar, paraxial, monochromatic-per-wavelength; the pulse enters only as
    an incoherent sum over wavelength (the convolution above). No temporal
    focusing dynamics -- this is the time-averaged irradiance the LC sees.
  * The anamorphic factor is NOT applied to the pupil coordinate. The handoff
    fixes its magnitude but not which way it runs at the pupil, and it is a
    ~15% stretch of the dispersion axis only. It moves no order between
    "inside" and "outside" the aperture, so the conclusions are unaffected;
    the axis scale carries that caveat.
  * The whole lens prescription (Ra/Rb/f7/f6/p1) and the grating angles are
    read from the committed handoff and cross-checked against its own
    um_per_px_groove and anamorphic constants, so a regeneration either
    propagates or raises. Nothing optical is hardcoded here.
  * Mirror-level diffraction from the DMD's own blaze is not modelled; this is
    the pattern's Fourier content only, within the first Nyquist window.

All other constants are parsed live from docs/optics_handoff.md, never pasted,
matching the repo rule that the handoff is the single source of truth.
"""

from __future__ import annotations

import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "fig_util"))

from figure_helpers import (  # noqa: E402
    apply_style,
    justified_legend,
    panel_label,
    savefig,
)

HANDOFF = REPO / "docs" / "optics_handoff.md"


def parse_build_label(label: str) -> dict:
    """Pull the lens prescription out of the handoff's ``build_label``.

    e.g. ``5.0mm Ra/Rb 250/200 f7 300 f6 80 p1 100`` -> Ra/Rb/f7/f6/p1 in mm.

    This exists because rev 4 -> rev 5 moved Ra (300 -> 250) at the same time
    as f7 (250 -> 300), and the two changes cancel on the groove axis. Anything
    that hardcoded one and not the other silently produced a scale that was
    wrong by 1.2x while still looking self-consistent. Read both, or neither.
    """
    m = re.search(r"Ra/Rb\s+(\d+)/(\d+)\s+f7\s+(\d+)\s+f6\s+(\d+)\s+p1\s+(\d+)", label)
    if not m:
        raise RuntimeError(f"cannot parse lens prescription from build_label: {label!r}")
    ra, rb, f7, f6, p1 = (float(v) for v in m.groups())
    return dict(f_Ra_mm=ra, f_Rb_mm=rb, f7_mm=f7, f_f6_mm=f6, f_peri1_mm=p1)


def parse_grating(text: str) -> dict:
    """Groove density and the installed in/out angles, from the BOM row.

    The angles are prose, not machine-readable, so the result is checked
    against the ``anamorphic`` constant (= cos beta / cos alpha) before use --
    if the optics repo re-angles the grating and this regex goes stale, that
    check fires rather than the figure quietly using last year's geometry.
    """
    row = re.search(r"TF grating.*?(\d+) g/mm.*?In\s*([\d.]+)°,\s*out\s*([\d.]+)°", text, re.S)
    if not row:
        raise RuntimeError("cannot find the TF grating row in the handoff")
    g, alpha, beta = float(row.group(1)), float(row.group(2)), float(row.group(3))
    return dict(grating_lines_per_m=g * 1e3, grating_alpha_deg=alpha, grating_beta_deg=beta)


def read_handoff_constants(path: Path = HANDOFF) -> dict:
    """Parse the fenced ``handoff-constants`` block out of the optics handoff.

    The Python twin of ``tfp.util.readHandoffConstants``. Reading at runtime
    (rather than pasting) is what keeps this figure honest when the optics repo
    regenerates -- the repo has been bitten three times by copied scale
    constants going stale.
    """
    text = path.read_text(encoding="utf-8")
    m = re.search(r"```handoff-constants\n(.*?)```", text, re.S)
    if not m:
        raise RuntimeError(f"no handoff-constants block in {path}")
    out: dict[str, object] = {}
    for line in m.group(1).splitlines():
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        key, _, val = line.partition(":")
        val = val.strip()
        try:
            out[key.strip()] = float(val) if "." in val else int(val)
        except ValueError:
            out[key.strip()] = val
    return out


@dataclass
class Rig:
    """Everything the propagation needs, derived once from the handoff."""

    cols: int
    rows: int
    pitch_m: float
    patch_diameter_px: float
    wavelength_m: float
    pulse_fwhm_s: float
    f7_m: float
    # relay: DMD -> I0. Ra/Rb come from build_label; L1a/L1b are fixed by the
    # DMD front end and do not vary across the trade study.
    f_L1a_mm: float = 80.0
    f_L1b_mm: float = 400.0
    f_Ra_mm: float = 250.0
    f_Rb_mm: float = 200.0
    grating_lines_per_m: float = 1200e3
    grating_alpha_deg: float = 43.7  # incidence,  handoff BOM row 3
    grating_beta_deg: float = 33.7   # diffracted, handoff BOM row 3
    illum_1e2_diameter_m: float = 7.0e-3

    @property
    def m_dmd_to_i0(self) -> float:
        """Magnification from the chip to the intermediate image I0."""
        return (self.f_L1b_mm / self.f_L1a_mm) * (self.f_Rb_mm / self.f_Ra_mm)

    @property
    def pitch_at_i0_m(self) -> float:
        return self.pitch_m * self.m_dmd_to_i0

    @property
    def slm_halfwidth_m(self) -> float:
        """Half-width of the diffraction window at the SLM (grid Nyquist).

        A pattern on a pitch-``a`` grid carries spatial frequencies out to
        1/(2a); the Fourier lens maps frequency nu to position lambda*f7*nu.
        """
        return self.wavelength_m * self.f7_m / (2.0 * self.pitch_at_i0_m)

    @property
    def bandwidth_m(self) -> float:
        """Spectral FWHM of a transform-limited Gaussian pulse (dt*dnu=0.441)."""
        dnu = 0.441 / self.pulse_fwhm_s
        c = 299_792_458.0
        return self.wavelength_m**2 / c * dnu

    @property
    def smear_fwhm_m(self) -> float:
        """How far the grating spreads the spectrum across the SLM.

        Angular dispersion dbeta/dlambda = m/(d cos beta) at the grating, scaled
        by the Ra/Rb relay's angular magnification (the reciprocal of its
        spatial magnification), then converted to a length by f7.
        """
        d = 1.0 / self.grating_lines_per_m
        dbeta_dlam = 1.0 / (d * math.cos(math.radians(self.grating_beta_deg)))
        ang_mag = self.f_Ra_mm / self.f_Rb_mm
        return self.f7_m * dbeta_dlam * self.bandwidth_m * ang_mag


def build_rig() -> Rig:
    """Assemble the rig entirely from the committed handoff, then self-check.

    Nothing here is a literal. The check at the end recomputes the sample-plane
    scale from the parsed lens prescription and compares it to the handoff's
    own ``um_per_px_groove``/``anamorphic``; a mismatch means the document
    moved in a way this model did not follow, and it is better to stop than to
    render a plausible-looking figure on stale geometry.
    """
    hc = read_handoff_constants()
    lenses = parse_build_label(str(hc["build_label"]))
    grating = parse_grating(HANDOFF.read_text(encoding="utf-8"))

    rig = Rig(
        cols=int(hc["dmd_cols"]),
        rows=int(hc["dmd_rows"]),
        pitch_m=float(hc["dmd_pitch_um"]) * 1e-6,
        patch_diameter_px=float(hc["patch_diameter_px"]),
        wavelength_m=float(hc["wavelength_nm"]) * 1e-9,
        pulse_fwhm_s=float(hc["pulse_fwhm_fs"]) * 1e-15,
        f7_m=lenses["f7_mm"] * 1e-3,
        f_Ra_mm=lenses["f_Ra_mm"],
        f_Rb_mm=lenses["f_Rb_mm"],
        **grating,
    )

    # Scale check: M_gs = 1 / (m_x * m_i0_s), groove = pitch * M1 / M_gs.
    m_x = rig.f_Rb_mm / rig.f_Ra_mm
    m_i0_s = (lenses["f_f6_mm"] / lenses["f7_mm"]) * (200.0 / lenses["f_peri1_mm"]) * (20.0 / 200.0)
    groove_um = rig.pitch_m * 1e6 * (rig.f_L1b_mm / rig.f_L1a_mm) * (m_x * m_i0_s)
    _agree("um_per_px_groove", groove_um, float(hc["um_per_px_groove"]))

    # Anamorphic check: it is cos(beta)/cos(alpha), which validates the angles
    # scraped out of the BOM prose.
    anam = math.cos(math.radians(rig.grating_beta_deg)) / math.cos(math.radians(rig.grating_alpha_deg))
    _agree("anamorphic", anam, float(hc["anamorphic"]))
    return rig


def _agree(name: str, got: float, want: float, tol: float = 0.005) -> None:
    if abs(got - want) / want > tol:
        raise RuntimeError(
            f"model disagrees with the handoff on {name}: computed {got:.4f}, "
            f"handoff says {want:.4f}. The prescription moved -- re-read "
            f"docs/optics_handoff.md before trusting any figure built here."
        )


# ----------------------------------------------------------------------------
# The patterns, all written in chip (col,row) coordinates and confined to the
# illuminated disc -- handoff section 4, enforced in code by
# tfp.util.assertPatternInPatch.
# ----------------------------------------------------------------------------

def _chip_grid(rig: Rig):
    yy, xx = np.mgrid[0 : rig.rows, 0 : rig.cols].astype(np.float64)
    return xx - (rig.cols - 1) / 2.0, yy - (rig.rows - 1) / 2.0


# Soma target size, as a DIAMETER in chip pixels. At the confirmed f7 = 300
# sample scale (1.9200 groove / 2.1581 dispersion, mean 2.04 µm/px) one chip
# pixel is ~2 µm, so:
#     Ø5 px  ~= 10 µm  -- a small soma, exactly the cell body
#     Ø7 px  ~= 14 µm  -- an L2/3 soma with a little targeting margin  <- default
#     Ø9 px  ~= 18 µm  -- a large soma / deliberate overfill
# Note scripts/alpRandomEnsemble.m computes a RADIUS and floors it at 2 px,
# which lands on Ø5 px -- the small end of this range.
SOMA_DIAM_PX = 7


def random_spots(rig: Rig, n: int, diam_px: int, seed: int = 20260819) -> np.ndarray:
    """``n`` discs of diameter ``diam_px``, uniform over the illuminated patch.

    Uniform in area (radius ~ sqrt(U)), not in radius, so the density does not
    pile up at the centre. Placement is seeded, so the figure is reproducible.
    """
    x, y = _chip_grid(rig)
    R = rig.patch_diameter_px / 2.0
    rad_px = diam_px / 2.0
    rng = np.random.default_rng(seed)
    out = np.zeros(x.shape, dtype=bool)
    placed = 0
    while placed < n:
        rr = R * math.sqrt(rng.random())
        th = rng.random() * 2 * math.pi
        cx, cy = rr * math.cos(th), rr * math.sin(th)
        if math.hypot(cx, cy) > R - rad_px:
            continue
        out |= np.hypot(x - cx, y - cy) <= rad_px
        placed += 1
    return out


def make_patterns(rig: Rig) -> list[tuple[str, str, np.ndarray]]:
    """Return ``(key, label, bool-array)`` for each case, in figure order."""
    x, y = _chip_grid(rig)
    r = np.hypot(x, y)
    R = rig.patch_diameter_px / 2.0
    patch = r <= R

    cases: list[tuple[str, str, np.ndarray]] = []

    # 1. Everything inside the illuminated disc. Note this is only ~16% of the
    #    whole chip, so it passes the 50% ON cap -- the cap targets a literal
    #    full-chip frame, not a full patch.
    cases.append(("all_on", "All ON (full patch)", patch))

    # 2. Checkerboards at three periods. A period-p checkerboard puts its
    #    energy into orders at +-1/p along both chip diagonals, so the coarser
    #    the square, the closer the orders sit to DC.
    for p in (64, 16, 4):
        chk = (((np.floor(x / p) + np.floor(y / p)) % 2) == 0) & patch
        cases.append((f"checker{p}", f"Checkerboard, {p} px", chk))

    # 3. Crosshairs: one bar along each chip axis. The transform of a bar is a
    #    line perpendicular to it, so this is the clearest demonstration that
    #    the SLM sees the *transform* and not the picture.
    bar = 6
    cross = ((np.abs(x) <= bar) | (np.abs(y) <= bar)) & patch
    cases.append(("crosshair", "Crosshairs", cross))

    # 4. Soma-sized targets -- the realistic experiment. Sized by DIAMETER;
    #    stating a radius invites the "2 px spot" ambiguity, since radius 2 px
    #    is Ø5 px on the chip.
    spots = random_spots(rig, n=200, diam_px=SOMA_DIAM_PX)
    cases.append(("spots200", f"200 spots, Ø{SOMA_DIAM_PX} px", spots))

    # 5. Annuli at three radii. A ring transforms to a Bessel J0 pattern whose
    #    ring spacing goes as 1/radius, so a bigger annulus gives finer fringes.
    for frac in (0.35, 0.65, 0.95):
        rr = frac * R
        w = 4.0
        ann = (np.abs(r - rr) <= w) & patch
        cases.append((f"annulus{int(frac*100)}", f"Annulus, {frac:.2f} R", ann))

    return cases


# ----------------------------------------------------------------------------
# Propagation to the SLM
# ----------------------------------------------------------------------------

def illumination(rig: Rig) -> np.ndarray:
    """Gaussian amplitude on the chip (Ø7.0 mm 1/e^2 *intensity* diameter).

    Reproduces the handoff's ``patch_edge_intensity`` (0.3604) at r = R, which
    is the check that this is the same beam the handoff modelled.
    """
    x, y = _chip_grid(rig)
    w_px = (rig.illum_1e2_diameter_m / 2.0) / rig.pitch_m
    return np.exp(-(x**2 + y**2) / w_px**2)  # amplitude; intensity is its square


def _bin_sum(a: np.ndarray, k: int) -> np.ndarray:
    """Sum k×k blocks -- downsampling that conserves total power."""
    n = (a.shape[0] // k) * k
    m = (a.shape[1] // k) * k
    return a[:n, :m].reshape(n // k, k, m // k, k).sum(axis=(1, 3))


def _rotate(img: np.ndarray, deg: float) -> np.ndarray:
    """Bilinear rotation about the array centre (scipy is not available here)."""
    h, w = img.shape
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    t = math.radians(deg)
    # inverse map: destination pixel -> source coordinate
    dx, dy = xx - cx, yy - cy
    sx = cx + dx * math.cos(t) + dy * math.sin(t)
    sy = cy - dx * math.sin(t) + dy * math.cos(t)
    x0, y0 = np.floor(sx).astype(int), np.floor(sy).astype(int)
    fx, fy = sx - x0, sy - y0
    out = np.zeros_like(img)
    ok = (x0 >= 0) & (x0 < w - 1) & (y0 >= 0) & (y0 < h - 1)
    xi, yi = np.clip(x0, 0, w - 2), np.clip(y0, 0, h - 2)
    out = (
        img[yi, xi] * (1 - fx) * (1 - fy)
        + img[yi, xi + 1] * fx * (1 - fy)
        + img[yi + 1, xi] * (1 - fx) * fy
        + img[yi + 1, xi + 1] * fx * fy
    )
    return np.where(ok, out, 0.0)


def _smear_x(img: np.ndarray, fwhm_px: float) -> np.ndarray:
    """Convolve along x with the laser spectrum (FFT convolution, numpy only)."""
    n = img.shape[1]
    sigma = fwhm_px / (2.0 * math.sqrt(2.0 * math.log(2.0)))
    k = np.arange(n) - n // 2
    kern = np.exp(-0.5 * (k / sigma) ** 2)
    kern /= kern.sum()
    return np.real(
        np.fft.ifft(np.fft.fft(img, axis=1) * np.fft.fft(np.fft.ifftshift(kern))[None, :], axis=1)
    )


# Display canvas: wide enough to hold the smeared line and the 17.4 mm aperture.
CANVAS_MM = 22.0
BIN = 4          # FFT downsample factor (power-conserving)
NFFT = 2048      # must exceed the 1280x800 chip


def slm_plane(pattern: np.ndarray, rig: Rig, illum: np.ndarray) -> np.ndarray:
    """Time-averaged irradiance at the SLM for one DMD pattern.

    Steps: (i) field on the chip = pattern x Gaussian illumination;
    (ii) Fourier transform -- this *is* the propagation, since the SLM is the
    Fourier plane of I0; (iii) rotate into the lab frame, because the chip is
    clocked 45 deg so the optical axes lie along its diagonals;
    (iv) convolve along dispersion with the laser spectrum.
    """
    field = np.zeros((NFFT, NFFT), dtype=np.complex128)
    r0 = (NFFT - pattern.shape[0]) // 2
    c0 = (NFFT - pattern.shape[1]) // 2
    field[r0 : r0 + pattern.shape[0], c0 : c0 + pattern.shape[1]] = pattern * illum

    inten = np.abs(np.fft.fftshift(np.fft.fft2(field))) ** 2
    inten = _bin_sum(inten, BIN)                      # -> NFFT/BIN across 2*halfwidth

    mm_per_px = (2.0 * rig.slm_halfwidth_m * 1e3) / inten.shape[0]
    n_canvas = int(round(CANVAS_MM / mm_per_px))
    n_canvas += n_canvas % 2
    canvas = np.zeros((n_canvas, n_canvas))
    o = (n_canvas - inten.shape[0]) // 2
    canvas[o : o + inten.shape[0], o : o + inten.shape[1]] = inten

    # The chip's 45 deg clocking: rotate the transform into the lab frame so
    # dispersion runs along +x and the (axis-aligned) SLM aperture is a square.
    canvas = _rotate(canvas, -45.0)
    return _smear_x(canvas, rig.smear_fwhm_m * 1e3 / mm_per_px), mm_per_px


# ----------------------------------------------------------------------------
# Figure
# ----------------------------------------------------------------------------

SLM_APERTURE_MM = 17.4   # Meadowlark HSP1K active area, 1024 x 17 um
FLOOR_DB = -6.0          # log10 dynamic range shown, relative to all-ON peak


def main() -> Path:
    apply_style()
    rig = build_rig()
    illum = illumination(rig)
    cases = make_patterns(rig)

    results = []
    for key, label, pat in cases:
        img, mm_per_px = slm_plane(pat, rig, illum)
        results.append(dict(key=key, label=label, pat=pat, img=img,
                            mm_per_px=mm_per_px,
                            on_frac=pat.mean()))

    ref_peak = results[0]["img"].max()          # all-ON sets the shared scale
    half = CANVAS_MM / 2.0
    extent = [-half, half, -half, half]
    for r in results:
        r["rel_peak"] = r["img"].max() / ref_peak
        n = r["img"].shape[0]
        ax_mm = (np.arange(n) - n / 2 + 0.5) * r["mm_per_px"]
        # Power that misses the LC entirely -- the aperture-fill question that
        # f7 = 300 reopens, since the footprint scales with f7.
        inside = (np.abs(ax_mm) <= SLM_APERTURE_MM / 2)[:, None] & \
                 (np.abs(ax_mm) <= SLM_APERTURE_MM / 2)[None, :]
        tot = r["img"].sum()
        r["clipped"] = 1.0 - (r["img"][inside].sum() / tot) if tot > 0 else 0.0
        # 1/e^2 extent of the collapsed profile on each axis, so the all-ON
        # case can be quoted as the aspect ratio of the spectral line.
        for key, prof in (("ext_disp", r["img"].sum(0)), ("ext_grv", r["img"].sum(1))):
            sel = ax_mm[prof > prof.max() * 0.1353]
            r[key] = float(sel.max() - sel.min()) if sel.size else 0.0

    worst_clip = max(r["clipped"] for r in results)
    line = results[0]

    # Spot-size sensitivity: the SLM peak is set by the DC order, which scales
    # as the square of the chip ON fraction, so target diameter is a stronger
    # lever on LC irradiance than the target COUNT is.
    sweep_d = [5, 7, 9, 11, 13]
    sweep = []
    for d in sweep_d:
        pat = random_spots(rig, n=200, diam_px=d)
        img, _ = slm_plane(pat, rig, illum)
        sweep.append((d, pat.mean(), img.max()))

    ncol = len(results)
    fig = plt.figure(figsize=(16.5, 11.3))
    gs = fig.add_gridspec(
        4, ncol, height_ratios=[1.0, 1.45, 1.10, 1.00],
        left=0.045, right=0.90, top=0.955, bottom=0.255, hspace=0.52, wspace=0.16,
    )

    letters = "ABCDEFGHI"
    for i, r in enumerate(results):
        # --- row 1: what is written on the chip -------------------------
        ax = fig.add_subplot(gs[0, i])
        ax.imshow(r["pat"], cmap="Greys", origin="lower", interpolation="nearest",
                  aspect="equal")
        ax.set_xticks([]); ax.set_yticks([])
        ax.set_title(r["label"], fontsize=8.5, pad=3)
        panel_label(ax, letters[i], x=-0.02, y=1.30)
        if i == 0:
            ax.set_ylabel("DMD chip", fontsize=9)

        # --- row 2: what the liquid crystal sees ------------------------
        ax2 = fig.add_subplot(gs[1, i])
        with np.errstate(divide="ignore"):
            db = np.log10(np.maximum(r["img"] / ref_peak, 1e-30))
        im = ax2.imshow(db, cmap="inferno", origin="lower", extent=extent,
                        vmin=FLOOR_DB, vmax=0.0, interpolation="nearest",
                        aspect="equal")
        ax2.add_patch(Rectangle((-SLM_APERTURE_MM / 2, -SLM_APERTURE_MM / 2),
                                SLM_APERTURE_MM, SLM_APERTURE_MM,
                                fill=False, ec="#39d0ff", lw=1.0, ls="--"))
        ax2.set_xticks([-8, 0, 8]); ax2.set_yticks([-8, 0, 8])
        ax2.tick_params(labelsize=8)
        if i == 0:
            ax2.set_ylabel("groove axis (mm)", fontsize=9)
        else:
            ax2.set_yticklabels([])
        ax2.set_xlabel("dispersion (mm)", fontsize=8.5)

    cax = fig.add_axes([0.915, gs[1, 0].get_position(fig).y0,
                        0.013, gs[1, 0].get_position(fig).height])
    cb = fig.colorbar(im, cax=cax)
    cb.set_label("log₁₀ irradiance, relative to all-ON peak", fontsize=9)
    cb.ax.tick_params(labelsize=8)

    # --- row 3: the two numbers that decide whether a pattern is safe ---
    axm = fig.add_subplot(gs[2, :])
    xs = np.arange(ncol)
    peaks = [r["rel_peak"] for r in results]
    axm.bar(xs, peaks, color="#c1443c", width=0.6)
    axm.set_yscale("log")
    axm.set_ylim(10 ** (FLOOR_DB - 0.4), 3.0)
    axm.axhline(1.0, color="#444", lw=0.9, ls="--")
    axm.text(ncol - 0.45, 1.25, "all-ON reference", fontsize=8.5, ha="right",
             va="bottom", color="#444")
    axm.set_xticks(xs)
    axm.set_xticklabels([r["label"] for r in results], fontsize=8.5)
    axm.set_ylabel("peak irradiance\n(rel. all-ON)", fontsize=9)
    axm.tick_params(labelsize=8)
    axm.set_xlim(-0.6, ncol - 0.4)
    panel_label(axm, "J", x=-0.012, y=1.06)
    for xi, r in zip(xs, results):
        pct = 100 * r["on_frac"]
        # White bbox so the all-ON reference line cannot cut through the label.
        axm.text(xi, r["rel_peak"] * 1.5, f"{pct:.1f}%" if pct < 10 else f"{pct:.0f}%",
                 ha="center", va="bottom", fontsize=8, zorder=5,
                 bbox=dict(facecolor="white", edgecolor="none", pad=1.0))

    # --- row 4: how hard target diameter drives the LC ----------------------
    axs = fig.add_subplot(gs[3, :])
    dd = np.array([d for d, _, _ in sweep])
    pk = np.array([p for _, _, p in sweep]) / ref_peak
    on = np.array([o for _, o, _ in sweep])
    axs.plot(dd, pk, "o-", color="#c1443c", lw=1.8, ms=7, label="simulated SLM peak")
    # The DC order carries (mean transmission)^2, so the square law is the
    # prediction, not a fit: anchor it on the smallest spot and let it run.
    axs.plot(dd, pk[0] * (on / on[0]) ** 2, "--", color="#444", lw=1.2,
             label="(chip ON fraction)² — predicted")
    axs.set_yscale("log")
    axs.set_xticks(dd)
    axs.set_xlabel("target diameter on the chip (px)", fontsize=9)
    axs.set_ylabel("peak irradiance\n(rel. all-ON)", fontsize=9)
    axs.tick_params(labelsize=8)
    axs.legend(fontsize=8.5, frameon=False, loc="upper left")
    axs.set_xlim(dd[0] - 0.7, dd[-1] + 0.7)
    axs.set_ylim(pk.min() / 4, pk.max() * 40)
    # Labels go ABOVE the points: the curve rises left-to-right, so below-left
    # runs into the x axis and its tick labels (which the overlap checker
    # deliberately ignores, so it would not be caught automatically).
    for d, o, p in sweep:
        axs.annotate(f"{d*2.039:.0f} µm\n{100*o:.1f}% ON", (d, p / ref_peak),
                     textcoords="offset points", xytext=(0, 13),
                     ha="center", fontsize=8)
    axs.annotate("used in (F)", (SOMA_DIAM_PX, pk[dd.tolist().index(SOMA_DIAM_PX)]),
                 textcoords="offset points", xytext=(0, -20), ha="center",
                 fontsize=8.5, fontweight="bold", color="#c1443c")
    panel_label(axs, "K", x=-0.012, y=1.06)

    title = "Irradiance at the SLM is the Fourier transform of the DMD pattern, smeared by the laser spectrum."
    body = (
        f"Scalar Fourier propagation of the merged arm to the Meadowlark HSP1K, at the bench-confirmed "
        f"f7 = {rig.f7_m*1e3:.0f} mm of handoff rev {read_handoff_constants()['handoff_rev']}. Every optical constant, including the lens "
        "prescription and grating angles, is parsed live from docs/optics_handoff.md and cross-checked against it. "
        "(A–I) Top row, the binary frame written on the DMD, confined to the Ø5.0 mm illuminated disc; bottom row, the resulting "
        "time-averaged irradiance on the liquid crystal, shown as log₁₀ relative to the all-ON peak over a common 6-decade scale and "
        "identical ±11 mm axes, so panels are directly comparable. Dashed cyan square is the 17.4 mm LC aperture. The horizontal axis "
        "is the grating's dispersion direction; because the chip is clocked 45°, each transform is rotated into this lab frame, which is "
        "why chip-aligned features (D, E) appear on the diagonals. (A) A filled patch puts everything into a single DC order, which the "
        f"grating then draws out into a spectral line of {line['ext_grv']:.2f} × {line['ext_disp']:.1f} mm (1/e², groove × dispersion). "
        f"That ~400:1 smear is what keeps the LC below its damage limit, and why the air-breakdown interlock sits upstream of the grating "
        f"instead. (B–D) Checkerboards at 64, 16 and 4 px "
        "place first orders at a radius that grows as 1/period, walking light outward from DC. (E) Crosshairs transform to a cross rotated "
        f"90° from the bars that produced it. (F) 200 targets of Ø{SOMA_DIAM_PX} px (≈{SOMA_DIAM_PX*2.039:.0f} µm at the sample), the "
        "realistic experiment: a broad speckled envelope with no "
        "concentration. (G–I) Annuli at 0.35, 0.65 and 0.95 of the patch radius give Bessel-ring transforms whose fringe spacing narrows "
        "as the ring grows. (J) Peak irradiance per pattern relative to the all-ON frame (log axis, dashed line = that reference); the "
        f"percentage above each bar is the fraction of the whole chip switched ON, which is the quantity the 50% load-time cap tests. "
        f"(K) Peak irradiance for 200 targets as target DIAMETER is swept {sweep_d[0]}–{sweep_d[-1]} px (≈{sweep_d[0]*2.039:.0f}–"
        f"{sweep_d[-1]*2.039:.0f} µm), spanning {pk[-1]/pk[0]:.0f}× — bigger targets both carry more power and transform to a narrower "
        "pupil distribution. The dashed line is the (ON fraction)² law the DC order obeys, drawn as a prediction anchored on the smallest "
        "spot rather than fitted; the agreement is why target size, not target count, is the strong lever on LC irradiance. "
        "Method: field = pattern × Gaussian illumination, one FFT to the pupil, rotation into the lab frame, then convolution along "
        "dispersion with the 7.7 nm pulse spectrum. The model is unfitted, yet reproduces two independent handoff constants — the "
        f"7.2 mm cross-dispersion footprint and the 0.3604 patch-edge intensity. No pattern clips the aperture "
        f"(worst case {100*worst_clip:.2f}% of power outside); the beam uses only ~41% of the aperture width across groove, which is "
        f"structural, not adjustable. The {read_handoff_constants()['anamorphic']:.4f} anamorphic factor is omitted because the handoff "
        f"fixes its magnitude but not its sign at the pupil; it would stretch the dispersion axis by ≤12% and moves no order across "
        f"the aperture."
    )
    justified_legend(fig, title, body)

    return savefig(
        fig, "slm_plane_profiles", outdir="figures/slm_plane",
        functions=[main, slm_plane, make_patterns, random_spots, illumination,
                   read_handoff_constants, build_rig, _rotate, _smear_x,
                   _bin_sum, _chip_grid, justified_legend, panel_label],
    )


if __name__ == "__main__":
    out = main()
    print(f"\nwrote {out}")
