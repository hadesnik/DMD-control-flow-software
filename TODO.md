# TF-Photostim — Pre-Rig Audit TODO

Generated 2026-05-22 from a three-agent audit before first real-hardware run.
Bottom line: **do not run on the real rig until the CRITICAL items below are resolved.**

---

## 🔴 CRITICAL — will break or misbehave on real hardware

- [x] **C1. Fire the ScanImage start-acquisition TTL.** *(Resolved by T-EP-3c, commit `2f04661`. Sequencer.runOne now calls `daq.sendDigitalPulse(startAcqLine, startAcqPulseS)` per trial.)*

- [ ] **C2. Wire `powerLUT` through Sequencer AO queueing.**
  [Sequencer.m](src/+tfp/+trial/Sequencer.m) `buildStimWaveform` (line ~782) uses `trial.powerMw` as a raw voltage. [powerLUT.m](src/+tfp/+patterns/powerLUT.m) is only called by `tests/test_patterns.m`. The FS-50 modulation input will sit at the wrong voltage for any power curve. Mock tests pass because `MockDAQ` synthesizes responses regardless of AO.
  *Next: T-EP-3d.*

- [x] **C3. Pick one execution path (per-trial vs continuous-session) and unify.** *(Resolved by T-EP-3c, commit `2f04661`. Sequencer now uses `startContinuousSession`/`queueClockedAO` and arms ScanImage episodically per trial — same path as the ensemble experiments.)*

- [x] **C4. Configure the frame-clock DI before reading it.** *(Resolved by T-EP-3c, commit `2f04661`. `frameClockLine` is now wired into `sessionCfg.diLines` at `startContinuousSession` time; `decodeFrameClock` runs on the captured continuous DI at session end.)*

- [ ] **C5. Implement real `safetyChecks` before any high-power runs.**
  [safetyChecks.m:12-14](src/+tfp/+util/safetyChecks.m#L12-L14) only checks an in-process abort flag. No power-max enforcement, no Pockels/shutter interlock. Ensemble experiments (which actually drive AO) don't even call it.

- [ ] **C6. Fix `real.yaml` schema — `paths.dataDir` and `daq.aiRangeV`.**
  Experiments read `config.paths.dataDir` and `config.daq.aiRangeV`. `real.yaml` puts `dataDir` under `session.dataDir` (lines 35-37) and has no `aiRangeV` at all. Same `paths` bug in `dli4130.yaml` (lines 43-45).
  *Without this, experiments crash at config load.*

- [ ] **C7. Verify `startContinuousSession` arms with no queued AO.**
  [NI6323_DAQ.m:521-525](src/+tfp/+hardware/NI6323_DAQ.m#L521-L525): `startBackground()` is called with no queued output. Inline `%VERIFY` admits older drivers required at least one queued AO sample. No fallback or try/catch.

- [ ] **C8. Persist axis-sign verify result to YAML automatically.**
  CLAUDE.md promises sign disambiguation gets written into the rig config; [verifyScanFieldComposition.m:206-218](src/+tfp/+calibration/verifyScanFieldComposition.m#L206-L218) only prints suggested YAML lines for the operator to copy. Easy to miss on first real-rig run.

- [ ] **C9. Switch ScanImage from continuous to episodic acquisition (one TIFF per trial, triggered by a per-trial start-acq TTL).** *Rounds 0–3 done; Rounds 4–5 pending.*
  - [x] Round 0 — Design lock (`docs/SYNC_EPISODIC.md`, archive tag).
  - [x] Round 1 — Foundation (Trial schema, TIFF reader, MockBridge episodic, RealBridge episodic).
  - [x] Round 2 — Aligner (`alignTrialsEpisodic`) + per-trial cross-check + tests.
  - [x] Round 3 — Experiment refactor: `exp_ensemble_activation`, `exp_ensemble_fill_factor_power`, and `Sequencer` all now run episodic SI on a continuous DAQ session. Cross-check uses acquisition window (not stim-only). 174/174 tests passing on main at `3800c03`.
  - [ ] Round 4 — Integration tests covering frame-drop / glitch resilience (T-EP-4a/4b).
  - [ ] Round 5 — Doc finalisation (SYNC_FRAME.md banner → final), CLAUDE.md update, ScanImage probe script (T-EP-5a/5b/5c), rig-side verification (T-EP-5d — manual).
        *T-EP-5c partially landed 2026-08-05 from the imaging PC: `scripts/imaging_pc_setup/probe_scanimage_config.m` dumps the ScanImage config and closed the SI-property `%VERIFY` items in `docs/SYNC_EPISODIC.md` §9.2/§12 against the installed SI2019bR0. Arm-latency measurement still needs the DAQ PC firing TTLs — folded into T-EP-5d.*
  *Archived prior design: tag `archive/continuous-alignment-2026-05-23`, see [docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md](docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md). Task decomposition: [tasks.md](tasks.md).*

---

## 🟡 CONSISTENCY — cross-file mismatches & convention violations

- [x] **S1. Reorder Sequencer: DMD softTrigger before DAQ.start.** *(Resolved by T-EP-3c, commit `2f04661`. Sequencer.runOne now calls `dmd.softTrigger()` before any DAQ AO queueing.)*

- [x] **S2. Sequencer hardcodes 30 Hz for `nFrames`.** *(Resolved by T-EP-3c, commit `2f04661`. `nFrames = ceil(trial.duration_s * config.imaging.frameRate) + 2` — derived from config.)*

- [x] **S3. Remove `isa(..., 'MockScanImageBridge')` check.** *(Resolved by T-EP-3c, commit `2f04661`. `getSyntheticResult` is called polymorphically; real bridge returns `[]`.)*

- [ ] **S4. Create `ScanImageBridgeBase` abstract class.** Real has `armStreaming`, `disconnect`, `verifyProtocol`; mock lacks them. Sequencer calls `siBridge.armStreaming(...)` ([Sequencer.m:72](src/+tfp/+trial/Sequencer.m#L72)); safe today only because `MockScanImageBridge.supportsStreaming` returns false.

- [ ] **S5. Fix `PLM.configureTrigger` signature drift.** Abstract: `(obj)`. Real: `(obj, mode)`. Mock: `(obj)`. Pick one and apply.

- [ ] **S6. Fix `DAQ.isInitialized` parity drift.** Public `isInitialized` on `MockDAQ`; private `isInitialized_` on `NI6323_DAQ`. Add to abstract `DAQ.m` and rename in `NI6323_DAQ` to public (SetAccess=protected).

- [ ] **S7. Convert bare-string errors to `tfp:<module>:<class>:<reason>` IDs.**
  - [DMD.m:31](src/+tfp/+hardware/DMD.m#L31) `error('not implemented')`
  - [loadConfig.m:157,172,176,215](src/+tfp/+io/loadConfig.m) four bare-string errors

- [ ] **S8. Unify mock/real DAQ error-namespace.** Both classes throw under both `tfp:hardware:DAQ:*` and `tfp:hardware:MockDAQ:*`/`NI6323_DAQ:*`. Convention: interface errors → `DAQ:*`, class-specific → class.

- [x] **S9. Fix `exp_ensemble_activation.m`** — stores `tr.powerMw = voltageV` (volts under a milliwatt field). *(Resolved by T-EP-3a, commit `be4fea2`. Now interpolates voltage→mW via `powerCurve` when supplied; otherwise falls back with a `metadata.powerNote = 'uncalibrated_AO_volts'` tag.)*

- [ ] **S10. Ensemble experiments never call `siBridge.setActivePattern`.** Synthetic imaging via `MockScanImageBridge.getLastAcquisition → CellResponseModel` is only reachable from the Sequencer path. Ensemble mock tests can't detect a pattern↔cell-position mismatch — exactly what the illuminated-region commit was meant to guard against.

- [x] **S11. Improve `CellResponseModel` for ensembles.** RESOLVED 2026-08-15 (3D work): `computeTrace` now uses the NEAREST ON-blob centroid (bwconncomp per blob, global-centroid fallback without IPT), so multi-target depth-group patterns couple each cell to the blob on top of it. Covered by `tests/test_bridge_multiplane_mock.m` (nearestBlobCentroidFixS11). The `sigma=10` default vs 28-px spot radius note still stands.

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
