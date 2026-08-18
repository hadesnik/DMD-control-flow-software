# Blink SDK API audit — Meadowlark 1K (HSP1K class)

**Status: NOT STARTED — blocking gate for `tfp.hardware.BlinkSLM`.**

This document mirrors [alp-api-audit.md](alp-api-audit.md): before any real
`calllib` name appears in `BlinkSLM.m`, the SDK header shipped with THIS SLM
PC's Blink install is vendored and every function the driver needs is
cross-referenced to a header line number. **Never invent Blink function
names** (CLAUDE.md rule, same discipline as the ALP API). Until this audit is
complete, `BlinkSLM` throws `tfp:hardware:BlinkSLM:sdkNotVendored` and
`slm_server` runs in `dryRun` mode (protocol only).

## Step 1 — vendor the SDK (on the SLM PC)

- [ ] Locate the Meadowlark/Blink install (typically under
      `C:\Program Files\Meadowlark Optics\`). Record the exact product +
      SDK version here.
- [ ] Copy into `vendor/meadowlark/official/` (strip any `.git/`):
  - [ ] the C wrapper header (`Blink_C_wrapper.h` or equivalent)
  - [ ] the SDK manual PDF
  - [ ] note (do not copy) the DLL name + full path for `slm_pc_config.m`
- [ ] Record the board type / dimensions the SDK reports (must be 1024×1024).

## Step 2 — the audit table

For each capability `BlinkSLM.m` needs, record the REAL function name and
header line, or mark it ABSENT:

| Capability | `BlinkSLM` method | Real SDK function (header:line) | Notes |
|---|---|---|---|
| Create/destroy SDK, select board | `initialize` / `cleanup` | TBD | |
| Query board width/height | `initialize` validation | TBD | must report 1024×1024 |
| Load wavelength LUT file | `initialize` (`lutPath`) | TBD | nearest-to-1038 nm LUT in the install? record filename |
| Write one 8-bit image now | `writeImage` | TBD | row-major vs column-major? trigger vsync wait? |
| **Preload N-image sequence to onboard memory** | `preloadSequence` | TBD | **the load-bearing question** |
| **External-trigger sequence advance** | `armExternalTrigger` | TBD | trigger polarity, voltage level, connector on the PCIe board |
| Software sequence step | `softwareAdvance` | TBD | |
| Wavefront-correction (WFC) file mechanism | `tfp.slm.loadWFC` | TBD | is WFC applied on-device or must it be summed into images? |

## Step 3 — decisions the audit settles

- [ ] **Does this unit support onboard sequence memory with hardware-trigger
      advance?** If YES: `trigger_mode: 'ttl'` becomes available (wire DAQ
      `port0/line8` → the board's trigger input; verify pulse spec). If NO:
      `trigger_mode` stays `'software'` permanently, `slm_server` advances by
      per-step `writeImage` of the preloaded stack, and
      `tfp.slm.validateSpec` should reject `'ttl'`.
- [ ] LUT: on-device (preferred; software hook stays identity) or must the
      LUT be baked into the images (`tfp.slm.applyLUT` with the LUT vector)?
- [ ] WFC: on-device or additive (point `slm.wfc_file` at the device file
      and let `tfp.slm.applyWFC` handle it)?
- [ ] Max frame rate confirmed vs the handoff's `slm_max_frame_hz: 1436`.

## Step 4 — implementation

- [ ] Replace every `%VENDOR-AUDIT` block in
      `src/+tfp/+hardware/BlinkSLM.m` with real `calllib` calls
      (loadlibrary + header, libpointer out-params, typed `checkBlinkReturn`
      mapping — copy the `DLP650LNIR_DMD.m` pattern).
- [ ] Set `dryRun = false` in `slm_pc_config.m`; run
      `slm_server` and drive it end-to-end from the DAQ PC
      (`tfp.hardware.MeadowlarkSLM` READY handshake, BLANK, ADV).
- [ ] Add a geometry assertion for `BlinkSLM` to
      `tests/test_optics_handoff_constants.m` (the MockSLM one already
      exists).
