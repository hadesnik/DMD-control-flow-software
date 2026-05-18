# TF-Photostim

MATLAB control software for a 2-photon temporal-focusing patterned
photostimulation system targeting single-cell resolution across a
3×3 mm field of view, in support of a BRAIN Initiative R01.

## Status

- **Phase 1 complete**: mock-only end-to-end pipeline. Pattern
  generation → trial sequencing → mock hardware → 11-step Sequencer
  state machine → on-disk persistence.
- **Tests**: 32 / 33 passing (`test_calibration_mock` deferred to
  Phase 2/3).
- **Hardware target**: Vialux ALP-4.3 driving a TI DLP650LNIR NIR DMD.
  Currently running mock-only on macOS pending hardware arrival.

## How to run

From the repo root, on a machine with MATLAB R2023a or later, with macOS 13.3+ required for R2023b and newer:

```
matlab -batch "runtests"
matlab -batch "addpath('src'); result = tfp.experiments.exp_ppsf_lateral('configs/mock.yaml', 'manual_check'); disp(result)"
```

The first command runs the full test suite (exit code 0 on full pass,
1 on any failure). The second runs the PPSF experiment end-to-end
against mocks and prints the summary struct.

## Repo layout

- `configs/` — YAML configuration files (mock and per-rig profiles).
- `docs/` — design notes and API audits.
- `src/` — MATLAB source under the `+tfp/` package.
- `tests/` — `matlab.unittest.TestCase` suite, run via `runtests`.
- `vendor/` — third-party references (Vialux ALP wrappers and headers).

## More

- [ARCHITECTURE.md](ARCHITECTURE.md) — concrete design, classes, data flow.
- [docs/alp-api-audit.md](docs/alp-api-audit.md) — Vialux ALP API
  cross-reference and verification checklist.
