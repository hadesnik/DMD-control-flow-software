# Frame-precise stim → ScanImage frame association

**Status:** Round-1 spec (TASK-SYNC-ALIGN, T-SYNC-1). Locks the API surface and
the trial schema so Rounds 2–4 can fan out as independent implementations.
No implementation in this round; only signatures, schema, and documented
contracts.

**See also:** [SYNC.md](SYNC.md) (PLM ↔ ScanImage trigger architecture — a
different problem, kept separate). This document is about *recording* the
relationship between trial events and ScanImage frames so post-hoc analysis
can bin frames by stim condition unambiguously.

---

## 1. Two-path design

Every ScanImage acquired frame must be tagged with the active stim
condition (trial id, condition, sub-condition index, repeat index, per-cell
fill fractions, phase relative to stim onset). We record this via two
complementary timestamp paths so post-hoc analysis can use either or
cross-check both:

- **(a) Out-pulse path.** DAQ emits a TTL on a DO line at every trial
  onset, plus a longer pulse at session start. ScanImage records this on
  its aux input. Each rising edge in that aux trace = one trial onset in
  ScanImage's own clock. Robust and minimal: only needs ScanImage to
  record the aux channel.
- **(b) In-capture path.** DAQ captures ScanImage's frame TTL on a DI
  line, via a single continuous, hardware-clocked session that runs for
  the whole experiment. Each frame's rising edge is anchored to a DAQ
  sample index. Trial onsets/offsets are anchored to DAQ samples too
  (clocked AO, not `outputSingleAnalog` + `pause`). A post-hoc lookup
  assigns each frame to a trial/condition. This is the canonical
  precision path; the out-pulse path is the resilient backup +
  cross-check.

Round 0 (out-pulse) is already partially implemented; this spec covers
the in-capture path and how both are stored on the trial.

---

## 2. DAQ master-clock model

A single DAQ session runs for the whole experiment. All event timestamps
in the trial schema are referenced to this session's hardware sample
clock.

- **Master clock**: the NI6323 onboard sample clock, started by
  `startContinuousSession(cfg)`.
- **Sample rate** (`cfg.sampleRate`, default `100_000` Hz): governs AI,
  AO, DI sampling. AO and AI/DI share the same clock so AO sample
  index `k` and AI/DI sample index `k` line up to within one clock
  period (10 µs at 100 kHz).
- **Sample index**: 1-based, monotonic, never reset within a session.
  `currentSampleIndex()` returns the next sample to be acquired (i.e.
  the count of samples acquired so far, +1).
- **Wall-clock anchor**: `sessionStartDatetime` is captured at the
  moment the hardware clock is armed in `startContinuousSession`. All
  later wall-clock conversions are
  `t_wallclock = sessionStartDatetime + sampleIdx / sampleRate`.
- **Session lifetime**: exactly one continuous session per experiment.
  Trials sit inside this session; trial state changes never start or
  stop the clock.

---

## 3. Out-pulse spec (already implemented; documented here)

Implemented in Round 0 via `daq.sendDigitalPulse(lineName, durationS)`
and the per-experiment options `syncDOLine`, `sessionStartPulseS`,
`trialOnsetPulseS` (see commit `3c6def9`,
[exp_ensemble_fill_factor_power.m](../src/+tfp/+experiments/exp_ensemble_fill_factor_power.m)).
This section documents the on-wire contract; do not change without
updating both endpoints (DAQ side and the ScanImage aux-channel recording
config).

- **Line.** A DO line configured by `cfg.syncDOLine` (e.g.
  `'port0/line0'` on the NI6323). Single line — both session-start and
  per-trial pulses are emitted on the same wire so ScanImage only
  records one aux channel.
- **Idle level.** Logic low (0 V).
- **Active edge.** Rising edge marks the event. The trailing edge
  carries no meaning; pulse width only needs to satisfy the receiver's
  minimum recognized width.
- **Pulse widths.**
  - Session-start pulse: `cfg.sessionStartPulseS`, default `0.100` s.
    Long pulse so an operator can distinguish session boundaries from
    trial onsets in the recorded aux trace by eye.
  - Per-trial onset pulse: `cfg.trialOnsetPulseS`, default `0.005` s
    (5 ms). Short enough that even at the slowest plausible ScanImage
    aux sample rate (~1 kHz) the rising edge is captured cleanly.
- **Timing accuracy.** Host-driven via `sendDigitalPulse` (sets line
  high, `pause(durationS)`, sets line low). This is *not* hardware-
  clocked; expect O(1 ms) jitter on the trailing edge. The leading
  edge is the only edge used downstream, so this jitter is
  acceptable — the in-capture path (§4) is the precision channel.
- **Receiver.** ScanImage records this DO line on an aux DI channel.
  Post-hoc, the aux trace is differentiated to detect rising edges;
  the first long edge (≥50 ms wide) is the session start, subsequent
  edges are trial onsets.

---

## 4. In-capture continuous-session API contracts

Implemented in MockDAQ (T-SYNC-2) and NI6323_DAQ (T-SYNC-3). The
abstract base [DAQ.m](../src/+tfp/+hardware/DAQ.m) declares the four
methods below.

### 4.1 `startContinuousSession(cfg)`

Start a single continuous, hardware-clocked DAQ session for the whole
experiment. Replaces the per-trial pattern of `start()` / `stop()`.

**Arguments**

- `cfg` — struct with fields:
  - `sampleRate` (double, Hz) — master clock rate. Required.
  - `aiChannels` (numeric vector, may be empty) — AI channels to
    sample continuously.
  - `aiRangeV` (`[lo hi]`, optional) — analog input range.
  - `aoChannels` (numeric vector, may be empty) — AO channels
    reserved for clocked AO output. Output happens via
    `queueClockedAO(...)`.
  - `diLines` (cellstr, may be empty) — DI lines to sample
    continuously. **Must include `cfg.frameClockLine`** if present.
  - `doLines` (cellstr, may be empty) — DO lines used for
    on-demand pulses (`sendDigitalPulse`); routed through the
    continuous session so on-demand DO can coexist with clocked
    AO/AI/DI.
  - `frameClockLine` (char, optional) — DI line carrying the
    ScanImage frame clock (e.g. `'port0/line2'`). Documented in
    `configs/real.yaml`.

**Returns.** Nothing.

**Side effects.** Allocates hardware resources, arms the clock, sets
`isRunning = true`, captures `sessionStartDatetime`, begins
continuous acquisition of AI + DI into an internal ring buffer.

**Errors.**
- `tfp:hardware:DAQ:badConfig` — missing required fields or
  invalid shapes.
- `tfp:hardware:DAQ:alreadyRunning` — called while
  `isRunning == true`.

### 4.2 `stopContinuousSession()`

Stop the master clock and return everything captured.

**Returns.** Struct with fields:

- `aiData` (nSamples × nAi double) — captured analog input,
  in volts, in the order of `cfg.aiChannels`.
- `diData` (nSamples × nDi logical or double 0/1) — captured
  digital input, in the order of `cfg.diLines`. The
  `frameClockLine` column is the primary input to
  `tfp.io.decodeFrameClock`.
- `aoSamplesWritten` (scalar uint64) — total clocked AO samples
  output during the session (sum across calls to
  `queueClockedAO`).
- `nSamplesTotal` (scalar uint64) — total clock ticks elapsed.
  Equals `size(aiData,1)` and `size(diData,1)` when both are
  configured.
- `sampleRate` (scalar double, Hz) — echo of `cfg.sampleRate`.
- `sessionStartDatetime` (datetime) — wall-clock anchor.
- `lineNames` — struct mirroring `cfg`: `.aiChannels`,
  `.diLines`, `.frameClockLine`, etc., so downstream code can
  re-index by name without re-reading the config.

**Side effects.** Disarms the clock, frees hardware resources, sets
`isRunning = false`. After this call, `currentSampleIndex()` returns
the final sample count.

**Errors.** `tfp:hardware:DAQ:notRunning` if called before
`startContinuousSession`.

### 4.3 `currentSampleIndex()`

Return the current DAQ sample index. Used by experiment code at
trial onset/offset moments to record `t_onset_daq_samples` /
`t_offset_daq_samples`.

**Returns.** Scalar uint64. 1-based; equals the number of clocked
samples that have already been acquired since `startContinuousSession`.
Calling at the instant of trial onset gives the "now" index.

**Errors.** `tfp:hardware:DAQ:notRunning` if no continuous session
is active.

**Notes.** This is a host-side read of the hardware sample counter.
Latency between host call and the returned value is implementation-
dependent (NI6323: ~tens of µs); the value is "the latest sample the
host can see", not a forward-looking timestamp. For sub-ms event
anchoring, prefer clocked AO sample indices over `currentSampleIndex`.

### 4.4 `queueClockedAO(samples, rate, startTrigger)`

Queue a hardware-clocked AO waveform on the channels declared in
`cfg.aoChannels`. Used in Round 3 to replace
`outputSingleAnalog(...) + pause(...)` for stim-onset commands.

**Arguments**

- `samples` (nSamples × nAo double, volts) — waveform.
- `rate` (double, Hz) — must equal `cfg.sampleRate` of the active
  session (clocked AO shares the master clock). Passed redundantly
  for caller-side clarity and as an assertion.
- `startTrigger` — one of:
  - `'immediate'` — begin output on the next clocked sample
    boundary. (Round-1 default; only mode that must be implemented
    in Round 2.)
  - `'sync'` — reserved for future use (sync to an external
    trigger such as the frame clock). Round-1 implementations may
    `error('tfp:hardware:DAQ:notImplemented', ...)`.

**Returns.** Scalar uint64 — the DAQ sample index at which the first
queued sample will be output. This is the canonical anchor for
`t_onset_daq_samples`; recording it at queue time is preferable to
calling `currentSampleIndex` after the fact.

**Errors.**
- `tfp:hardware:DAQ:notRunning` — no continuous session.
- `tfp:hardware:DAQ:badShape` — column count ≠ number of AO
  channels.
- `tfp:hardware:DAQ:badRate` — `rate` ≠ session sample rate.

---

## 5. Frame-clock DI encoding

ScanImage's frame-clock output is wired into the NI6323 on a DI line
declared as `cfg.frameClockLine` in the continuous session config (the
existing rig uses `'port0/line2'`, see `configs/real.yaml`). It is
sampled at the master clock rate alongside everything else.

- **Polarity.** Active-high. Rising edge marks the start of one
  ScanImage frame.
- **Pulse count.** Exactly one pulse per acquired frame.
- **Pulse width.** Native ScanImage TTL: 1–10 µs typical. At
  100 kHz sample rate this is 0.1–1.0 samples wide — usable for
  edge detection but not for width-based decoding. The decoder
  (`tfp.io.decodeFrameClock`, T-SYNC-4) only consumes rising edges.
- **Idle level.** Logic low between frames.
- **Decoding contract.** `decodeFrameClock(diVec, sampleRate)`
  returns `(frameStartSamples, frameRateHz)`:
  - `frameStartSamples` (n×1 uint64) — DAQ sample index of each
    detected rising edge.
  - `frameRateHz` (scalar) — inferred from the median interval
    between rising edges; useful as a sanity check vs the ScanImage
    configured rate. Edge cases (missing pulses, jittered pulses,
    polarity inversion) are unit-tested in T-SYNC-4.

---

## 6. Trial schema fields and units

Implemented as `SetAccess = private` properties on
[`tfp.trial.Trial`](../src/+tfp/+trial/Trial.m). The new fields default
to empty / NaN so existing trial files load without migration. They are
populated by:

- The host-side stim driver (via the updated `markRunning` /
  `markComplete` transitions), for the canonical DAQ-sample anchors.
- The post-hoc alignment pass
  (`tfp.io.alignTrialsToFrames`, T-SYNC-5), via the new
  `attachFrameAlignment(...)` method, for the frame-index lists and
  the cross-checked aux-edge index.

### 6.1 Sample anchors (filled during execution)

| Field | Type | Unit | Source | Notes |
|---|---|---|---|---|
| `t_onset_daq_samples` | uint64 / NaN | DAQ samples (1-based) | `markRunning(onsetSample, ...)` | Anchored to the first sample of the clocked AO command that opens the stim, or to `currentSampleIndex()` at the moment of trial start if the trial doesn't drive clocked AO. |
| `t_offset_daq_samples` | uint64 / NaN | DAQ samples (1-based) | `markComplete(data, offsetSample)` | Anchored to the last AO sample of the stim, or to `currentSampleIndex()` at trial end. |
| `daq_master_sample_rate_hz` | double / NaN | Hz | `markRunning(..., sampleRate, ...)` | Snapshot of the active session's `cfg.sampleRate`. Recorded per-trial so loaded trials are self-describing if the session metadata is lost. |
| `session_start_datetime` | datetime / NaT | wall clock | `markRunning(..., sessionStart)` | Snapshot of the active session's `sessionStartDatetime`. |

### 6.2 Frame alignment (filled post-hoc)

| Field | Type | Unit | Source | Notes |
|---|---|---|---|---|
| `t_onset_si_aux_edge_index` | double / NaN | edge index | `attachFrameAlignment(...)` | Index into the ScanImage aux-trace rising-edge list that corresponds to this trial's onset pulse. 1-based; NaN until aligned. |
| `frame_indices_during_stim` | uint64 row vector | ScanImage frame index | `attachFrameAlignment(...)` | Frames whose rising edge falls inside `[t_onset_daq_samples, t_offset_daq_samples]`. Empty until aligned. |
| `frame_indices_baseline` | uint64 row vector | ScanImage frame index | `attachFrameAlignment(...)` | Frames in the pre-stim baseline window `[t_onset_daq_samples - preStim_s*sampleRate, t_onset_daq_samples)`. Empty until aligned. |

### 6.3 State transitions

- `markRunning(obj)` — backward-compatible no-arg form. Leaves the new
  anchor fields at their defaults.
- `markRunning(obj, onsetSample, sampleRate, sessionStartDatetime)`
  — extended form. Records the three session-level anchors and
  transitions to `'running'`. All three args are required when *any*
  of them is provided.
- `markComplete(obj, data)` — backward-compatible.
- `markComplete(obj, data, offsetSample)` — extended form, records
  `t_offset_daq_samples`.
- `attachFrameAlignment(obj, frameIndicesDuringStim, frameIndicesBaseline, siAuxEdgeIndex)`
  — new method, callable only after `markComplete`. Throws
  `tfp:trial:Trial:badTransition` otherwise. Sets the three post-hoc
  fields. Idempotent: calling twice with the same values is allowed;
  calling with different values throws
  `tfp:trial:Trial:frameAlignmentMismatch` (Round-2 implementations
  may relax this to a warning).

All invalid transitions throw `tfp:trial:Trial:badTransition` with a
message naming the current and required states.
