"""Drop-in publication-figure helpers for scientific data analysis.

This is the shared, project-agnostic helper bundled with the ``figure-standards``
Claude Code plugin. Copy it into a project (e.g. into the project's package or a
``fig_util/`` directory) and route **every** figure save through :func:`savefig`.
It is the single source of truth for the lab's six figure conventions:

1. A legend with a **bold title**; legend body text renders at **10 pt**.
2. Panel letters at **14 pt** (bold).
3. **No on-figure text overlaps any other text or panel** -- enforced by a
   programmatic bounding-box check at save time (not by eyeballing).
4. Every figure is saved as a **vector PDF + a PNG companion**, plus an
   auto-generated **``<fig>.code.html``** listing the functions used to build it,
   linked from a clickable annotation in the PDF. PDF/PS text is embedded as
   **real, selectable/editable text** (``fonttype 42``), never vectorized outlines.
5. The legend states, per panel, exactly what each panel shows.
6. **All on-figure text is >= 8 pt** (the rcParams floor; the legend only ever
   shrinks toward 8 pt to dodge an overlap, never below).

Pure matplotlib + the standard library -- **no seaborn, no third-party deps** -- so
it renders in any environment that has matplotlib. Run ``python figure_helpers.py
--selftest`` to exercise the overlap check.
"""

from __future__ import annotations

import html
import inspect
import os
import re
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt

# Embed real text (not vectorized outlines) on any vector save, the moment this module
# is imported. matplotlib's defaults are wrong for this: pdf/ps default to Type-3 fonts
# (fonttype 3 -- not editable as live text in Illustrator, outlined by some renderers).
# 42 = embed the actual TrueType font, so text stays selectable AND editable. Set here at
# import (as well as in apply_style() below) so it holds even for scripts that save without
# calling apply_style() and for multi-page PdfPages saves that bypass savefig(). rcParams
# are process-global and read by the backend at save time, so this covers every save path.
mpl.rcParams["pdf.fonttype"] = 42
mpl.rcParams["ps.fonttype"] = 42


def apply_style() -> None:
    """Apply a consistent publication style to matplotlib rcParams.

    Every font size set here is **>= 8 pt** (convention 6): base 9, panel titles 10,
    axis labels 9, tick labels 8, matplotlib's own legend 8. Call once at import/startup
    before building figures.

    Also forces ``pdf.fonttype``/``ps.fonttype = 42`` so PDF/EPS text is embedded as
    real, selectable/editable TrueType text rather than matplotlib's default Type-3 /
    outlined glyphs (convention 4).
    """
    mpl.rcParams.update({
        # Real embedded text, not outlines -- see the module-level note above.
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "figure.dpi": 110,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "font.size": 9,
        "axes.titlesize": 10,
        "axes.labelsize": 9,
        "axes.linewidth": 0.8,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "legend.fontsize": 8,
        "legend.frameon": False,
        "lines.linewidth": 1.3,
        "figure.facecolor": "white",
        "axes.facecolor": "white",
    })


def savefig(fig, out_path, *, outdir=None, functions=None,
            link_text: str = "▸ source code", png_companion: bool = True,
            check_overlaps: bool = True, strict: bool = False) -> Path:
    """Save ``fig`` and return its path, enforcing the figure conventions.

    ``out_path`` is the destination filename or path; if it has no extension it
    defaults to ``.pdf`` (vector, publication format). ``outdir`` optionally prepends a
    directory (created if needed).

    File-type layout (convention 4): within each figure folder the three artifact types
    are kept in sibling subfolders -- the vector ``.pdf`` in ``pdf/``, its ``.png``
    companion in ``png/``, and the ``.code.html`` source listing in ``html/`` -- so a
    folder holding many figures stays navigable. ``savefig(fig, "psth", outdir="figures/psth")``
    therefore writes ``figures/psth/pdf/psth.pdf`` + ``figures/psth/png/psth.png`` +
    ``figures/psth/html/psth.code.html``.

    What this writes (conventions 3 & 4):

    - the **PDF** itself, into ``pdf/``;
    - a same-named **``.png``** companion into ``png/`` when ``png_companion`` (default
      ``True``) -- this is what previews inline on GitHub / in a figures README;
    - a self-contained **``<fig>.code.html``** source listing into ``html/`` when
      ``functions`` is given (an iterable of the callables used to build the figure, e.g.
      ``[main, collect, justified_legend]``) plus a small clickable "source code" link
      embedded in the PDF pointing at it. See :func:`write_code_listing`.

    Overlap gate (convention 3): when ``check_overlaps`` (default ``True``) the rendered
    text bounding boxes are checked; on any overlap a loud ``⚠ TEXT OVERLAP`` report is
    printed and a ``<fig>.overlap.txt`` sidecar is written next to the figure. A non-empty
    report is a **blocker to fix** (make the figure taller + enlarge
    ``fig.subplots_adjust(bottom=...)``, reposition/shrink the offending text, keep the
    legend at ``y_top=None``) -- regenerate until it is clean and no sidecar remains. Pass
    ``strict=True`` to additionally raise once the figure is saved, so a batch run fails
    loudly instead of silently leaving a sidecar.
    """
    raw = Path(out_path)
    if outdir is not None:
        raw = Path(outdir) / raw
    if not raw.suffix:
        raw = raw.with_name(raw.name + ".pdf")           # publication default is vector PDF
    suffix = raw.suffix.lower()
    stem = raw.stem
    folder = raw.parent                                  # the figure folder

    def _typed_dir(kind: str) -> Path:
        """The ``pdf/``, ``png/`` or ``html/`` sibling folder inside this figure folder."""
        d = folder / kind
        d.mkdir(parents=True, exist_ok=True)
        return d

    # Route by type: an explicit "foo.png" is a PNG-only save into png/; otherwise the
    # publication PDF goes into pdf/ (with its optional companion PNG into png/).
    if suffix == ".png":
        path = _typed_dir("png") / (stem + ".png")
    else:
        path = _typed_dir("pdf") / (stem + ".pdf")

    # Provenance: write the code listing (into html/) first, then embed a clickable link
    # to it. write_code_listing never raises (it degrades to None), so a figure always saves.
    if functions:
        sidecar = write_code_listing(path, functions, sidecar_dir=_typed_dir("html"))
        if sidecar is not None:
            attach_source_link(fig, sidecar, link_text=link_text)

    fig.savefig(path)
    if png_companion and suffix != ".png":
        # PNGs carry no clickable link (raster has no annotations) -- the link text
        # simply renders as a small blue label, which is harmless.
        fig.savefig(_typed_dir("png") / (stem + ".png"))

    # Mandatory self-check: no on-figure text may overlap another text or a panel.
    overlaps = []
    if check_overlaps:
        overlaps = _report_overlaps(fig, path.name, path.with_suffix(".overlap.txt"))
    if strict and overlaps:
        raise RuntimeError(
            f"{len(overlaps)} text overlap(s) in {path.name}; "
            f"see {path.with_suffix('.overlap.txt').name} and fix before continuing.")
    return path


def fig_dir(folder, kind: str) -> Path:
    """Return (creating it) the ``pdf/``/``png/``/``html/`` subfolder of a figure folder.

    The file-type layout convention (see :func:`savefig`) keeps each figure folder's PDFs,
    PNGs and ``.code.html`` listings in sibling subfolders. Multi-page ``PdfPages`` scripts
    that build their output path by hand (rather than going through :func:`savefig`) should
    route it through here, e.g.::

        pdf_path = fig_dir("figures/ccg", "pdf") / "ccg_rs_rs.pdf"
        sidecar  = write_code_listing(pdf_path, funcs, sidecar_dir=fig_dir("figures/ccg", "html"))
    """
    d = Path(folder) / kind
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Figure provenance: a clickable in-PDF link to an auto-generated HTML listing of
# the functions used to build the figure (convention 4). The listing is derived by
# introspecting the actual callables, so it needs no hand maintenance.
# ---------------------------------------------------------------------------
def attach_source_link(fig, sidecar, *, link_text: str = "▸ source code",
                       color: str = "#1a6fb0") -> None:
    """Embed a clickable link in ``fig`` pointing at the code-listing ``sidecar``.

    ``sidecar`` is the ``Path`` to the ``<figname>.code.html`` written next to the
    figure (the value returned by :func:`write_code_listing`).

    matplotlib's PDF backend turns a text artist's ``url=`` into a clickable URI link
    annotation. We embed the sidecar's **absolute** ``file://`` URI (via
    ``Path.resolve().as_uri()``, which percent-encodes spaces): most desktop viewers
    (macOS **Preview** in particular) ignore relative file links, so an absolute target
    is what actually opens. The link is correct for wherever the figure was last
    generated (re-running refreshes it); when viewed on GitHub the PNG companion is what
    is looked at anyway.

    The link is pinned to the bottom-right corner (bold, link-blue, 9 pt) so it clears
    the justified-legend band and stays strictly inside [0, 1] so ``bbox_inches="tight"``
    never clips it.
    """
    href = Path(sidecar).resolve().as_uri()
    t = fig.text(0.995, 0.006, link_text, ha="right", va="bottom", fontsize=9,
                 color=color, fontweight="bold", url=href)
    t.set_gid("source-link")


def write_code_listing(out_pdf: Path, functions, *, repo_root: Path | None = None,
                       sidecar_dir: Path | None = None) -> Path | None:
    """Write a self-contained HTML listing of ``functions`` for ``out_pdf``.

    ``functions`` is an iterable of callables (and/or the script's own functions). Each
    is introspected for its ``file:line`` and source. Functions defined inside the
    project tree (under ``repo_root``, default: the current working directory) get their
    full source dumped; third-party callables (numpy, matplotlib, ...) and any whose
    source can't be located are noted but not dumped, so the listing stays focused on the
    project's own code.

    Returns the sidecar :class:`~pathlib.Path` (``<figname>.code.html``) or ``None`` if
    nothing could be listed. By default the sidecar is written **beside** ``out_pdf``;
    pass ``sidecar_dir`` to place it elsewhere (``savefig`` passes the figure folder's
    ``html/`` subfolder so the listing lands next to its siblings). **Never raises** --
    provenance must not be able to break a figure save -- on error it prints a warning
    and returns ``None``.
    """
    try:
        root = (repo_root or Path.cwd()).resolve()
        in_repo, external, seen = [], [], set()
        for fn in functions:
            obj = inspect.unwrap(fn)            # see through decorators
            label = getattr(obj, "__qualname__", getattr(obj, "__name__", repr(obj)))
            try:
                src_file = inspect.getsourcefile(obj) or inspect.getfile(obj)
                src_lines, start = inspect.getsourcelines(obj)
            except (TypeError, OSError):
                # builtins / C-extensions / dynamically-defined: can't show source.
                external.append((label, getattr(obj, "__module__", "?"), None))
                continue
            abs_path = Path(src_file).resolve()
            key = (os.path.realpath(src_file), start)   # realpath collapses path variance
            if key in seen:
                continue
            seen.add(key)
            try:
                rel = abs_path.relative_to(root)        # ValueError => outside tree => third-party
            except ValueError:
                external.append((label, getattr(obj, "__module__", "?"),
                                 f"{abs_path}:{start}"))
                continue
            in_repo.append((label, f"{rel}:{start}", "".join(src_lines)))

        if not in_repo and not external:
            return None

        sidecar_name = out_pdf.stem + ".code.html"     # NOT with_suffix: stems hold dots
        listing_dir = Path(sidecar_dir) if sidecar_dir is not None else out_pdf.parent
        listing_dir.mkdir(parents=True, exist_ok=True)
        sidecar = listing_dir / sidecar_name
        sidecar.write_text(_render_code_html(out_pdf.name, in_repo, external),
                           encoding="utf-8")
        return sidecar
    except Exception as exc:                            # noqa: BLE001 -- never break a save
        print(f"  [provenance] code listing skipped: {exc}")
        return None


def _render_code_html(fig_name: str, in_repo, external) -> str:
    """Build the self-contained HTML page (inline CSS, no external assets)."""
    esc = html.escape
    parts = [
        "<!doctype html><html><head><meta charset='utf-8'>",
        f"<title>Source for {esc(fig_name)}</title>",
        "<style>",
        "body{font:14px/1.5 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;"
        "max-width:920px;margin:2rem auto;padding:0 1rem;color:#222}",
        "h1{font-size:1.3rem} h2{font-size:1rem;margin-top:1.6rem;border-bottom:1px solid #ddd;"
        "padding-bottom:.2rem}",
        ".loc{color:#888;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.85rem}",
        "pre{background:#f6f8fa;border:1px solid #e1e4e8;border-radius:6px;padding:.8rem;"
        "overflow:auto;font:12px/1.45 ui-monospace,Menlo,Consolas,monospace}",
        "ul.toc{padding-left:1.2rem} ul.toc a{text-decoration:none}",
        ".thirdparty{color:#666;font-size:.9rem;margin-top:2rem}",
        "</style></head><body>",
        f"<h1>Functions used to generate <code>{esc(fig_name)}</code></h1>",
        "<p>Auto-generated source listing. Project functions are shown in full; "
        "third-party / standard-library calls are noted but not reproduced.</p>",
    ]
    # Table of contents (anchor links to each in-repo function).
    if in_repo:
        parts.append("<ul class='toc'>")
        for i, (label, loc, _src) in enumerate(in_repo):
            parts.append(f"<li><a href='#fn-{i}'>{esc(label)}</a> "
                         f"<span class='loc'>{esc(loc)}</span></li>")
        parts.append("</ul>")
    # One source block per in-repo function.
    for i, (label, loc, src) in enumerate(in_repo):
        parts.append(f"<h2 id='fn-{i}'>{esc(label)}</h2>")
        parts.append(f"<p class='loc'>{esc(loc)}</p>")
        parts.append(f"<pre><code>{esc(src)}</code></pre>")
    # Third-party / unavailable: name + module + location, no source.
    if external:
        parts.append("<div class='thirdparty'><h2>Third-party / standard-library "
                     "(source not shown)</h2><ul>")
        for label, module, loc in external:
            tail = f" <span class='loc'>{esc(loc)}</span>" if loc else ""
            parts.append(f"<li>{esc(label)} &mdash; {esc(module)}{tail}</li>")
        parts.append("</ul></div>")
    parts.append("</body></html>")
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Paper-style figure formatting: panel letters + a fully-justified legend.
# ---------------------------------------------------------------------------
def panel_label(ax, letter: str, *, x: float = -0.08, y: float = 1.04,
                fontsize: int = 14) -> None:
    """Bold **14 pt** panel letter just above the top-left of an axes (axes-fraction
    coords; convention 2). Default ``y`` sits just above the axes (not up near a
    suptitle), so the letter clears the figure title on single-row layouts.
    """
    t = ax.text(x, y, letter, transform=ax.transAxes, fontsize=fontsize,
                fontweight="bold", va="bottom", ha="right", clip_on=False)
    t.set_gid("panel-letter")


_PANEL_REF = re.compile(r"\([A-Z](?:[,–-][A-Z])?\)")  # (A), (A,B), (A-D), (A–D)


def justified_legend(fig, title: str, body: str, *, x0: float = 0.06,
                     x1: float = 0.94, y_top: float | None = None, fontsize: float = 10,
                     line_spacing: float = 1.5, bottom_margin: float = 0.03,
                     min_fontsize: float = 8.0) -> float:
    """Render a paper-style figure legend: a **bold** ``title`` run followed by ``body``,
    fully justified between ``x0``..``x1`` (figure fraction), starting with the first
    line's top at ``y_top`` and growing downward (conventions 1 & 5).

    Panel references in ``body`` such as ``(A)`` / ``(A,B)`` / ``(A-D)`` are bold. Write
    the body as per-panel references -- ``(A) ... (B) ...`` -- naming exactly what each
    panel shows (axes, conditions, groups, pooling, time windows) plus a brief note on
    the analytical approach, so the figure stands alone. The last line is left-aligned
    (standard for justified paragraphs). Words are placed individually because matplotlib
    has no native full justification.

    Overlap safety (convention 3: a legend must NEVER obscure any panel/axis/figure text):
    - ``y_top=None`` (default) auto-places the legend's top just below the lowest panel
      text (tick labels / axis labels), so it cannot overlap the panels above it. Pass an
      explicit ``y_top`` only to override.
    - Body text renders at ``fontsize`` (default **10 pt**) and is shrunk only as far as
      ``min_fontsize`` (default **8 pt** -- the convention-6 floor) if needed so the whole
      block fits above ``bottom_margin``; it can never run off the bottom either. Size the
      reserved band (taller figure + ``fig.subplots_adjust(bottom=...)``) so it stays at
      the full 10 pt without shrinking.

    Returns the figure-fraction y below the last line.
    """
    fig.canvas.draw()
    rend = fig.canvas.get_renderer()
    figw, figh = fig.bbox.width, fig.bbox.height
    line_px = (x1 - x0) * figw

    runs = [(w, True) for w in title.split()]
    runs += [(w, bool(_PANEL_REF.fullmatch(w))) for w in body.split()]

    def _layout(fs):
        """Word widths + greedy line-wrap at font size ``fs``."""
        def _w(word, bold):
            t = fig.text(0, 0, word, fontsize=fs, fontweight="bold" if bold else "normal")
            w = t.get_window_extent(rend).width
            t.remove()
            return w
        space = max(_w("m m", False) - _w("mm", False), 2.0)
        widths = [_w(w, b) for w, b in runs]
        lines, cur, cur_w = [], [], 0.0
        for i in range(len(runs)):
            add = widths[i] + (space if cur else 0.0)
            if cur and cur_w + add > line_px:
                lines.append(cur)
                cur, cur_w = [i], widths[i]
            else:
                cur.append(i)
                cur_w += add
        if cur:
            lines.append(cur)
        return lines, widths, space

    # Auto-place below the lowest panel text so the legend never overlaps the panels.
    if y_top is None:
        ys = []
        for ax in fig.axes:
            try:
                bb = ax.get_tightbbox(rend)
            except Exception:
                bb = None
            if bb is not None and bb.height > 0:
                ys.append(bb.y0 / figh)
        y_top = (min(ys) if ys else 0.22) - 0.025

    # Shrink the font (to the 8 pt floor) until the block fits above ``bottom_margin``.
    fs = float(fontsize)
    while True:
        lines, widths, space = _layout(fs)
        line_h = fs * line_spacing * fig.dpi / 72.0 / figh     # fig-fraction per line
        if (y_top - len(lines) * line_h) >= bottom_margin or fs <= min_fontsize:
            break
        fs -= 0.5

    line_h_px = fs * line_spacing * fig.dpi / 72.0
    y = y_top * figh
    for li, line in enumerate(lines):
        wsum = sum(widths[i] for i in line)
        n = len(line)
        gap = space if (li == len(lines) - 1 or n == 1) else (line_px - wsum) / (n - 1)
        x = x0 * figw
        for i in line:
            word, bold = runs[i]
            t = fig.text(x / figw, y / figh, word, fontsize=fs,
                         fontweight="bold" if bold else "normal", ha="left", va="top")
            t.set_gid("legend")          # tag so check_text_overlaps groups the words
            x += widths[i] + gap
        y -= line_h_px
    return y / figh


# ---------------------------------------------------------------------------
# Automated text-overlap self-check (convention 3: no on-figure text may overlap
# another text or a panel). Run automatically by savefig / pdf_savefig.
# ---------------------------------------------------------------------------
def _intersection_area(a, b) -> float:
    """Area of the intersection of two display-space Bboxes (0 if disjoint)."""
    x0, x1 = max(a.x0, b.x0), min(a.x1, b.x1)
    y0, y1 = max(a.y0, b.y0), min(a.y1, b.y1)
    return (x1 - x0) * (y1 - y0) if (x1 > x0 and y1 > y0) else 0.0


def _overlap_frac(a, b) -> float:
    """Intersection area as a fraction of the SMALLER box (0..1)."""
    inter = _intersection_area(a, b)
    if inter <= 0:
        return 0.0
    m = min(a.width * a.height, b.width * b.height)
    return inter / m if m > 0 else 0.0


def _ax_name(ax, fig) -> str:
    """Human label for an axes: its panel letter if present, else its index."""
    for t in ax.texts:
        if t.get_gid() == "panel-letter" and t.get_text().strip():
            return f"panel {t.get_text().strip()}"
    try:
        return f"ax{fig.axes.index(ax)}"
    except ValueError:
        return "ax?"


def _text_snip(s: str, owner: str) -> str:
    snip = s.replace("\n", " ").strip()
    snip = (snip[:30] + "…") if len(snip) > 30 else snip
    return f'{owner} "{snip}"'


def check_text_overlaps(fig, *, overlap_frac: float = 0.15):
    """Return a list of overlapping on-figure text elements in a rendered ``fig``.

    Compares the **rendered** bounding boxes of every visible, non-empty text artist:
      * the justified-legend words (``gid='legend'``) are unioned into one "legend block"
        so their intended adjacency is never flagged;
      * a pair of texts with **different owners** (different panels, or panel-vs-caption)
        is flagged when they intersect by more than ``overlap_frac`` of the smaller box
        (so 1-px touches and same-panel tick spacing are ignored);
      * figure-level captions (legend / suptitle / source link) are additionally flagged
        when they intrude into any panel's data rectangle (catches a legend/caption drawn
        on top of a panel).

    Each item is ``{"a", "b", "frac", "category"}`` with human-readable labels. An empty
    list means no overlapping text. Pure inspection -- does not modify the figure.
    """
    from matplotlib.text import Text
    from matplotlib.transforms import Bbox

    fig.canvas.draw()
    rend = fig.canvas.get_renderer()

    # Exclude tick labels (major AND minor): tick-number crowding is a separate, noisier
    # concern, and on log axes the minor labels ("6x10^-1" ...) are plentiful.
    tick_ids = set()
    for ax in fig.axes:
        for minor in (False, True):
            for tl in (*ax.get_xticklabels(minor=minor), *ax.get_yticklabels(minor=minor)):
                tick_ids.add(id(tl))

    axbb = {}                                          # axes -> display bbox (cached)
    for ax in fig.axes:
        try:
            bb = ax.get_window_extent(rend)
            if bb.width > 0 and bb.height > 0:
                axbb[ax] = bb
        except Exception:
            pass

    def _contain(bb):
        """Smallest axes geometrically containing the bbox center (or None). Fixes inset /
        mathtext text artists that report no parent axes -- attribute them to where they sit
        so they are not mistaken for figure-level captions over their own panel."""
        cx, cy = (bb.x0 + bb.x1) / 2, (bb.y0 + bb.y1) / 2
        best, best_area = None, float("inf")
        for ax, ab in axbb.items():
            if ab.x0 <= cx <= ab.x1 and ab.y0 <= cy <= ab.y1:
                area = ab.width * ab.height
                if area < best_area:
                    best, best_area = ax, area
        return best

    suptitle = getattr(fig, "_suptitle", None)
    items, captions, legend_bboxes = [], [], []
    for t in fig.findobj(Text):
        if id(t) in tick_ids or not t.get_visible() or not t.get_text().strip():
            continue
        try:
            bb = t.get_window_extent(rend)
        except Exception:
            continue
        if bb.width <= 0 or bb.height <= 0:
            continue
        gid = t.get_gid()
        if gid == "legend":
            legend_bboxes.append(bb)                  # unioned into one caption below
        elif gid == "source-link":
            captions.append({"label": "source-link", "bbox": bb})
        elif t is suptitle:
            captions.append({"label": _text_snip(t.get_text(), "suptitle"), "bbox": bb})
        else:
            ax = t.axes or _contain(bb)               # geometric fallback for parent-less text
            owner = _ax_name(ax, fig) if ax is not None else "figure"
            items.append({"label": _text_snip(t.get_text(), owner), "ax": ax, "bbox": bb})
    if legend_bboxes:
        captions.append({"label": "legend block", "bbox": Bbox.union(legend_bboxes)})

    overlaps = []
    # text vs text -- captions act as ax-less items; skip pairs within the SAME panel
    # (their layout is intentional). Cross-panel, panel-vs-caption and caption-vs-caption
    # are all checked.
    pool = items + [{"label": c["label"], "ax": None, "bbox": c["bbox"]} for c in captions]
    for i in range(len(pool)):
        for j in range(i + 1, len(pool)):
            a, b = pool[i], pool[j]
            if a["ax"] is not None and a["ax"] is b["ax"]:
                continue
            frac = _overlap_frac(a["bbox"], b["bbox"])
            if frac >= overlap_frac:
                overlaps.append({"a": a["label"], "b": b["label"], "frac": frac,
                                 "category": "text-text"})

    # caption (legend / suptitle / source-link) intruding into a panel's data rectangle
    for cap in captions:
        ca = cap["bbox"].width * cap["bbox"].height
        if ca <= 0:
            continue
        for ax, ab in axbb.items():
            frac = _intersection_area(cap["bbox"], ab) / ca
            if frac >= overlap_frac:
                overlaps.append({"a": cap["label"], "b": f"{_ax_name(ax, fig)} data area",
                                 "frac": frac, "category": "text-over-panel"})
    return overlaps


def _report_overlaps(fig, label: str, sidecar) -> list:
    """Run :func:`check_text_overlaps`; print a loud report + write ``sidecar`` if any,
    or clear a stale sidecar if the figure is now clean. Returns the overlap list."""
    ov = check_text_overlaps(fig)
    sc = Path(sidecar) if sidecar is not None else None
    if ov:
        lines = [f"  - {o['a']}  ∩  {o['b']}  ({o['frac'] * 100:.0f}%, {o['category']})"
                 for o in ov]
        msg = f"⚠ TEXT OVERLAP in {label} ({len(ov)} found):\n" + "\n".join(lines)
        print(msg)
        if sc is not None:
            try:
                sc.write_text(msg + "\n")
            except Exception:
                pass
    elif sc is not None and sc.exists():
        try:
            sc.unlink()              # previously overlapping, now clean -> drop stale report
        except Exception:
            pass
    return ov


def pdf_savefig(pdf, fig, *, name=None, check_overlaps: bool = True, **kwargs) -> None:
    """Save ``fig`` as a page into an open :class:`~matplotlib.backends.backend_pdf.PdfPages`
    (multi-page figures), running the same text-overlap self-check as :func:`savefig`
    (prints a report; no sidecar, since pages share one PDF). Drop-in for
    ``pdf.savefig(fig)`` in ``PdfPages`` scripts. For provenance on multi-page PDFs, call
    :func:`write_code_listing` once and :func:`attach_source_link` on each page first.
    """
    if check_overlaps:
        _report_overlaps(fig, name or "PdfPages page", None)
    pdf.savefig(fig, **kwargs)


def _selftest_overlaps() -> bool:
    """Machinery check: a clean multi-panel figure reports 0 overlaps; a figure with two
    deliberately stacked texts reports >= 1."""
    plt.switch_backend("Agg")
    apply_style()
    fig, axes = plt.subplots(2, 2, figsize=(11, 9))
    fig.subplots_adjust(bottom=0.30, hspace=0.4, wspace=0.3)
    for ax, L in zip(axes.ravel(), "ABCD"):
        ax.plot([0, 1], [0, 1]); ax.set_xlabel("time (ms)"); ax.set_ylabel("rate (Hz)")
        ax.set_title(f"panel {L}"); panel_label(ax, L)
    fig.suptitle("Self-test figure", fontsize=12)
    justified_legend(fig, "Figure.", "(A) one. (B) two. (C) three. (D) four. " * 4)
    clean = check_text_overlaps(fig)
    print(f"clean figure -> {len(clean)} overlaps (expect 0)")
    for o in clean:
        print(f"   unexpected: {o['a']} ∩ {o['b']} ({o['frac']*100:.0f}%)")
    plt.close(fig)

    fig2 = plt.figure(figsize=(6, 4))
    fig2.text(0.50, 0.5, "OVERLAPPING TEXT A", ha="center", va="center", fontsize=26)
    fig2.text(0.54, 0.5, "OVERLAPPING TEXT B", ha="center", va="center", fontsize=26)
    dirty = check_text_overlaps(fig2)
    print(f"overlapping figure -> {len(dirty)} overlaps (expect >= 1)")
    plt.close(fig2)

    ok = (len(clean) == 0) and (len(dirty) >= 1)
    print("OVERLAP SELF-TEST:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        raise SystemExit(0 if _selftest_overlaps() else 1)
