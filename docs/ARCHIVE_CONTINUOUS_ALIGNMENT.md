# Archive: continuous-alignment design (pre-episodic switch)

**Snapshot date:** 2026-05-23
**Tag:** `archive/continuous-alignment-2026-05-23`
**Branch:** `archive/continuous-alignment`
**Snapshotted commit:** `349bb06` ("PPSF: enforce single near-central target; unify stim radius to 14 px")

---

## Why this archive exists

Before switching to **episodic ScanImage acquisition (one TIFF per trial, triggered
by a per-trial start-acquisition TTL)**, we preserved the prior **continuous
alignment** design so it can be diffed against, partially restored, or fully
reverted to if the episodic approach hits unforeseen problems at the rig.

## What "continuous alignment" means

In the snapshotted design, ScanImage and the DAQ both ran **continuously for the
whole experiment** and trial → frame alignment was reconstructed post-hoc from
two parallel signals:

- **Path (a) out-pulse:** DAQ pulsed a single DO line (`port0/line10`) once at
  session start and once at each trial onset. ScanImage was to record this on an
  aux DI input.
- **Path (b) in-capture:** DAQ continuously captured ScanImage's frame-clock
  TTL on `port0/line2`. Alignment rule was "Nth rising edge in the captured DI
  vector = Nth frame in ScanImage's TIFF."

The catastrophic-failure concern with this design (and the reason for the
switch) is that **any single edge slip in the captured DI corrupts every trial
after the slip** — there is no per-trial re-anchoring in path (b) alone.

## Files central to the archived design

| File | Role in the archived design |
|---|---|
| [docs/SYNC_FRAME.md](SYNC_FRAME.md) | Full architectural spec: continuous DAQ session, two timestamp paths, frame-clock encoding, trial schema fields |
| [src/+tfp/+io/decodeFrameClock.m](../src/+tfp/+io/decodeFrameClock.m) | Detect frame-clock rising edges in a DI vector |
| [src/+tfp/+io/alignTrialsToFrames.m](../src/+tfp/+io/alignTrialsToFrames.m) | Window-based per-trial → frame index assignment (path b) |
| [src/+tfp/+experiments/exp_ensemble_activation.m](../src/+tfp/+experiments/exp_ensemble_activation.m) | Continuous-session ensemble experiment |
| [src/+tfp/+experiments/exp_ensemble_fill_factor_power.m](../src/+tfp/+experiments/exp_ensemble_fill_factor_power.m) | Continuous-session fill-factor sweep with `sendDigitalPulse` for path (a) |
| [tests/test_sync_endtoend_mock.m](../tests/test_sync_endtoend_mock.m) | T-SYNC-13 integration test |
| [src/+tfp/+hardware/DAQ.m](../src/+tfp/+hardware/DAQ.m) (`startContinuousSession`, `stopContinuousSession`, `queueClockedAO`, `currentSampleIndex`, `sendDigitalPulse`) | DAQ-side continuous-session API |

Note that the continuous **DAQ** session is expected to remain in the episodic
design (the DAQ keeps acquiring AI / DI / driving AO continuously); only
ScanImage switches from continuous to per-trial-triggered acquisition. So most
of the files above continue to be used; what changes is the alignment role of
path (a)/(b) and the ensemble experiments' per-trial structure.

## How to recover

Diff the current state against the archive:
```bash
git diff archive/continuous-alignment-2026-05-23 -- docs/SYNC_FRAME.md
git diff archive/continuous-alignment-2026-05-23 -- src/+tfp/+io/alignTrialsToFrames.m
```

Cherry-pick a single archived file back onto the working branch:
```bash
git checkout archive/continuous-alignment-2026-05-23 -- src/+tfp/+io/alignTrialsToFrames.m
```

Full revert to the archived design (destructive; only if episodic is abandoned):
```bash
git switch -c restore-continuous archive/continuous-alignment
# review, then merge or fast-forward main
```

The tag is immutable; the branch is for browsing. Neither is pushed to the
remote by default — `git push origin archive/continuous-alignment
archive/continuous-alignment-2026-05-23` if you want to share.

## Related

- TODO.md C9 (the pre-archive item) proposed a *hybrid* aligner that kept the
  continuous design but flipped paths (a)/(b) so path (a) became the primary
  anchor. The episodic switch supersedes that proposal entirely.
