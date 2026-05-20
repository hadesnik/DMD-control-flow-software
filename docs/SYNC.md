# PLM–ScanImage Synchronisation Architecture

**Status:** Design doc — open questions require TI confirmation before implementation.
**Scope:** DLPC641 trigger interface, wiring from NI PCIe-6323, and ScanImage frame-clock routing.
**See also:** `src/+tfp/+hardware/TIPLM_PLM.m` (stub), `src/+tfp/+hardware/DLP650LNIR_DMD.m`
  (reference for how the DMD side of timing is already structured).

---

## 1. Overview

The TI NIR PLM (DLPC641 controller, 904×800, ~50 µs switching) enables axial multiplexing of
the temporal-focusing photostimulation beam: a different defocus wavefront is loaded onto the
PLM each ScanImage frame, steering the 2-photon excitation volume to a different z-plane.
Collecting N consecutive frames while stepping the PLM through N pre-computed defocus patterns
yields a 3-D stimulation stack without moving the objective.

The PLM must transition to the next pattern **between** ScanImage frames so that the settling
transient (~50 µs) is complete before the photostimulation laser fires within the new frame.
Two candidate architectures achieve this:

- **Option A (preferred): PLM as slave.** The ScanImage frame-done TTL is routed to the
  DLPC641 TRIG\_IN input. Each rising edge advances the PLM by one stored pattern. Timing
  authority stays with ScanImage / the resonant scanner; the PLM follows passively.

- **Option B (fallback): PLM as master.** The DLPC641 sync-out pulse is fed to the NI6323
  digital input. The DAQ uses that pulse to gate the laser and optionally trigger ScanImage
  acquisition. The PLM sets the frame rhythm rather than following it.

Option A is recommended. See Section 5.

---

## 2. Option A — PLM as Slave (Preferred)

### 2.1 Signal routing

```
Imaging PC (ScanImage)
  Frame-clock TTL output ──────────────────────────────┐
         │                                              │
         │  (existing wire, already wired)              │  (new wire, Option A)
         ▼                                              ▼
  DAQ PC, NI6323 DI port0/line2                  DLPC641 TRIG_IN
  (post-hoc frame-stim alignment,                (advances PLM pattern
   already in configs/real.yaml)                  on each rising edge)
```

The frame-clock line from the imaging PC is split: one leg runs to the NI6323 digital input
(already implemented for frame-stim alignment); the second leg runs directly to the DLPC641
TRIG\_IN connector. No additional DAQ processing is required for the split path — the DLPC641
listens passively.

Alternatively the NI6323 can re-drive the signal (DI → loopback to DO → DLPC641 TRIG\_IN) if
electrical isolation or fanout buffering is needed. This adds ≤1 µs propagation through the
NI6323 digital re-drive path, which is negligible against the 33 ms frame period.

### 2.2 Timing diagram

Nominal values: ScanImage 30 Hz, 512×512 pixels (33.3 ms frame period).
PLM settling: ~50 µs after TRIG\_IN edge. Diagram not to scale.

```
ScanImage frame clock (imaging PC output):
  ┌───────────────┐               ┌───────────────┐               ┌───────────────
  │   Frame N     │               │   Frame N+1   │               │   Frame N+2
──┘               └───────────────┘               └───────────────┘
                  ↑ frame-done edge               ↑ frame-done edge
                  (≈ 33.3 ms period)

DLPC641 TRIG_IN (same rising edge, direct wire):
                  ┐               ┐
──────────────────┘               └──────────────────────────────── ...
                  (pulse width %TBD µs — see §4 Q2)

PLM pattern index (advances ~50 µs after each TRIG_IN edge):
  [  Pattern k               ][  ~50 µs  ][  Pattern k+1          ][...]
                                  settle

Laser gate — Pockels cell (DAQ AO, programmed onset within frame):
                                         [== stim window ==]
                                         (fires after PLM settled)

DAQ AI acquisition (NI6323, continuous background):
  ═══════════════════════════════════════════════════════════════════
```

The laser gate is programmed by the DAQ to open at a fixed delay after the frame-done edge,
chosen to be longer than the worst-case PLM settling time. Using 200 µs (4× the nominal 50 µs)
leaves a comfortable margin while consuming only 0.6 % of the 33 ms frame period.

### 2.3 Pre-loading patterns on the DLPC641

Before the first frame-clock edge, all N defocus patterns for the axial stack must reside in
DLPC641 internal memory. The proposed sequence:

1. Compute the full pattern stack via `PLM.generatePatternLibrary(N, dz_range_um, obj_name)`.
2. Encode each uint8 pattern to the DLPC641 display format
   (bitplane encoding — see TASK-PLM-4 and §4 Q5 below).
3. For each pattern k = 0..N-1:
   - Display via Psychtoolbox `Screen('Flip', ...)` — this writes the pattern to the DLPC641
     frame buffer at index k.
   - Send I2C command to store frame k into persistent pattern slot k.
     (%TBD: specific I2C register — see §4 Q3.)
4. Send I2C command to enable TRIG\_IN mode:
   - Set trigger source to TRIG\_IN pin. (%TBD: register address — see §4 Q3.)
   - Set pattern advance mode to "one step per rising edge." (%TBD: register value.)
   - Optionally set wrap-around: after pattern N-1 return to pattern 0. (%TBD.)
5. Assert "arm" — DLPC641 enters trigger-wait state. (%TBD: I2C command or GPIO.)

After step 5 the DLPC641 is idle, holding pattern 0. Each subsequent TRIG\_IN rising edge
advances to the next slot. The host (MATLAB on DAQ PC) does not need to send any I2C command
per frame; the DLPC641 handles sequencing autonomously.

MATLAB call sequence in `TIPLM_PLM.configureTrigger()` (to be implemented):

```matlab
% Pseudocode — I2C register addresses are %TBD pending TI response (§4 Q3)
obj.i2c_write(REG_TRIG_SOURCE,  TRIG_SRC_TRIG_IN);     % %TBD
obj.i2c_write(REG_TRIG_MODE,    TRIG_MODE_STEP);        % %TBD
obj.i2c_write(REG_PATTERN_WRAP, TRIG_WRAP_ENABLE);      % %TBD
obj.i2c_write(REG_ARM,          ARM_TRIGGER_MODE);       % %TBD
```

MATLAB I2C access on the DAQ PC is via the Instrument Control Toolbox `i2cdev` object
(R2019a+). The DLPC641 I2C address is %TBD (check EVM schematic or TI application note).

### 2.4 Latency budget

| Event | Latency | Source |
|---|---|---|
| Frame-done TTL → DLPC641 TRIG\_IN edge | < 1 µs | wire propagation |
| DLPC641 internal trigger recognition | %TBD | TI datasheet (§4 Q2) |
| PLM mirror settling | ~50 µs | TI NIR PLM datasheet |
| Total PLM advance latency | < 100 µs (%TBD) | — |
| ScanImage frame period at 30 Hz | 33,333 µs | ScanImage |
| **Margin (frame period − PLM latency)** | **> 33,200 µs** | — |

The PLM settling time (~50 µs) is three orders of magnitude shorter than the 33 ms frame
period. Even at higher frame rates (e.g., 100 Hz, 10 ms frame period) the PLM latency is
< 1 % of the frame. This makes Option A viable at any ScanImage frame rate achievable with
the resonant scanner.

---

## 3. Option B — PLM as Master (Fallback)

### 3.1 Signal routing

```
DLPC641 sync-out (GPIO / %TBD connector)
         │
         ▼
  DAQ PC, NI6323 DI port0/line3   ──► delayed laser gate (Pockels)
         │
         │  (optional — if ScanImage can accept per-frame external trigger)
         ▼
  Imaging PC, ScanImage vDAQ external trigger input
```

### 3.2 Timing diagram

```
PLM pattern advance (DLPC641 internal clock, rate set by I2C):
  ┌─────────────────────────┐         ┌────────────────────────
  │   Pattern k             │         │   Pattern k+1
──┘                         └─────────┘
                             ↑ sync-out pulse

DAQ NI6323 DI (captures sync-out):
                             ┌──┐
─────────────────────────────┘  └────────────────────────────── ...

Laser gate (Pockels, DAQ-gated after sync-out + settling margin):
                                  [== stim ==]

ScanImage frame start (if slaved to DAQ):
                                      ┌────────────────────────
───────────────────────────────────── ┘   Frame N+1
                                      ↑ must align with resonant scanner phase
```

### 3.3 Why this is more complex

The ScanImage resonant scanner operates at a fixed resonance frequency (~7.9 kHz for a
512-line, 30 Hz frame rate). The frame rate is an integer divisor of the line rate; it is
**not** freely settable by an external trigger. To slave ScanImage frame starts to the PLM:

- ScanImage would need to be in a "triggered frame" acquisition mode where it waits for an
  external gate before committing a frame to disk. This mode exists in ScanImage 5.x/2021+
  via `hSI.hScan2D.trigAcqInTerm` and `hSI.extTrigEnable`, but the exact handshake required
  to gate individual frames (rather than whole acquisitions) is not confirmed for our setup.
  (%VERIFY with Masato — see TASK-P3-06.)

- The PLM's internal pattern clock must be phase-locked to the ScanImage resonant scanner
  or the trigger will arrive at a random phase within the scan cycle, causing frame-to-frame
  jitter in which axial plane is active during each acquired frame.

- If the PLM pattern rate drifts, ScanImage frame rate drifts with it, disrupting the
  expected relationship between trial index and frame timestamp.

In Option A none of these problems arise: the resonant scanner and ScanImage timing are
unchanged; the PLM simply follows the existing frame clock.

---

## 4. Open Questions Requiring TI Confirmation

Send to TI FAE with reference to the TI NIR PLM EVM (DLPC641 controller) and the
photostimulation use case. Propose Option A as the intended architecture.

**Q1 — TRIG\_IN voltage level:**
Is the DLPC641 TRIG\_IN input 3.3 V logic or 5 V tolerant?
The ScanImage frame-clock output (from imaging PC BNC) is 5 V TTL. If DLPC641 is 3.3 V only,
a level-shifter (e.g., SN74LVC1T45 or equivalent) is required before the TRIG\_IN pin.

**Q2 — Minimum TRIG\_IN pulse width:**
What is the minimum pulse width (µs) on TRIG\_IN to guarantee recognition of a rising edge?
The frame-done TTL from ScanImage is typically 1–10 µs wide. If the minimum is larger, we
must stretch the pulse using a monostable or DAQ re-drive.

**Q3 — I2C command sequence to arm trigger mode:**
Provide the I2C register address and write sequence to:
  (a) enable TRIG\_IN as the pattern-advance source,
  (b) set "one-step-per-edge" mode (as opposed to continuous internal clock),
  (c) enable wrap-around after the last pattern,
  (d) arm the DLPC641 to enter trigger-wait state.
Include the I2C device address of the DLPC641 on the EVM.

**Q4 — Sync-out availability (Option B prerequisite):**
Is a sync-out signal (TTL pulse coincident with each pattern transition) available on the
DLPC641 EVM GPIO header? If so, what is the connector/pin reference and voltage level?
This is needed only for Option B but useful as a diagnostic even in Option A.

**Q5 — Maximum preloaded pattern count:**
What is the maximum number of patterns that can be stored in DLPC641 internal memory for
hardware-sequenced TRIG\_IN playback? The nominal requirement is 20–50 planes for a
±500 µm axial stack at 20 µm steps. If the limit is lower, patterns must be reloaded
between sweeps, which requires a synchronisation gap.

---

## 5. Recommended Path

**Implement Option A** once TI answers Q1–Q3 above.

Implementation steps, in order:

1. **Electrical:** confirm TRIG\_IN voltage tolerance (Q1). If 3.3 V only, add level-shifter
   on the frame-clock wire before it reaches the DLPC641.

2. **I2C wiring:** connect the DAQ PC I2C bus (USB-to-I2C adapter, e.g., Total Phase Aardvark,
   or NI USB-8452) to the DLPC641 I2C header on the EVM. Verify communication by reading a
   known register (device ID or firmware version).

3. **MATLAB I2C driver:** implement `configureTrigger()` and `advancePattern()` in
   `TIPLM_PLM.m` using MATLAB `i2cdev` (Instrument Control Toolbox). Fill in register
   addresses from TI's answer to Q3.

4. **Pattern preload:** implement pattern preload loop in `TIPLM_PLM.loadPattern()` —
   display via Psychtoolbox (TASK-PLM-4), then I2C store-to-slot command. Verify with
   `getStatus()` that N patterns are resident.

5. **Arm and test with frame clock:** connect the frame-clock wire, call `configureTrigger()`,
   then manually toggle TRIG\_IN with a function generator at 30 Hz. Confirm via `getStatus()`
   that the pattern index advances once per pulse.

6. **Full integration test:** run `exp_ppsf_lateral.m` with `MockDAQ` replaced by
   `NI6323_DAQ`, PLM enabled. Verify pattern index and frame index are aligned in the
   saved trial data.

Option B should only be revisited if TI reports that DLPC641 does not support TRIG\_IN
hardware sequencing (Q3) — in which case the DAQ must software-poll the sync-out and
re-arm the PLM each frame, significantly increasing latency and jitter.
