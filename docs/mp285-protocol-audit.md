# Sutter MP-285 serial protocol audit

**Status: NOT VERIFIED — required before first hardware use of
`tfp.hardware.MP285ZStage` (the direct-serial backend, used when the manual
serial switch box points the MP-285 at the DAQ PC).**

`MP285ZStage.m` implements the framing below from the MP-285 manual's binary
command set; every item must be checked against the unit's actual manual and
one bench session before a calibration trusts it. The `RelayZStage` path
(MP-285 stays on the imaging PC, moves via `hSI.hMotors` through
`si_motor_helper.m`) does NOT depend on this audit — but it has its own
`%VERIFY` (the `hSI.hMotors.motorPosition` property name and its blocking
semantics on SI2019bR0).

## Audit items

1. **usteps-per-um** (`config.zstage.usteps_per_um`, code default 25 =
   0.04 um/ustep). Depends on the installed lead screw and the resolution
   mode (coarse/fine). Check the ROE display against a commanded 100 um
   move. A wrong value scales EVERY z-calibration linearly — this is the
   highest-leverage item.
2. **'c' position query framing**: expect `'c' + CR` -> 12 payload bytes
   (3x int32 little-endian usteps, x/y/z) `+ CR`. Confirm byte order and
   that the trailing CR arrives (code reads 13 bytes).
3. **'m' absolute move framing**: `'m' + 3x int32 usteps + CR`; the unit
   replies CR **on move completion** (this is what makes `moveToUm`
   blocking). Confirm: does the controller also echo anything else?
   X/Y MUST be echoed back unchanged (code reads current position first) —
   verify no lateral drift after a pure-z move sequence.
4. **Serial parameters**: 9600 baud (config default), 8N1? Flow control?
   The switch box must be transparent to these.
5. **Timeout behaviour**: long moves vs the 10 s default timeout — a 500 um
   move at low speed may exceed it; measure and set `config.zstage.timeoutS`.
6. **ROE interaction**: commands while the operator touches the ROE knob —
   confirm the unit's documented behaviour (typically the ROE and remote
   commands must not race; brief the operator).

## Sign convention

`ZStage` promises "zUm increases toward deeper focus". Determine on the
bench which MP-285 z direction that is on this rig's mounting, and if
inverted, note it here and negate in `MP285ZStage` (single place) — the
calibrations only use differences, but the SIGN decides
`threeD.depth_gradient_sign` bookkeeping downstream.
