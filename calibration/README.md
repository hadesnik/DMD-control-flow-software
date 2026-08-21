# calibration/

One folder per calibration session, named by date:
`calibration/<YYYY-MM-DD>_<session>/`.

Written by the guided bringup in `tfp.gui.CalibrationApp` (and by any
command-line session driving `tfp.gui.CalibrationSession.runStep`), one step at
a time as the session proceeds — not at the end, so the record survives a
crashed MATLAB or an operator who walks away mid-procedure.

| Path | What | Tracked? |
|---|---|---|
| `report.html` | the whole session: what was done, what was measured, the verdict and why | ✅ |
| `report.json` | the same, machine-readable | ✅ |
| `steps/<id>.json` | one step's verdict, checks and derived metrics | ✅ |
| `steps/<id>.mat` | that step's full result struct with provenance | ❌ gitignored |
| `figures/<id>.png` | the step's plot (also embedded in `report.html`) | ✅ |
| `figures/<id>.pdf` | vector copy of the same plot | ✅ |

**Why the split.** What the scale was on the day an experiment ran is not
recoverable from anything else, so the readable record belongs in version
control. The `.mat` payloads carry camera stacks and sweep data and would grow
the repo without adding anything a reader can use — they stay local, alongside
`data/`.

`report.html` is self-contained (inline CSS, figures embedded as data URIs), so
it can be copied off the rig PC and opened anywhere.

Saved calibration `.mat` files that the rig config *points at* are a different
thing and still live under `data/calibration/` via `tfp.io.saveCalibration`;
this folder is the human record of the session that produced them.
