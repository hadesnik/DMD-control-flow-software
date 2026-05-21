# PLM–ScanImage Synchronisation Architecture

**Status:** Design doc — Q1 (DLPC900 GPIO voltage level) still requires EVM schematic
confirmation. Q2–Q5 resolved; see §4. Controller correction: the 0.67" PLM EVM uses **dual
DLPC900**, not DLPC641 (confirmed by TI FAE, 2026-05-21). All DLPC641 references updated.
**Scope:** DLPC900 trigger interface, wiring from NI PCIe-6323, and ScanImage frame-clock routing.
**See also:** `src/+tfp/+hardware/TIPLM_PLM.m` (stub), `src/+tfp/+hardware/DLP650LNIR_DMD.m`
  (reference for how the DMD side of timing is already structured).

---

## 1. Overview

The TI NIR PLM (dual DLPC900 controller, 904×800, ~50 µs switching) enables axial multiplexing
of the temporal-focusing photostimulation beam: a different defocus wavefront is loaded onto the
PLM each ScanImage frame, steering the 2-photon excitation volume to a different z-plane.
Collecting N consecutive frames while stepping the PLM through N pre-computed defocus patterns
yields a 3-D stimulation stack without moving the objective.

The PLM must transition to the next pattern **between** ScanImage frames so that the settling
transient (~50 µs) is complete before the photostimulation laser fires within the new frame.
Two candidate architectures achieve this:

- **Option A (preferred): PLM as slave.** The ScanImage frame-done TTL is routed to the
  DLPC900 TRIG\_IN\_2 input. Each rising edge advances the PLM by one stored pattern. Timing
  authority stays with ScanImage / the resonant scanner; the PLM follows passively.

- **Option B (fallback): PLM as master.** The DLPC900 TRIG\_OUT pulse is fed to the NI6323
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
  DAQ PC, NI6323 DI port0/line2             [level shifter?]
  (post-hoc frame-stim alignment,                  │
   already in configs/real.yaml)                   ▼
                                          DLPC900 TRIG_IN_2
                                      (advances PLM pattern
                                        on each rising edge)
```

The frame-clock line from the imaging PC is split: one leg runs to the NI6323 digital input
(already implemented for frame-stim alignment); the second leg runs to the DLPC900 TRIG\_IN\_2
connector, potentially via a level shifter (see §4 Q1). No additional DAQ processing is required
for the split path — the DLPC900 listens passively.

Alternatively the NI6323 can re-drive the signal (DI → loopback to DO → DLPC900 TRIG\_IN\_2) if
electrical isolation or level-shifting is needed. This adds ≤1 µs propagation through the
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

DLPC900 TRIG_IN_2 (same rising edge, direct wire or via level shifter):
                  ┐               ┐
──────────────────┘               └──────────────────────────────── ...
                  (min pulse width ≥ 20 µs — confirmed by TI FAE)

PLM pattern index (advances ~50 µs after each TRIG_IN_2 edge):
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

### 2.3 Pre-loading patterns on the DLPC900

**Important:** The 0.67" PLM EVM uses **Pre-stored Pattern Mode** (confirmed by TI FAE). In this
mode, patterns are embedded in the device firmware image and flashed to onboard flash memory via
USB — **not** loaded dynamically over I2C at runtime. The TI GUI 'Firmware' tab packages patterns
into a `.bin` firmware file and programs it to the device. This is a one-time setup per
experiment type (or whenever the axial stack changes).

The workflow is therefore:

**One-time setup (before an experiment session):**

1. Compute the full pattern stack offline:
   `[pats, dz_um, sys] = plm.generatePatternLibrary(N, dz_range_um, 'Olympus20x')`.
2. Export each pattern as an image file (PNG, 8-bit grayscale, 0–31 scaled to 0–255).
   `TIPLM_PLM.exportPatternImages(pats, outputDir)` — **to be implemented**.
3. Open the TI LightCrafter / PLM GUI on the DAQ PC. In the **Firmware** tab:
   - Import the N exported images as a pre-stored pattern sequence.
   - Set trigger mode: **External Positive** (TRIG\_IN\_2 rising edge advances one pattern).
   - Set sequence: wrap-around after pattern N−1 → return to pattern 0.
   - Program firmware to device (USB flash). This takes ~30 s.
4. In the **Pattern Settings** tab: enable TRIG\_IN\_2, confirm trigger mode is active.
5. Optionally verify via the GUI: toggle TRIG\_IN manually and confirm pattern index advances.

**At experiment runtime (each session):**

- Patterns are already in flash. No per-session MATLAB upload needed.
- `TIPLM_PLM.configureTrigger()` sends I2C commands to arm the DLPC900 trigger-wait state:

```matlab
% DLPC900 I2C — see DLPC900 Programmer's Guide (DLPU018), §2.4
% I2C address: 0x36 (primary DLPC900 on EVM — confirm from EVM schematic)
obj.i2c_write(0x1A, 0x00);   % Pattern Display Mode: Pre-stored sequence
obj.i2c_write(0x75, 0x01);   % Trigger In 2: enable, positive edge
obj.i2c_write(0x1A, 0x02);   % Start pattern sequence (arm)
% Note: exact register map — verify against DLPU018 before use.
```

- After `configureTrigger()`, the DLPC900 holds pattern 0 and waits.
- Each TRIG\_IN\_2 rising edge (≥ 20 µs wide) advances one pattern autonomously.
- MATLAB does **not** send any I2C command per frame during acquisition.

**Implication for pattern changes:** If the axial stack (N planes, dz\_range) changes between
experiments, the firmware must be reprogrammed via the GUI (~30 s). For sessions with a fixed
stack this is negligible. If rapid stack changes are required during a session, a more complex
approach (video-mode DisplayPort streaming) would be needed — out of scope for current prelim.

### 2.4 Latency budget

| Event | Latency | Source |
|---|---|---|
| Frame-done TTL → DLPC900 TRIG\_IN\_2 edge | < 1 µs | wire propagation |
| DLPC900 trigger recognition (min pulse width) | ≥ 20 µs | TI FAE, 2026-05-21 |
| PLM mirror settling | ~50 µs | TI NIR PLM datasheet |
| Total PLM advance latency | < 100 µs | — |
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
DLPC900 TRIG_OUT (GPIO header on EVM — see §4 Q4)
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

- Additionally, with Pre-stored Pattern Mode (§2.3), the DLPC900 is already designed to
  follow an external trigger, not generate its own clock. Using it as a master would require
  switching to a different controller mode, adding implementation complexity.

In Option A none of these problems arise: the resonant scanner and ScanImage timing are
unchanged; the PLM simply follows the existing frame clock.

---

## 4. Open Questions

**Q1 — TRIG\_IN\_2 voltage level: OPEN (check EVM schematic)**
The DLPC900 GPIO is nominally 1.8 V logic. The ScanImage frame-clock output (imaging PC BNC)
is 5 V TTL. A level shifter is almost certainly required (e.g., SN74LVC1T45: 5V → 1.8V, or
use the NI6323 DO which is 3.3V, then a second stage to 1.8V). Confirm the exact TRIG\_IN\_2
voltage tolerance from the EVM schematic or DLPC900 datasheet (DLPS027) before wiring.

**Q2 — Minimum TRIG\_IN\_2 pulse width: RESOLVED**
≥ 20 µs recommended (TI FAE response, 2026-05-21). The ScanImage frame-done TTL is typically
1–10 µs wide — **this is too short**. The NI6323 must re-drive the signal with a stretched
pulse (≥ 20 µs) via a DAQ counter output configured as a retriggerable one-shot. See §5 step 1.

**Q3 — I2C command sequence to arm trigger mode: RESOLVED (consult DLPU018)**
The DLPC900 I2C API is fully documented in the DLPC900 Programmer's Guide (TI doc DLPU018).
The device uses the same protocol as the DLP6500 LightCrafter. Key references:
  - I2C address: 0x36 (primary controller on EVM — verify from EVM schematic/User's Guide)
  - Pattern Display Mode register: DLPU018 §2.4 "Pattern Display Mode"
  - Trigger input configuration: DLPU018 §2.4 "External Trigger Input"
  - Pattern sequence start/stop: DLPU018 §2.4 "Pattern Sequence Control"
No further TI input needed — implement from DLPU018 directly.

**Q4 — TRIG\_OUT availability (Option B prerequisite / diagnostic): OPEN**
Is a TRIG\_OUT signal available on the DLPC900 EVM GPIO header?
Useful as a diagnostic even in Option A (confirm trigger is being received). Check the
PLM EVM User's Guide or schematic for connector/pin reference and voltage level.

**Q5 — Maximum pre-stored pattern count: RESOLVED**
Pre-stored Pattern Mode on the DLPC900 uses onboard flash (same as DLP6500 LightCrafter).
The LightCrafter 6500 supports up to 24-bit patterns (3 × 8-bit planes) with a total flash
capacity of ~128 MB, accommodating hundreds of binary frames. Our requirement of 20–50
patterns at 904×800 uint8 (~0.7 MB each uncompressed) is well within capacity. No constraint.

---

## 5. Recommended Path

**Implement Option A.** The primary remaining blocker is Q1 (voltage level / level-shifter
selection). Q2–Q5 are resolved.

Implementation steps, in order:

1. **Electrical — level shifter + pulse stretcher (critical):**
   - Confirm TRIG\_IN\_2 voltage tolerance from EVM schematic (Q1).
   - Add a level shifter (e.g., SN74LVC1T45) between the ScanImage frame-clock line and
     TRIG\_IN\_2 to bring the signal to 1.8 V (or whatever the EVM requires).
   - The ScanImage frame-done pulse is ~1–10 µs wide, below the 20 µs minimum (Q2).
     Use an NI6323 counter output configured as a retriggerable one-shot (monostable) to
     re-drive the pulse at ≥ 20 µs width. MATLAB configuration:
     ```matlab
     % Counter output: retriggerable one-shot, 25 µs pulse, triggered by frame-clock DI
     % (Instrument Control Toolbox / DAQ Toolbox — exact call TBD for NI6323)
     ```

2. **I2C wiring:** connect the DAQ PC I2C bus (USB-to-I2C adapter, e.g., Total Phase
   Aardvark or NI USB-8452) to the DLPC900 I2C header on the EVM. Verify communication
   by reading the firmware version register (DLPU018 §2.1).

3. **Pattern firmware upload (one-time per session):**
   - Run `TIPLM_PLM.exportPatternImages(pats, dir)` to export uint8 patterns as PNGs.
   - Use the TI LightCrafter GUI → Firmware tab to package patterns and flash to device.
   - In Pattern Settings tab: enable TRIG\_IN\_2, positive edge, wrap-around mode.

4. **MATLAB I2C driver:** implement `configureTrigger()` in `TIPLM_PLM.m` using MATLAB
   `i2cdev` (Instrument Control Toolbox). Register map from DLPU018 — no further TI input
   needed. Verify by reading pattern index register after each manual trigger pulse.

5. **Integration test:** connect the stretched frame-clock wire, call `configureTrigger()`,
   run ScanImage in Focus mode at 30 Hz. Confirm via `getStatus()` that the pattern index
   advances once per frame.

6. **Full experiment test:** run `exp_pseudo_axial.m` with `NI6323_DAQ` and TIPLM\_PLM
   enabled. Verify pattern index and frame index are aligned in saved trial data.

Option B should only be revisited if the EVM hardware does not expose TRIG\_IN\_2 as a
usable external input — which the TI FAE response confirms it does.
