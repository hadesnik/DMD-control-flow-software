# TF-Photostim — Pre-Rig Audit TODO

Generated 2026-05-22 from a three-agent audit before first real-hardware run.
Bottom line: **do not run on the real rig until the CRITICAL items below are resolved.**

---

## 🔴 CRITICAL — will break or misbehave on real hardware

- [ ] **C1. Fire the ScanImage start-acquisition TTL.**
  Architecture says the DAQ PC asserts a TTL on `port0/line10` to start ScanImage's externally-triggered acquisition. Nothing in [Sequencer.m:124-233](src/+tfp/+trial/Sequencer.m#L124-L233) or `ScanImageBridge.armForExternalTrigger` actually drives that line. `NI6323_DAQ.start()` only kicks off queued AO.
  *Without this, ScanImage will never start.*

- [ ] **C2. Wire `powerLUT` through Sequencer AO queueing.**
  [Sequencer.m:148](src/+tfp/+trial/Sequencer.m#L148) queues `zeros(nSamples, nAo)`. `trial.powerMw` is metadata only. [powerLUT.m](src/+tfp/+patterns/powerLUT.m) is only called by `tests/test_patterns.m`. The FS-50 modulation input will sit at 0 V for the entire power curve. Mock tests pass because `MockDAQ` synthesizes responses regardless of AO.
  *Without this, no light comes out.*

- [ ] **C3. Pick one execution path (per-trial vs continuous-session) and unify.**
  `Sequencer.runOne` uses per-trial API; new ensemble experiments use `startContinuousSession`/`queueClockedAO`. [NI6323_DAQ.m:62-65](src/+tfp/+hardware/NI6323_DAQ.m#L62-L65) warns "mixing is not supported and is intentionally not policed." Sequencer-driven experiments (`exp_ppsf_lateral`, `exp_ppsf_2d`, `exp_axial_ppsf`, `exp_power_curve`, `exp_rapid_sequential`) never integrate with `alignTrialsToFrames`. T-SYNC-13 only covers the ensemble path.

- [ ] **C4. Configure the frame-clock DI before reading it.**
  [Sequencer.m:182-192](src/+tfp/+trial/Sequencer.m#L182-L192) calls `daq.readDigitalInput(...)` but `configureDigitalInput` is never called. On `NI6323_DAQ` this throws `tfp:hardware:NI6323_DAQ:noDigitalData` (line 229), gets caught and downgraded to a warning, and every trial completes with `frameClock=[]`.

- [ ] **C5. Implement real `safetyChecks` before any high-power runs.**
  [safetyChecks.m:12-14](src/+tfp/+util/safetyChecks.m#L12-L14) only checks an in-process abort flag. No power-max enforcement, no Pockels/shutter interlock. Ensemble experiments (which actually drive AO) don't even call it.

- [ ] **C6. Fix `real.yaml` schema — `paths.dataDir` and `daq.aiRangeV`.**
  Experiments read `config.paths.dataDir` and `config.daq.aiRangeV`. `real.yaml` puts `dataDir` under `session.dataDir` (lines 35-37) and has no `aiRangeV` at all. Same `paths` bug in `dli4130.yaml` (lines 43-45).
  *Without this, experiments crash at config load.*

- [ ] **C7. Verify `startContinuousSession` arms with no queued AO.**
  [NI6323_DAQ.m:521-525](src/+tfp/+hardware/NI6323_DAQ.m#L521-L525): `startBackground()` is called with no queued output. Inline `%VERIFY` admits older drivers required at least one queued AO sample. No fallback or try/catch.

- [ ] **C8. Persist axis-sign verify result to YAML automatically.**
  CLAUDE.md promises sign disambiguation gets written into the rig config; [verifyScanFieldComposition.m:206-218](src/+tfp/+calibration/verifyScanFieldComposition.m#L206-L218) only prints suggested YAML lines for the operator to copy. Easy to miss on first real-rig run.

- [ ] **C9. Switch ScanImage from continuous to episodic acquisition (one TIFF per trial, triggered by a per-trial start-acq TTL).**
  Replaces the previous hybrid-aligner plan. Continuous DAQ session is preserved (AI/DI continuous, AO clocked per trial); only ScanImage's acquisition pattern changes. With trials ≥2 s long, ScanImage's external-trigger arm latency (~50–100 ms) is well under 5% of a trial, so we can afford the episodic switch — and in exchange every trial gets its own TIFF anchored to its own trigger, so a frame drop or trigger glitch is bounded to one trial instead of corrupting everything after.
  1. Configure ScanImage in external-trigger mode, N frames per trigger (operator-side ScanImage config on the imaging PC; verify arm-ready latency on the rig).
  2. Per-trial flow: arm ScanImage for `nFrames = ceil(trial.duration_s * frameRateHz) + buffer` → fire start-acq TTL on `port0/line10` → `queueClockedAO` for stim → wait for ScanImage completion → record the resulting TIFF path on the Trial.
  3. New `tfp.io.alignTrialsEpisodic(trials, tiffPaths, frameStartSamples, sampleRate)`: trivial per-trial frame list (`1:numFramesInTiff(i)`); cross-check against frame-clock DI edge count in trial window.
  4. Session-level assertion: `numel(tiffPaths) == numel(trials)`. Trial-level assertion: TIFF frame count vs DI-edge count agree to ±1 frame; disagreement → mark trial `alignmentConfidence ∈ {"low","quarantine"}`.
  5. Add `Trial.siTiffPath`, `Trial.alignmentDiscrepancy`, `Trial.alignmentConfidence` fields.
  6. Mock support: `MockScanImageBridge` simulates episodic acquisition (synthetic TIFF placeholder + frame count).
  7. Archive the prior continuous-alignment design — done: tag `archive/continuous-alignment-2026-05-23`, see [docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md](docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md).
  *Task decomposition for parallel agents: see [tasks.md](tasks.md).*

---

## 🟡 CONSISTENCY — cross-file mismatches & convention violations

- [ ] **S1. Reorder Sequencer: DMD softTrigger before DAQ.start** ([Sequencer.m:176,179](src/+tfp/+trial/Sequencer.m#L176-L179)). Or move to external-trigger gating with the DAQ DO driving both.

- [ ] **S2. Sequencer hardcodes 30 Hz** for `nFrames` ([Sequencer.m:166](src/+tfp/+trial/Sequencer.m#L166)); `ScanImageBridge.frameRate_` is ignored.

- [ ] **S3. Remove `isa(..., 'MockScanImageBridge')` check** at [Sequencer.m:204](src/+tfp/+trial/Sequencer.m#L204). Real bridge already returns `[]` from `getSyntheticResult`.

- [ ] **S4. Create `ScanImageBridgeBase` abstract class.** Real has `armStreaming`, `disconnect`, `verifyProtocol`; mock lacks them. Sequencer calls `siBridge.armStreaming(...)` ([Sequencer.m:72](src/+tfp/+trial/Sequencer.m#L72)); safe today only because `MockScanImageBridge.supportsStreaming` returns false.

- [ ] **S5. Fix `PLM.configureTrigger` signature drift.** Abstract: `(obj)`. Real: `(obj, mode)`. Mock: `(obj)`. Pick one and apply.

- [ ] **S6. Fix `DAQ.isInitialized` parity drift.** Public `isInitialized` on `MockDAQ`; private `isInitialized_` on `NI6323_DAQ`. Add to abstract `DAQ.m` and rename in `NI6323_DAQ` to public (SetAccess=protected).

- [ ] **S7. Convert bare-string errors to `tfp:<module>:<class>:<reason>` IDs.**
  - [DMD.m:31](src/+tfp/+hardware/DMD.m#L31) `error('not implemented')`
  - [loadConfig.m:157,172,176,215](src/+tfp/+io/loadConfig.m) four bare-string errors

- [ ] **S8. Unify mock/real DAQ error-namespace.** Both classes throw under both `tfp:hardware:DAQ:*` and `tfp:hardware:MockDAQ:*`/`NI6323_DAQ:*`. Convention: interface errors → `DAQ:*`, class-specific → class.

- [ ] **S9. Fix `exp_ensemble_activation.m:431`** — stores `tr.powerMw = voltageV` (volts under a milliwatt field). Rename, or convert via `powerCurve` when available.

- [ ] **S10. Ensemble experiments never call `siBridge.setActivePattern`.** Synthetic imaging via `MockScanImageBridge.getLastAcquisition → CellResponseModel` is only reachable from the Sequencer path. Ensemble mock tests can't detect a pattern↔cell-position mismatch — exactly what the illuminated-region commit was meant to guard against.

- [ ] **S11. Improve `CellResponseModel` for ensembles.** Uses pattern-OR centroid ([CellResponseModel.m:86-90](src/+tfp/+sim/CellResponseModel.m#L86-L90)): a multi-spot ensemble lands its "perceived center" at the geometric mean of all ON-pixels. The 28-px spot radius from the recent commit isn't reflected (`sigma=10`).

- [ ] **S12. Enforce `illuminatedRegion` inside `+patterns/`** (`singleSpot.m`, `multiSpot.m`, `ppsfPattern.m`) — currently only checked at experiment level in the two ensemble scripts. Sequencer-driven experiments can place spots outside the π-Shaper footprint silently.

- [ ] **S13. Fix dual session-start datetimes** in ensemble experiments — host snapshot taken *after* `startBackground`, offset by tens of ms from master-clock t=0.

- [ ] **S14. Extend `saveTrial` schema to include continuous-session capture** — loaded ensemble trials currently can't reconstruct AI on their own; only via separate `session_capture.mat`.

- [ ] **S15. Remove or wire `mock.yaml` orphan sections** — `laser:` (lines 71-76) and `trial:` (lines 79-85) are referenced nowhere in code.

- [ ] **S16. Remove or implement `scanimage.enabled`** — set in tests/mock.yaml but never read.

- [ ] **S17. Add `dmd.nRows`/`nCols` to `real.yaml`** (or verify `DLP650LNIR_DMD.initialize` hardcodes 800×1280). `dli4130.yaml` already sets them.

- [ ] **S18. Relocate or hide `DLPC900_PLM` public methods not in `PLM`/`MockPLM`** — `connect`, `startSequence`, `stopSequence`, `uploadPatternSequence`, `uploadTwoPatternFlipTest`. Pure additions today, but any experiment using them is implicitly real-only.

---

## 🟢 MINOR — cleanup & future work

- [ ] **M1. Replace `ScanImageBridge.waitForCompletion` `pause()`** with a real completion event.

- [ ] **M2. Reconcile or remove `getLastAcquisition` linspace timestamps** — confusing third "frame time" representation alongside `frameClock` (raw DI) and decoded `frame_indices_during_stim`. Nothing consumes it.

- [ ] **M3. Add integration test covering Sequencer's frame-clock path.** T-SYNC-13 only exercises `MockDAQ` directly, sidestepping `Sequencer.runOne` — the original T-SYNC-12 motivation isn't covered.

- [ ] **M4. Add schema validation to `loadConfig.m`.** Currently permissive — accepts unknown keys, doesn't enforce required sections. Would catch C6 at load time.

- [ ] **M5. Enable `test_calibration_mock` for the `mockResponse` branch.** All helpers exist (`alignDMDtoCamera_mock`, `crossRegisterScanImage_mock`, `composeCalibration`, `verifyScanFieldComposition`). Tag the `liveMockCrossRegister` branch with an Image Processing Toolbox guard.

- [ ] **M6. Triage existing `TODO`/`%VERIFY` markers in `+hardware/`** — intentional audit flags, but they catalog the un-verified-on-real-hardware surface. Worth a sweep before first hardware run.

- [ ] **M7. `MockDMD` reads `loadLatencyMsPerPattern`, `debugFigure`**; `maxPatternRate` from mock.yaml is accepted but unused. Confirm or wire.

- [ ] **M8. `mock.yaml` `daq.digitalInChannels: [port0/line2]`** is an inline-array of bare strings; other configs use block lists. `loadConfig.m` handles both, but normalize.

- [ ] **M9. Expose `matlab` on PATH** — `which matlab` returns empty in this shell. CLAUDE.md says R2023a is installed locally; PATH/symlink missing, so `matlab -batch "runtests('tests')"` can't run pre-flight.

---

## Minimum viable set for first hardware bring-up

In order:

1. C1 — start-acquisition TTL (no imaging triggers without it)
2. C2 — `powerLUT` plumbed through Sequencer AO (no light without it)
3. C6 — fix `real.yaml` paths/aiRangeV (config load fails without it)
4. C4 — `configureDigitalInput` before frame-clock read (no sync on Sequencer path)
5. S1 — reorder DMD softTrigger before DAQ.start (or external-trigger gating)
6. C3 — pick one execution path and delete/unify the other
7. C5 — make `safetyChecks` real before any power above thermal-damage threshold

Everything else can wait until after first light, but 1–4 are mandatory.

---

## Audit provenance

Three review agents (still resumable):
- `a486126bd00a265fb` — ScanImage PC ↔ DAQ PC interface
- `ac37b66fcd82fd285` — Hardware abstraction integrity
- `aa41746bf251a5dc3` — Configs, calibration, experiments
