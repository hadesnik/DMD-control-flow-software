# TF-Photostim

MATLAB control software for a 2-photon temporal-focusing patterned
photostimulation system targeting single-cell resolution across a
3×3 mm field of view, in support of a BRAIN Initiative R01.

## Status

- **Phase 1 complete**: mock-only end-to-end pipeline — pattern
  generation → trial sequencing → mock hardware → 11-step Sequencer
  state machine → on-disk persistence.
- **Phase 2 complete**: real NI DAQ integration, ScanImageBridge TCP
  protocol, verified trigger topology.
- **Phase 3 in progress**: RealScanImageBridge, calibration routines
  (`alignDMDtoCamera`, `powerMeterSweep`), SubstageCamera HAL,
  2D PPSF experiment.
- **Tests**: 42 / 42 passing.
- **Hardware target**: DLi4130 (visible, ALP-4.1, borrowed from Waller
  lab) for software validation now; TI DLP650LNIR NIR DMD arriving soon.

## How to run

From the repo root, on a machine with MATLAB R2023a or later:

```
matlab -batch "runtests"
```

Exit code 0 = all pass. Run experiments against mocks:

```matlab
result = tfp.experiments.exp_ppsf_lateral('configs/mock.yaml', 'manual_check');
disp(result)
```

### Calibration workflow (scope PC, real hardware)

```matlab
% 1. Spatial calibration — DMD pixels → sample µm
tfp.calibration.alignDMDtoCamera('configs/windowed_mouse_v1.yaml');

% 2. Power calibration — DAQ voltage → mW at sample
tfp.calibration.powerMeterSweep('configs/windowed_mouse_v1.yaml');

% 3. Run experiment
tfp.experiments.exp_ppsf_lateral('configs/windowed_mouse_v1.yaml');
% or: tfp.experiments.exp_ppsf_2d(...)
```

## Repo layout

- `configs/` — YAML configuration files (mock and per-rig profiles).
- `docs/` — design notes and API audits.
- `+tfp/` — MATLAB source package.
- `tests/` — `matlab.unittest.TestCase` suite, run via `runtests`.
- `vendor/` — third-party references (Vialux ALP wrappers and headers).

## More

- [ARCHITECTURE.md](ARCHITECTURE.md) — concrete design, classes, data flow.
- [docs/alp-api-audit.md](docs/alp-api-audit.md) — Vialux ALP API
  cross-reference and verification checklist.
