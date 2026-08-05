# Episodic ScanImage acquisition and per-trial alignment

**Status:** Design-locked 2026-05-23 (TASK-EP, T-EP-0). Locks the
contracts implemented by the Wave-2 coding round (T-EP-1a … T-EP-1d).
No code is changed in this round; only signatures, schema, and
documented contracts.

**See also:** [SYNC_FRAME.md](SYNC_FRAME.md) — the *superseded*
continuous-acquisition design. Sections of that document remain
load-bearing (DAQ master-clock model and the continuous-session API
contracts); other sections are explicitly replaced here. The archival
banner at the top of SYNC_FRAME.md enumerates which sections still
apply. [SYNC.md](SYNC.md) describes the (separate) PLM↔ScanImage
trigger architecture and is not affected by this switch.

**Migration tag:** the prior continuous design is preserved at git tag
`archive/continuous-alignment-2026-05-23`; see
[ARCHIVE_CONTINUOUS_ALIGNMENT.md](ARCHIVE_CONTINUOUS_ALIGNMENT.md).

---

## 1. Overview

ScanImage is no longer run continuously across an experiment. Instead,
ScanImage is **armed for external trigger per trial**: each trial fires
a TTL pulse from the DAQ that starts a fresh ScanImage acquisition of
`N` frames, ScanImage writes one TIFF per trial, and trial-N's frames
are exactly the contents of trial-N's TIFF. Alignment between stim and
imaging frames collapses from a global problem ("which rising edge in
the captured frame clock is the Nth frame ScanImage saved?") to a
per-trial bookkeeping problem ("which TIFF did this trial produce?").

*Why this switch.* The prior design (see SYNC_FRAME.md) ran ScanImage
continuously and aligned stim to frames by the rule *"the Nth rising
edge in the captured frame-clock DI corresponds to the Nth frame in
ScanImage's TIFF."* A single dropped frame, spurious DI edge, or
ScanImage buffer underrun then corrupts every trial *after* the slip —
there is no per-trial re-anchoring. Trials in this project are always
≥2 s long (set by GCaMP kinetics), so ScanImage's external-trigger arm
latency (~50–100 ms) is well under 5% of a trial. With episodic
acquisition, each trial is anchored to its own start-acq TTL, and a
frame drop or trigger glitch is bounded to a single trial. The
frame-clock DI is still captured and decoded, but its role demotes from
**primary alignment anchor** to **per-trial cross-check**.

---

## 2. Architecture

DAQ remains the timing master with one continuous session for the whole
experiment. ScanImage is the slave and is armed *per trial* for an
external-trigger acquisition of a fixed frame count. The two clocks are
re-anchored at every trial boundary.

```
                                                    Imaging PC
DAQ PC (timing master)                              (ScanImage)
┌────────────────────────────────┐                  ┌──────────────────┐
│ continuous DAQ session         │                  │  external-trig   │
│  - AI / DI sampled at master   │                  │  acquisition,    │
│    clock (e.g. 100 kHz)        │                  │  N frames per    │
│  - clocked AO queued per trial │                  │  TTL,            │
│  - DO pulses on demand         │                  │  one TIFF per    │
│                                │                  │  acquisition     │
│  port0/line2  (DI) ◀───────────│──── frame-clock TTL out (existing)
│  port0/line10 (DO) ───────────►│──── start-acq TTL in (one per trial)
│  port0/line0  (DO) ───────────►│──── operator sync (long pulse at session start)
└────────────────────────────────┘                  └──────────────────┘
```

### 2.1 Timing diagram

Nominal values: master DAQ clock 100 kHz, ScanImage 30 Hz, trial duration
~2 s, start-acq pulse 200 µs wide, session-start pulse 100 ms wide.
Diagram not to scale.

```
DAQ master clock (sample index k, 100 kHz):
═══════════════════════════════════════════════════════════════════════════►

session-start DO (port0/line0, operator-visible, ONE long pulse per session):
   ┌──────────┐
───┘          └──────────────────────────────────────────────────────────────
   ▲
   sessionStartDatetime captured here

start-acq DO (port0/line10, ONE short pulse per trial — the per-trial anchor):
                          ┌┐                           ┌┐
──────────────────────────┘└───────────────────────────┘└────────────────────
                          ▲                            ▲
                          trial N start                trial N+1 start
                          (k = t_onset_daq_samples)

ScanImage acquisition state (slave, externally triggered):
                          ┌──────  N frames ──────┐   ┌──────  N frames ──────┐
                          │  TIFF_N.tif written   │   │  TIFF_{N+1}.tif       │
──────────────────────────┘                       └───┘                       └

Frame-clock DI (port0/line2, captured continuously by DAQ; per-trial cross-check):
                              │  │  │  │  ...  │  │     │  │  │  │  ...  │  │
                              ▼  ▼  ▼  ▼       ▼  ▼     ▼  ▼  ▼  ▼       ▼  ▼

Clocked AO (Pockels / laser gate, queued per trial):
                              [== stim window ==]      [== stim window ==]
                              k_on            k_off

Trial onset/offset markers (DAQ samples; canonical sample anchors):
                          ▲                  ▲         ▲                  ▲
                  t_onset_daq_samples  t_offset_daq_samples
```

Notes on the diagram:
- The start-acq TTL leading edge defines the trial's onset on the imaging
  side; the clocked-AO sample index defines the stim window on the DAQ
  side. The two anchors are independent and are cross-checked
  post-trial by comparing the count of frame-clock DI edges in the
  stim window to the TIFF's frame count.
- The frame-clock DI runs continuously and is decoded by
  `tfp.io.decodeFrameClock` exactly as before. Its rising edges are no
  longer used to *name* frames — TIFF index does that — but they
  remain the highest-precision way to localise frames within the DAQ
  master clock for the cross-check.

---

## 3. Per-trial flow

The Sequencer MUST execute the following calls in the exact order
below, on every trial. Italicised tags mark blocking vs non-blocking.

1. `bridge.armForExternalTrigger(nFrames)` — *blocking, ≤ obj.armTimeoutS_*.
   Tells ScanImage how many frames the next TIFF will contain and puts
   the imaging PC in "waiting for trigger" state. Must complete before
   the start-acq TTL is fired or the trigger will be missed.
2. `bridge.setActivePattern(mask, stimOnsetSec, stimDurationSec)` —
   *blocking, non-time-critical*. Sends stim metadata over the
   metadata channel (msocket / TCP / no-op depending on mode). MAY be
   omitted in ttl_only mode.
3. `bridge.clearLiveTraces()` (optional) — *non-blocking*. Reset live-F
   accumulator if streaming is enabled.
4. `onsetSample = daq.queueClockedAO(samples, rate, 'immediate')` —
   *non-blocking* (returns immediately with the start-sample index;
   the AO begins on the next clock boundary).
5. `daq.sendDigitalPulse(cfg.startAcqDOLine, cfg.startAcqPulseS)` —
   *blocking for the pulse duration* (~200 µs). This is the per-trial
   start-acq TTL; its leading edge is the imaging anchor. MUST be
   issued *after* `armForExternalTrigger` so ScanImage is ready.
6. `trial.markRunning(onsetSample, sampleRate, sessionStartDatetime)` —
   record the canonical DAQ-sample anchor.
7. `bridge.waitForCompletion(cfg.trialTimeoutS)` — *blocking, up to
   `cfg.trialTimeoutS`*. Returns when ScanImage has written the TIFF;
   throws `tfp:hardware:ScanImageBridge:acquisitionTimeout` on
   overrun.
8. `offsetSample = daq.currentSampleIndex()` — capture trial-offset
   anchor.
9. `siTiffPath = bridge.getLastTiffPath()` — return the absolute path
   to the TIFF this trial produced.
10. `trial.markComplete(data, offsetSample, siTiffPath)` — close the
    trial and record the TIFF path.

The post-session aligner (`tfp.io.alignTrialsEpisodic`, §7) is run
after the whole session ends; it populates the post-hoc fields via
`Trial.attachEpisodicAlignment(...)`.

**Ordering rationale.** ScanImage's external-trigger arm latency is
50–100 ms in practice (observed; `%VERIFY` on the rig); the start-acq
TTL must arrive after that latency has elapsed. The Sequencer
guarantees this by completing `armForExternalTrigger` (which blocks on
its own metadata handshake) before issuing the pulse. `queueClockedAO`
is issued *before* the TTL because the AO start-sample index is the
canonical DAQ anchor for the trial — it must be captured before any
event that could perturb the sample counter.

---

## 4. Continuous DAQ session config (unchanged)

The DAQ side of the architecture is **unchanged** from SYNC_FRAME.md.
In particular, all four continuous-session API contracts in
SYNC_FRAME.md §4 remain load-bearing and are not restated here:

- §4.1 `startContinuousSession(cfg)`
- §4.2 `stopContinuousSession()`
- §4.3 `currentSampleIndex()`
- §4.4 `queueClockedAO(samples, rate, startTrigger)`

The DAQ master-clock model in SYNC_FRAME.md §2 (single hardware clock
per experiment, 1-based sample indices, `sessionStartDatetime` anchor)
also remains the source of truth.

The frame-clock DI encoding contract in SYNC_FRAME.md §5 remains the
on-wire spec for the rising-edge train coming back from ScanImage. The
only change is in how those edges are *consumed*: §7 below describes
the cross-check usage that replaces the "Nth-edge = Nth frame" rule
from SYNC_FRAME.md §6.2.

**New config keys (added in this round):**

| Key | Type | Default | Meaning |
|---|---|---|---|
| `startAcqDOLine` | char | `'port0/line10'` | DO line that fires the per-trial start-acq TTL into ScanImage. Already present in `configs/real.yaml`. |
| `startAcqPulseS` | double | `2e-4` (200 µs) | Width of the start-acq pulse. ScanImage requires only a clean rising edge; 200 µs is well above any plausible debounce/min-width. |
| `framesPerTrial` | uint32 | (no default) | Number of frames ScanImage MUST acquire on each trigger. Computed from `(trial.preStim_s + trial.duration_s + trial.postStim_s) * frameRate` at experiment setup. |
| `armTimeoutS` | double | `5.0` | How long `armForExternalTrigger` is allowed to block before throwing `armTimeout`. |
| `trialTimeoutS` | double | `2 * framesPerTrial / frameRate` (computed) | How long `waitForCompletion` is allowed to block before throwing `acquisitionTimeout`. |

The legacy `cfg.trialOnsetPulseS` and the per-trial `syncDOLine`
onset pulses are **removed** from the Sequencer. Only the session-start
long pulse on `syncDOLine` survives (operator visual sanity).

---

## 5. Trial schema additions

The Phase-1 DAQ-sample anchors in SYNC_FRAME.md §6.1 are unchanged.
The frame-alignment fields in SYNC_FRAME.md §6.2 are **superseded** by
the three new fields and the new method below. Existing trial files
that lack the new fields load with defaults (NaN / empty string).

### 5.1 New properties (`SetAccess = private` on `tfp.trial.Trial`)

| Field | Type | Unit | Source | Notes |
|---|---|---|---|---|
| `siTiffPath` | char | absolute path | `markComplete(..., siTiffPath)` | Absolute path on the imaging-PC filesystem to the TIFF saved by ScanImage for this trial. `''` if `bridge.getLastTiffPath()` returned empty (e.g. `ttl_only` mode). The path may or may not be reachable from the DAQ PC depending on whether a network share is mounted; downstream analysis is responsible for path translation. |
| `alignmentDiscrepancy` | int32 / NaN | frames | `attachEpisodicAlignment(...)` | `nFramesInTiff − nFrameClockEdgesInStimWindow`. Sign convention: positive means TIFF has more frames than the DI saw. Computed only when both the TIFF metadata and the frame-clock decode are available; NaN otherwise. |
| `alignmentConfidence` | char | enum | `attachEpisodicAlignment(...)` | One of `'high'`, `'low'`, `'quarantine'`, or `''` (not yet aligned). Tier rules in §7.2. |

### 5.2 Extended `markComplete` signature

```matlab
markComplete(obj, data)                            % legacy, unchanged
markComplete(obj, data, offsetSample)              % SYNC_FRAME.md, unchanged
markComplete(obj, data, offsetSample, siTiffPath)  % NEW (T-EP-1a)
```

- The 4-arg form records `t_offset_daq_samples` AND `siTiffPath` and
  then transitions to `'complete'`.
- `siTiffPath` MUST be a char row vector. Empty string is allowed and
  means "no TIFF available" (mock or ttl_only).
- All prior `markComplete` semantics carry forward (state transition
  validation, throws `tfp:trial:Trial:badTransition` on invalid moves).

### 5.3 New method `attachEpisodicAlignment`

```matlab
attachEpisodicAlignment(obj, alignmentDiscrepancy, alignmentConfidence)
```

- **Pre-condition.** `obj.status == 'complete'`. Otherwise throws
  `tfp:trial:Trial:badTransition`.
- **Inputs.** `alignmentDiscrepancy` is a numeric scalar (cast to
  `int32` internally; NaN preserved as NaN sentinel via the int32→NaN
  rule of `NaN` ⇒ `intmin('int32')` is **not** acceptable — store NaN
  as a double sentinel on the property; the property type is mixed
  `int32 | NaN` exactly because of this).
  `alignmentConfidence` is one of `'high'`, `'low'`, `'quarantine'`.
- **Post-condition.** The two new fields are populated. `siTiffPath`
  was already populated by `markComplete`; this method does NOT touch
  it.
- **Idempotence.** Calling twice with identical arguments is allowed;
  calling with different arguments throws
  `tfp:trial:Trial:episodicAlignmentMismatch`.
- **Errors.**
  - `tfp:trial:Trial:badTransition` — wrong status.
  - `tfp:trial:Trial:badAlignmentConfidence` — value not in the enum.
  - `tfp:trial:Trial:episodicAlignmentMismatch` — re-applied with a
    different value.

The legacy method `attachFrameAlignment(...)` (SYNC_FRAME.md §6.3)
remains on `Trial` for back-compat; new code MUST NOT call it. It will
be removed once all callers are migrated (tracked in TASKS.md TASK-EP
Round 5).

---

## 6. TIFF metadata reader contract

The aligner needs to know how many frames each trial's TIFF contains
and (optionally) per-frame timestamps. A new helper provides this in
one call so the aligner does not depend on ScanImage internals.

### 6.1 Signature

```matlab
meta = tfp.io.readScanImageTiff(tiffPath)
```

### 6.2 Output struct shape

```matlab
meta.numFrames        % uint32 — total frames written to this TIFF.
                     %   For multi-channel TIFFs, counts FRAMES (i.e. time
                     %   points), not IFDs: numIFDs / numChannels.
meta.numChannels      % uint32 — channels saved per frame (≥1).
meta.frameRateHz      % double — frame rate read from the ScanImage
                     %   header (hSI.hRoiManager.scanFrameRate or the
                     %   ScanImage-version-equivalent property). NaN if
                     %   unrecoverable.
meta.frameTimestamps_s% nFrames x 1 double — per-frame timestamps in
                     %   seconds since acquisition start. Sourced from
                     %   ScanImage's per-frame header if available
                     %   ('frameTimestamps_sec' in the SI struct);
                     %   otherwise synthesised as
                     %   linspace(0, (nFrames-1)/frameRateHz, nFrames).
                     %   The `timestampsAreSynthesised` flag indicates
                     %   which branch was taken.
meta.timestampsAreSynthesised  % logical
meta.sourceTiff       % char — absolute path echoed from the input.
meta.scanImageVersion % char — version string parsed from the TIFF
                     %   header, or '' if not present.
```

### 6.3 Implementation expectations

- Prefer `scanimage.util.opentif(tiffPath)` when the ScanImage MATLAB
  package is on the path (it parses the full ScanImage header). Fall
  back to `imfinfo(tiffPath)` + the ScanImage MEX-free parser of the
  ImageDescription field when not available.
- Multi-channel handling: ScanImage stores channels as interleaved
  IFDs (channel-major within a frame). `meta.numFrames` MUST be
  `numIFDs / meta.numChannels`. If the division has a remainder the
  function throws `tfp:io:readScanImageTiff:badIfdCount`.
- Reading the pixel data is NOT in this contract; the aligner only
  needs the header. Heavy I/O stays out of the aligner's loop.

### 6.4 ScanImage version dependency

ScanImage's TIFF header schema is stable across 5.x/2020+ but the
exact property names for `frameRateHz` and per-frame timestamps drift.
The function MUST handle both `hSI.hRoiManager.scanFrameRate` (the
modern path) and the older `hSI.hScan2D.scanFrameRate`; if neither is
present in the header, return `NaN` and continue.

**Imaging-PC version confirmed (2026-08-05): SI2019bR0**
(`C:\Program Files\Vidrio\SI2019bR0_2020-01-08-110731_4d721e971c`).
`hSI.hRoiManager.scanFrameRate` exists at
`+scanimage/+components/RoiManager.m:25` (a dependent property derived
from `scanFramePeriod`), so the modern path is the live one on this rig.
Keep the `hScan2D` fallback for TIFFs written by other/older installs.
The remaining `%VERIFY` is which of the two the *header* of an actual
saved TIFF carries — settled by reading one real trial TIFF, not by
inspecting the running object.

### 6.5 Errors

- `tfp:io:readScanImageTiff:notFound` — `tiffPath` does not exist.
- `tfp:io:readScanImageTiff:badIfdCount` — IFD count not divisible by
  channel count.
- `tfp:io:readScanImageTiff:unreadable` — `imfinfo`/`opentif`
  threw on the file (corrupt TIFF, partial write).

---

## 7. Aligner contract

The new aligner replaces `tfp.io.alignTrialsToFrames`. Its public
contract is fixed; Wave-2 agent T-EP-1b implements it.

### 7.1 Signature

```matlab
report = tfp.io.alignTrialsEpisodic( ...
            trials, tiffPaths, frameStartSamples, sampleRate)
```

**Inputs:**
- `trials` — 1×N vector of `tfp.trial.Trial` objects. MAY be empty.
  Trials with `status ~= 'complete'` are skipped (their result row in
  the report carries `alignmentConfidence == 'quarantine'` and
  `reason == 'incompleteTrial'`).
- `tiffPaths` — `cellstr` of length N (one TIFF per trial, by trial
  index). Empty string `''` allowed for trials with no TIFF (mock,
  ttl_only) — handled as `alignmentConfidence == 'quarantine'`,
  `reason == 'missingTiff'`.
- `frameStartSamples` — output of `tfp.io.decodeFrameClock` on the
  whole-session frame-clock DI. Numeric vector, cast to `uint64`
  internally.
- `sampleRate` — DAQ master clock rate in Hz; matches each trial's
  `daq_master_sample_rate_hz`. Used only as a sanity check; a
  mismatch raises `tfp:io:alignTrialsEpisodic:sampleRateMismatch`.

**Output:**

```matlab
report.perTrial          % 1xN struct array with fields:
                        %   .trialIdx               (echoed)
                        %   .tiffPath               (echoed; '' if missing)
                        %   .nFramesInTiff          uint32, 0 if missing
                        %   .nFrameClockEdgesInWindow uint32
                        %   .alignmentDiscrepancy   int32 (NaN if not
                        %                            computable)
                        %   .alignmentConfidence    char ('high'|'low'
                        %                            |'quarantine')
                        %   .reason                 char ('' for high/low;
                        %                            'missingTiff' |
                        %                            'incompleteTrial' |
                        %                            'discrepancyTooLarge'
                        %                            for quarantine)
report.session.nTrials             % numel(trials)
report.session.nHigh               % count by tier
report.session.nLow
report.session.nQuarantined
report.session.fatal               % logical; see §7.3
report.session.fatalReason         % char; '' when fatal == false
```

### 7.2 Confidence tiers

Let `d = nFramesInTiff − nFrameClockEdgesInWindow` (signed `int32`).

| Tier | Rule | Action |
|---|---|---|
| `'high'` | `|d| ≤ 1` | Trial proceeds to analysis. The ±1 tolerance absorbs the well-known one-frame ambiguity at window edges (a frame whose rising edge falls within ½ frame of `t_onset_daq_samples` or `t_offset_daq_samples` may land on either side of the inclusive comparison). |
| `'low'` | `1 < |d| ≤ 5` | Trial proceeds but is flagged. Downstream analysis MAY exclude these depending on the question. A warning `tfp:io:alignTrialsEpisodic:lowConfidence` is issued once per session. |
| `'quarantine'` | `|d| > 5`, OR `tiffPath == ''`, OR trial not complete | Trial is excluded from analysis. The TIFF (if any) is still preserved; the quarantine status only affects whether the aligner publishes the alignment to the trial. |

The aligner MUST call
`trial.attachEpisodicAlignment(d, tier)` on every trial that reached
`'complete'` and had a TIFF (i.e. tiers `'high'` and `'low'`).
Quarantined trials are NOT updated (their `alignmentConfidence`
remains `''`).

### 7.3 Session-level assertions and fatal report

The aligner issues a **fatal** report (`report.session.fatal == true`)
and returns *without* calling `attachEpisodicAlignment` on any trial
when:

- More than 50% of trials would be quarantined for non-missing reasons
  (`discrepancyTooLarge`). This means the cross-check is broken
  globally — frame-clock wiring lost, ScanImage running free-running
  instead of triggered, etc.
- `frameStartSamples` is non-monotonic.
- `sampleRate` disagrees with any trial's
  `daq_master_sample_rate_hz` by more than 1 ppm.

`fatalReason` enumerates the cause. The Sequencer's session-finalize
hook MUST check `report.session.fatal` and write the report to the
session log even on fatal exit — the operator needs the diagnostic.

### 7.4 Errors

- `tfp:io:alignTrialsEpisodic:badTrials` — `trials` not a
  `tfp.trial.Trial` array (or empty).
- `tfp:io:alignTrialsEpisodic:badPaths` — `tiffPaths` length ≠
  `numel(trials)` or not a `cellstr`.
- `tfp:io:alignTrialsEpisodic:badFrames` — `frameStartSamples` not a
  numeric vector, or non-monotonic (raised as fatal in the report
  rather than thrown — see §7.3 — but a non-vector shape throws).
- `tfp:io:alignTrialsEpisodic:sampleRateMismatch` — per-trial
  `daq_master_sample_rate_hz` differs from `sampleRate` (>1 ppm).

---

## 8. Cross-check contract

This section pins down how `nFrameClockEdgesInWindow` is computed so
two independent implementations cannot disagree.

### 8.1 Stim-window sample bounds

The cross-check window for trial *i* is

```
[t_onset_daq_samples(i), t_offset_daq_samples(i)]   inclusive both ends
```

— exactly the same window used for `frame_indices_during_stim` in
SYNC_FRAME.md §6.2. The window is inclusive of both endpoints; a frame
whose rising edge lands exactly on `t_offset_daq_samples` counts.

When a trial has `t_offset_daq_samples` missing (NaN) the window
degenerates to a zero-length point window `[t_onset, t_onset]` and the
trial is forced to `'quarantine'` with reason `'incompleteTrial'`.

### 8.2 Edge counting

```matlab
nFrameClockEdgesInWindow = ...
    sum(frameStartSamples >= t_onset & frameStartSamples <= t_offset)
```

`frameStartSamples` and the trial bounds are both `uint64`; the
comparison is in unsigned integer space and there is no rounding.

### 8.3 TIFF frame count

`nFramesInTiff = meta.numFrames` from
`tfp.io.readScanImageTiff(tiffPath)`. The aligner MUST NOT read pixel
data; only the header.

### 8.4 Discrepancy

```matlab
alignmentDiscrepancy = int32(nFramesInTiff) - int32(nFrameClockEdgesInWindow)
```

Stored as signed `int32` so positive == "TIFF has more frames than DI
saw" (the usual direction when ScanImage acquires a partial
trailing-edge frame the DI didn't yet emit a pulse for).

### 8.5 Behaviour on fatal mismatch

If the *session-level* checks in §7.3 fire, the aligner returns
without calling `attachEpisodicAlignment` on any trial — no partial
alignment is published. The per-trial entries in `report.perTrial` are
still populated so the operator can see the per-trial discrepancies
for debugging. Trials remain in `status == 'complete'` with their
`alignmentDiscrepancy` and `alignmentConfidence` fields at defaults
(NaN / `''`).

---

## 9. ScanImageBridge episodic API contract (LOCKED)

This contract is the surface that Wave-2 agents T-EP-1c (`MockScanImageBridge`)
and T-EP-1d (`ScanImageBridge`) implement independently. The two
implementations MUST agree on all signatures, state-machine
transitions, and error identifiers below.

### 9.1 State machine

Each bridge instance carries a private state variable `state_` with
values:

```
'idle'      — initial; no acquisition pending or in flight. Also the
              state before beginSession() is called (session-level
              fields unset).
'armed'     — armForExternalTrigger has returned successfully; ready
              for the start-acq TTL.
'acquiring' — start-acq TTL has been observed (mock: simulated
              immediately at armForExternalTrigger return + a flag set
              when the Sequencer calls a notify-style hook; real:
              detected by the bridge polling ScanImage acqState).
'completed' — waitForCompletion returned; getLastTiffPath is callable.
```

A separate boolean `sessionActive_` (initialised to `false`) gates
`armForExternalTrigger`; see §9.2. The state machine is per-trial,
`sessionActive_` is per-session. Both are reset by `disconnect()`.

State transitions (only legal moves):
```
idle      -> armed       (armForExternalTrigger ok; requires
                          sessionActive_ == true)
armed     -> acquiring   (Sequencer fires the TTL; for mock, a notify
                          hook; for real, polled)
acquiring -> completed   (waitForCompletion ok)
completed -> idle        (getLastTiffPath ok)
*         -> idle        (disconnect / reset; also clears
                          sessionActive_ and session snapshot fields)
```

### 9.2 `beginSession(opts)`

```matlab
sessionInfo = beginSession(obj, opts)
```

Called once per experiment, immediately after the operator has
configured ScanImage (selected save directory, set logFileStem,
configured external-trigger mode) and immediately before the Sequencer
starts running trials. Snapshots the ScanImage acquisition counter and
file-naming context so each subsequent trial's TIFF path is
deterministically derivable.

- **Pre.** `state_ == 'idle'`. `sessionActive_ == false`.
- **Post.** `state_ == 'idle'`. `sessionActive_ == true`. The following
  private fields are populated and MUST NOT be mutated for the duration
  of the session:
  - `startAcqNum_` (uint32) — value of ScanImage's acquisition counter
    (`hSI.hScan2D.logFileCounter`) at the moment of the call. Trial *i*
    (1-based) will land at acquisition number `startAcqNum_ + i - 1`.
  - `logFileStem_` (char) — value of `hSI.hScan2D.logFileStem`.
  - `logFileSaveDir_` (char) — value of `hSI.hScan2D.logFilePath`.
    Confirmed on SI2019bR0 at `+scanimage/+components/Scan2D.m:55`.
  - `acqNumWidth_` (uint8) — zero-pad width of the acquisition-number
    field in the filename. Default `5`, **confirmed against the
    installed SI2019bR0** (2026-08-05): `+scanimage/+components/
    Photostim.m:2254` uses `sprintf('_%05d', logFileCounter)`. MUST NOT
    be changed mid-session.
  - `trialCounter_ = 0` (uint32).
- **Inputs.** `opts` struct, all optional:
  - `opts.startAcqNumOverride` (uint32) — for tests; bypass ScanImage
    query and force the snapshot value. Mock bridge ignores ScanImage
    and uses this if present, else `1`.
  - `opts.logFileStemOverride`, `opts.logFileSaveDirOverride` (char) —
    same role for the other two fields.
- **Returns.** `sessionInfo` — struct echoing the four snapshot fields
  (`startAcqNum`, `logFileStem`, `logFileSaveDir`, `acqNumWidth`) plus
  `sessionStartDatetime` (datetime, captured at the call). The
  Sequencer SHOULD persist this into its session-metadata YAML so the
  per-trial TIFF paths can be reconstructed from disk after a crash.
- **Blocking.** Yes, briefly, for the ScanImage property reads. Bounded
  by `obj.armTimeoutS_`.
- **Why this is non-destructive.** The bridge MUST NOT write to
  `hSI.hScan2D.logFileCounter`. Resetting the counter would mutate
  operator-visible state and could collide with prior sessions if the
  same save directory were reused; instead we record the baseline and
  derive paths relative to it. The operator's existing workflow
  (selecting a fresh save directory per session) provides isolation
  from any prior session on the imaging PC.
- **Errors.**
  - `tfp:hardware:ScanImageBridge:badState` — `state_ ~= 'idle'` or
    `sessionActive_ == true`.
  - `tfp:hardware:ScanImageBridge:siQueryFailed` — could not read one
    of the three ScanImage properties (timeout or msocket error).

### 9.3 `armForExternalTrigger(nFrames)`

```matlab
armForExternalTrigger(obj, nFrames)
```

- **Pre.** `state_ == 'idle'`. `sessionActive_ == true` (i.e.
  `beginSession()` has been called for this session). `nFrames` is a
  positive finite scalar.
- **Post.** `state_ == 'armed'`. `nFrames_` stored.
  `trialCounter_` incremented by 1. For `ScanImageBridge` in
  `msocket` mode this also completes the A/B handshake (per
  SYNC_FRAME.md §3 — unchanged).
- **Blocking.** Yes. May block up to `armTimeoutS_` (config field,
  default 5 s) while waiting for the metadata handshake.
- **Returns.** Nothing.
- **Errors.**
  - `tfp:hardware:ScanImageBridge:badState` — `state_ ~= 'idle'` or
    `sessionActive_ == false`.
  - `tfp:hardware:ScanImageBridge:badNFrames` — `nFrames` invalid.
  - `tfp:hardware:ScanImageBridge:armTimeout` — handshake did not
    complete within `armTimeoutS_`.

### 9.4 `waitForCompletion(timeoutS)`

```matlab
waitForCompletion(obj, timeoutS)
```

- **Pre.** `state_ ∈ {'armed', 'acquiring'}`. The Sequencer is allowed
  to call `waitForCompletion` immediately after firing the start-acq
  TTL without observing the transient `'acquiring'` state — the
  bridge MUST tolerate that.
- **Post.** `state_ == 'completed'`. Implementations MUST internally
  set `lastTiffPath_` before returning.
- **Blocking.** Yes. Up to `timeoutS` seconds.
- **Returns.** Nothing.
- **Errors.**
  - `tfp:hardware:ScanImageBridge:badState` — `state_` not in the
    allowed set.
  - `tfp:hardware:ScanImageBridge:acquisitionTimeout` — TIFF write
    did not complete within `timeoutS`. `state_` is set to `'idle'`
    (the trial is dead; no partial recovery attempted) before
    throwing.

### 9.5 `getLastTiffPath()`

```matlab
tiffPath = getLastTiffPath(obj)
```

- **Pre.** `state_ == 'completed'`. `sessionActive_ == true`.
- **Post.** `state_ == 'idle'`. The bridge is ready to arm again.
  `trialCounter_` is **not** decremented; it remains equal to the
  trial index just completed and forms the basis for the deterministic
  path derivation below.
- **Path derivation (LOCKED).** The real bridge MUST construct the
  path as

  ```matlab
  acqNum   = obj.startAcqNum_ + uint32(obj.trialCounter_) - uint32(1);
  fmt      = sprintf('%%s_%%0%dd.tif', double(obj.acqNumWidth_));
  fileName = sprintf(fmt, obj.logFileStem_, acqNum);
  tiffPath = fullfile(obj.logFileSaveDir_, fileName);
  ```

  (At default `acqNumWidth_ == 5`, this evaluates to
  `<logFileSaveDir_>/<logFileStem_>_00042.tif` for the 42nd
  acquisition.) The bridge SHOULD verify the file exists on disk
  before returning; if it does not, the bridge MUST still return the
  expected path and log a `tfp:hardware:ScanImageBridge:tiffNotFound`
  warning. The aligner downstream is responsible for handling missing
  files (it treats a missing TIFF as a fatal session-level mismatch
  per §7).

  Path translation between PCs is the caller's responsibility — if the
  imaging PC writes to `D:\...` and the DAQ PC mounts that as
  `Z:\...`, the experiment script swaps the prefix before passing
  paths to `tfp.io.alignTrialsEpisodic`.
- **Returns.** `tiffPath` — char row vector, absolute path on the
  ScanImage PC's filesystem (subject to the path-translation caveat
  above). Empty string `''` is permitted ONLY for the mock's
  `ttl_only`-like scenarios; in real-bridge `msocket`/`tcp` modes
  returning `''` indicates the bridge could not derive a path (e.g.
  one of the session-snapshot fields became unset mid-session) and the
  bridge MUST log a warning
  `tfp:hardware:ScanImageBridge:noTiffPath`.
- **Errors.**
  - `tfp:hardware:ScanImageBridge:badState` — `state_ ~= 'completed'`
    or `sessionActive_ == false`.

### 9.6 `verifyEpisodicProtocol()`

```matlab
verifyEpisodicProtocol(obj)
```

- **Pre.** `state_ == 'idle'`. ScanImage is in external-trigger mode
  on the rig.
- **Post.** `state_ == 'idle'` (the diagnostic always restores the
  initial state, success or fail).
- **Blocking.** Interactive — prints progress and may block on the
  operator. Used once per rig bring-up.
- **Returns.** Nothing. Side effect: prints a pass/fail summary to
  stdout, with the same level of detail as the existing
  `verifyProtocol()` in `ScanImageBridge.m` (handshake, completion
  signal, TIFF-path retrieval).
- **Errors.** None — failures are reported as printed diagnostics, not
  thrown.

### 9.7 Mock fake-TIFF placeholder scheme (LOCKED)

`MockScanImageBridge.getLastTiffPath()` returns a path to a real
file that the aligner can `readScanImageTiff` on without ScanImage
being present. The locked scheme is:

- **One `.mat` sidecar per trial** at
  `fullfile(mockTiffDir_, sprintf('mock_trial_%04d.mat', trialCounter_))`.
  The path returned from `getLastTiffPath` is this `.mat` file (NOT a
  `.tif`); the file extension `.mat` is the signal to
  `readScanImageTiff` that this is a mock sidecar and to short-circuit
  the TIFF parser.
- **Sidecar contents.** A single struct named `meta` matching the
  output shape of `tfp.io.readScanImageTiff` (see §6.2):
  - `numFrames` (uint32)
  - `numChannels` (uint32) — always 1 for the mock
  - `frameRateHz` (double)
  - `frameTimestamps_s` (`numFrames × 1` double)
  - `timestampsAreSynthesised` (logical) — always `true` for the mock
  - `sourceTiff` (char) — echo of the `.mat` path
  - `scanImageVersion` (char) — `'mock'`
- **mockTiffDir_** is set from `config.mockTiffDir` (default
  `tempdir()/tfp_mock_tiffs/`). The bridge creates the directory on
  first use; tests clean up by deleting it in `tearDown`.
- **Counter.** `trialCounter_` is initialised to `0` by
  `beginSession()` and incremented on each `armForExternalTrigger`
  success (see §9.3). It is reset by `beginSession()` (start of a new
  session) and by `disconnect()`. The mock's
  `getLastTiffPath` returns
  `fullfile(mockTiffDir_, sprintf('mock_trial_%04d.mat', trialCounter_))`
  — note this uses `trialCounter_` directly (mock-local 1-based trial
  index), NOT `startAcqNum_ + trialCounter_ - 1` (real-bridge path
  derivation per §9.5). The `.mat` extension is the only contract the
  aligner cares about; the filename body is for human readability of
  mock test artifacts.

**Why `.mat`, not a fake TIFF.** Writing a synthetic ScanImage-format
TIFF requires re-implementing ScanImage's header schema (which is
itself version-dependent and would drift). The `.mat` sidecar carries
exactly the metadata the aligner needs and nothing more; the aligner
contract (§6) explicitly admits this branch via the extension check.
This keeps the mock self-contained and avoids the mock-vs-real schema
drift trap.

`tfp.io.readScanImageTiff` MUST detect `endsWith(tiffPath, '.mat')`,
load the file with `load(tiffPath, 'meta')`, and return that struct
unchanged. Any other branch (`.tif`, `.tiff`) uses the real parser
described in §6.

### 9.8 Other ScanImageBridge methods

Methods listed in `ScanImageBridge.m` that are NOT in the episodic
contract (`setPendingPower`, `setActivePattern`, `clearLiveTraces`,
`getLiveTraces`, `supportsStreaming`, `armStreaming`, `disconnect`,
`getLog`, the legacy `getLastAcquisition`) remain available with
unchanged semantics. The episodic contract does NOT subsume them; the
Sequencer still calls them where appropriate (e.g.
`setPendingPower` before `setActivePattern` in msocket mode).

The legacy `getLastAcquisition()` returns a (path, timestamps) pair
and predates `getLastTiffPath()`. New code MUST use
`getLastTiffPath()`; `getLastAcquisition()` stays for back-compat with
a one-shot deprecation warning (raised on first call per session).

---

## 10. Cross-check contract → 11 was renumbered; this section number reserved

(Intentionally empty placeholder kept so cross-references in the
companion Round 1 task tickets keep their section anchors stable.)

---

## 11. Failure modes and containment

| Failure mode | Detection | Containment | Action |
|---|---|---|---|
| Dropped frame within a trial | `alignmentDiscrepancy ≠ 0` and \|d\|>1 | One trial | tier `'low'` (\|d\|≤5) or `'quarantine'` (\|d\|>5) |
| Spurious DI edge inside stim window | `alignmentDiscrepancy < −1` | One trial | tier `'low'` / `'quarantine'` by magnitude |
| Missing TIFF (path empty) | `tiffPath == ''` | One trial | tier `'quarantine'`, reason `'missingTiff'` |
| TIFF count mismatch with planned `framesPerTrial` | comparison after `readScanImageTiff` | One trial | already covered: `alignmentDiscrepancy` carries the signal |
| ScanImage arm timeout | `armForExternalTrigger` throws `armTimeout` | One trial | Sequencer marks trial `failed`; session continues |
| ScanImage acquisition timeout | `waitForCompletion` throws `acquisitionTimeout` | One trial | Sequencer marks trial `failed`; bridge `state_` ⇒ `'idle'` |
| DAQ buffer underrun | continuous session throws on next read; clocked AO sample index gap | Session-fatal | Sequencer stops the session; aligner reports fatal because per-trial anchors are no longer trustworthy |
| ScanImage running free-running (not triggered) | session-level: >50% trials quarantined | Session-fatal | Aligner returns `fatal == true`; operator must re-config ScanImage |
| Frame-clock DI disconnected | `frameStartSamples` empty for whole session | Session-fatal | Aligner reports fatal; no trial is updated |
| Non-monotonic `frameStartSamples` | aligner check | Session-fatal | Aligner reports fatal; no trial is updated |

Per-trial containment is the design goal: a single misbehaving trial
MUST NOT corrupt the next trial's alignment. Session-fatal modes are
those where the *cross-check itself* is broken globally; the operator
needs the fatal report to diagnose and re-run the session.

---

## 12. Operator-side ScanImage config

The imaging PC's ScanImage instance MUST be configured before the
Sequencer is started:

1. **External-trigger mode.** Acquisition triggered by an external TTL
   on the ScanImage `trigAcqInTerm`. **Property names confirmed** on the
   installed SI2019bR0 (imaging PC, 2026-08-05): `hSI.extTrigEnable`
   (`+scanimage/SI.m:20`), `hSI.hScan2D.trigAcqInTerm` and
   `trigAcqEdge` (`+scanimage/+components/Scan2D.m:44, 47`), with the
   legal terminal list in `trigAcqInTermAllowed` (`Scan2D.m:150`).
   Still `%VERIFY` on the rig: **which** terminal from
   `trigAcqInTermAllowed` is physically wired, and the edge polarity.
   Run `probe_scanimage_config` on the imaging PC to dump the allowed
   list. The `configs/real.yaml` line `port0/line10` is the DAQ-side DO
   that drives it.
2. **Frames per acquisition.** ScanImage's
   `hSI.hScan2D.framesPerAcq` MUST be set to `cfg.framesPerTrial`. The
   Sequencer DOES NOT remotely change this value — the operator sets it
   manually before the session.
   **Confirmed** on SI2019bR0 at `+scanimage/+components/Scan2D.m:121`
   ("number of frames per acquisition trigger"). Note a same-named
   property also exists at the `hSI` level (`+scanimage/SI.m:126`,
   initialised `nan`); `probe_scanimage_config` reports both live values
   so the operator sets the one that is actually in effect.
3. **Save directory per session.** Operator selects a fresh save
   directory in ScanImage at the start of every session (existing lab
   workflow). The bridge MUST NOT mutate ScanImage's
   `logFileCounter` — instead `beginSession()` snapshots its current
   value (§9.2) and derives subsequent per-trial paths relative to that
   baseline. This makes the bridge safe to re-run within an already-
   open ScanImage session, and means a crash and restart in the same
   save directory just produces a fresh baseline rather than
   overwriting prior trials.
4. **Log-file naming convention.** ScanImage will write one TIFF per
   external trigger named `<logFileStem>_<NNNNN>.tif`, where `NNNNN`
   is the zero-padded acquisition counter. **Width 5 confirmed** on
   SI2019bR0: `+scanimage/+components/Photostim.m:2254` builds
   `sprintf('_%05d', hSI.hScan2D.logFileCounter)`, and the same `%05d`
   convention appears in `IntegrationRoiManager.m:155` and
   `MotionManager.m:1627`. The three source properties are confirmed at
   `Scan2D.m:88` (`logFileStem`), `:55` (`logFilePath`), `:89`
   (`logFileCounter`, default 1); `Scan2D.m:237` also exposes
   `logFullFilename` = `fullfile(logFilePath, logFileStem)`.
   The aligner does not parse filenames; it consumes whatever
   `bridge.getLastTiffPath()` returns. Still `%VERIFY` on the rig: that
   per-acquisition naming actually produces a fresh file per external
   trigger (and not one growing TIFF) — that is acquisition behaviour,
   not a property name, so only a live triggered run settles it.
5. **Save format.** TIFF only (not BigTIFF unless trials are very
   large; `tfp.io.readScanImageTiff` handles both via `imfinfo`).
6. **No Save-Last-Frame mode.** Each acquisition MUST write a
   complete TIFF before the next trigger arrives.

Items 1, 2, 3, and 4 are the load-bearing operator-side switches;
items 1, 2, and 4 are marked `%VERIFY` here so that the rig-bring-up
checklist captures them. Item 3 (save directory selection) is operator
workflow, not a software-detectable misconfiguration.

---

## 13. Migration notes

- **Archive tag.** The prior continuous design is preserved at git
  tag `archive/continuous-alignment-2026-05-23`. See
  [ARCHIVE_CONTINUOUS_ALIGNMENT.md](ARCHIVE_CONTINUOUS_ALIGNMENT.md)
  for the tag's contents and the rollback procedure.
- **Still load-bearing from SYNC_FRAME.md:**
  - §2 DAQ master-clock model.
  - §4 (all four continuous-session API contracts:
    `startContinuousSession`, `stopContinuousSession`,
    `currentSampleIndex`, `queueClockedAO`).
  - §5 Frame-clock DI encoding contract.
- **Superseded sections of SYNC_FRAME.md:**
  - §1 Two-path design — the out-pulse path is now operator-only
    (session-start long pulse); the per-trial trial-onset out-pulses
    are removed.
  - §3 Out-pulse spec, where it discusses the per-trial onset pulse.
    Session-start pulse semantics are retained.
  - §6.2 Frame alignment fields and the Nth-edge-=-Nth-frame rule —
    replaced by §5 of this document and the new
    `attachEpisodicAlignment` method.
- **Deprecated symbols** (one-shot warning, removed in Round 5):
  - `tfp.io.alignTrialsToFrames` ⇒ use `tfp.io.alignTrialsEpisodic`.
  - `tfp.trial.Trial.attachFrameAlignment` ⇒ use
    `attachEpisodicAlignment`.
  - `ScanImageBridge.getLastAcquisition` ⇒ use `getLastTiffPath`.
- **Config keys removed from experiments:**
  - `cfg.trialOnsetPulseS` and per-trial onset pulses on
    `cfg.syncDOLine`. The Sequencer no longer fires per-trial pulses
    on this line.
- **Config keys added:** `cfg.startAcqDOLine`, `cfg.startAcqPulseS`,
  `cfg.framesPerTrial`, `cfg.armTimeoutS`, `cfg.trialTimeoutS`,
  `cfg.mockTiffDir` (mock only).
