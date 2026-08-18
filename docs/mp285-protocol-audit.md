# Sutter MP-285 serial protocol audit

**Status: NOT VERIFIED — required before first hardware use of
`tfp.hardware.MP285ZStage` (the direct-serial backend).**

Two mountings use this backend, both needing the audit below:
- `mount: 'objective'` (default) — the rig MP-285 moving the MOM objective,
  reached when the manual serial switch box points it at the DAQ PC.
- `mount: 'sample'` — the spare MP-285 carrying the substage camera + slide
  (BRINGUP_GUIDE §5 Option B). Adds items #7 (XY) and #8 (mechanics).

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
7. **XY axes** (sample mount only — see below). `moveToXYUm` writes the
   same 3-axis `'m'` frame with x/y set and z echoed back. Verify: (a) a
   pure-XY move leaves z unchanged on the ROE display; (b) all three axes
   share the same µsteps/µm — item #1 is measured on z, and `moveToXYUm`
   assumes it applies to x/y. If they differ, x/y need their own scale
   before XY travel can be trusted as a distance.
8. **Sample-mount mechanics** (Option B only). The spare MP-285 carries the
   Basler + slide as one rigid unit. Check: (a) total payload against the
   MP-285's rated load; (b) no sag or vibration during a sweep — a long
   cantilevered camera bracket is the failure mode, since µm-scale z
   accuracy is the whole point of this axis; (c) THE load-bearing property:
   camera-to-film focus must stay invariant across the full z sweep range
   AND the XY travel used. If the camera can defocus relative to the film,
   the mount has given up the very advantage it exists for.

## Sign convention

`ZStage` promises "zUm increases toward deeper focus". Which RAW MP-285 z
direction that is **depends on the mount**, so it is a config key rather
than a code edit: `config.zstage.direction_sign` (+1 | -1), applied to the
z element only at the µm↔µsteps boundary in `MP285ZStage`.

| `mount` | What moves | Raw stage direction that is "deeper" |
|---|---|---|
| `'objective'` (default) | the MOM objective, sample fixed | objective travels toward the sample |
| `'sample'` (Option B) | slide + substage camera, objective fixed | sample travels toward the objective — **opposite** raw sense |

Bench procedure, per mount, once: put the film in focus, command
`z.moveRelativeUm(+10)`, and observe whether the focal plane moved DEEPER
into the sample (for a film: the film goes out of focus in the direction
that matches a deeper focal plane; easiest with a thick slab or a slide
with debris on both faces). If it moved shallower, set
`direction_sign: -1` and re-check. Record the result here.

The calibrations only use differences, so a wrong sign still fits — but it
flips `threeD.depth_gradient_sign` bookkeeping downstream and silently
mirrors 3D targeting, which is why this is a bench check and not an
assumption. Note also that `calibrateSlmDefocus`'s slope sanity band
compares `abs(slope)`, so it will NOT catch an inverted ruler.
