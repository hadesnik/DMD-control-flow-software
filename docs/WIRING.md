# NI PCIe-6323 wiring — DAQ PC

The physical wiring record for the DAQ PC's NI PCIe-6323. **Software cannot
discover any of this**, so a row that is not filled in here is a row that does
not exist as far as the control code is concerned.

Rows marked **TBD** are placeholders. `tfp.hardware.LaserPowerController`
refuses every output while `laser.carbide_modulator_ao_channel` is empty and
tells the operator to come here — the config placeholder is load-bearing, not
decorative.

---

## Confirmed

Cross-referenced with Masato's DAQ code, 2026-05-29.

| Line | Dir | Connected to | Notes |
|------|-----|--------------|-------|
| `ai2` | in | Multiclamp 700B output | primary ephys / patch electrode |
| `ai3` | in | Stim trigger monitor | read back for post-hoc alignment |
| `ao0` | out | Multiclamp 700B ch1 command | postsynaptic cell command |
| `ao2` | out | Multiclamp 700B ch2 command | presynaptic cell — normally unused |
| `ao3` | out | NKT FS-50 power modulator | **build A** photostim laser power, 0–5 V |
| `port0/line10` | out | ScanImage acquisition trigger | rising edge starts SI |
| `port0/line8` | out | SLM trigger out | Meadowlark sequence advance |
| `port0/line1` | in | ScanImage frame clock | rising edge = frame acquired |

## TBD — fill this in at the bench

### CARBIDE external modulator (build B photostim power)

The one that matters for the first DMD-at-sample calibrations.

**The modulator is FEC — Fast Energy Control — on connector `XB14`.** Source:
`docs/CARBIDE-CB3-40W-User-Manual.pdf` (the full 127-page manual; the
`… - Installation.pdf` alongside it is only the 17-page installation chapter and
is image-only). Sections §5.8.3 p70 and §6.7 p93.

#### Specified by the manual (no bench measurement needed)

| Field | Value | Manual ref |
|---|---|---|
| Connector | `XB14`, "External Fast Energy Control (FEC) analog input" | §6.7 p93 |
| **Physical location** | Rear panel, **far top-right corner** — alone on the upper strip, well right of `XS13`, above the LIGHT CONVERSION logo plate and near the water IN/OUT fittings. It is **not** in the `XB4`–`XB9` BNC cluster at bottom-left, which is where people look first. | Figure 74, p85 |
| Control voltage range | **0 – 10 V** | §5.8.3 p70, Table 24 p93 |
| Transfer function | **Output energy linear in input voltage** | §5.8.3 p70 |
| Output power response latency | < 10 µs | Table 24 p93 |
| Modulation speed | < 2 µs | Table 24 p93 |
| Granularity | full-scale **individual pulse** amplitude control, pulse-to-pulse to 1 MHz | §5.8.3 p70, Table 24 p93 |
| Software gate | User app → External control → "Analog input (0 – 10 V) to XB14"; source also selectable in the app's advanced section | §5.8.3 p70, §6.7 p93 |
| Cable requirement | **ferrite beads on any BNC cable into the laser** | Notice, p86 |

**The alternative analog path does not apply to this unit.** XS13 pin 24
(`VAC_CTRL`, 0–5 V, the "AV" line on the shipped XS13-A-BNC adapter) is "used only
if laser is equipped with Integrated attenuator, AOM, or CBM02 / CBM04 harmonics
modules" (Table 20 p90), and its energy response is *not* linearized, with a 15 mV
deadband (§5.8.3 p70). Quote Q260513-BM3 lists the base laser plus the integral
pulse picker only — no attenuator, no AOM. Confirm against the as-built config,
but plan on **FEC/XB14 being the only analog power path**.

#### ⚠️ Confirm before buying a cable — the manual does not say

| Field | Value | Filled in by / date |
|---|---|---|
| **XB14 connector type** (BNC likely, never stated in text) | | |
| **XB14 input impedance — 50 Ω or high-Z?** | | |

Connector type is settleable by eye at the laser: a **BNC** receptacle has two
bayonet lugs on the outside of the barrel and a slotted channel — you push and
quarter-turn. An **SMA** has a finely threaded barrel and needs a wrench-tightened
nut. Figure 74 draws XB14 as coax with a bayonet channel, so BNC, but the manual
never says it in words — check the hardware, not the drawing.

Impedance can block the whole approach. The NI PCIe-6323's AO outputs source only
a few mA. If XB14 is 50 Ω terminated the 6323 cannot drive it near 10 V and a
buffer amplifier goes between them. If it is high-Z — as XS13 and the XS13-A-BNC
adapter explicitly are ("not terminated at 50 Ohm", p42 / p89) — the DAQ drives it
directly. LC support can answer it, but the bench settles it faster.

#### Bench protocol — settle the interface before the beam is a variable

Steps 1–2 need no beam. Do them before step 3; that ordering is the whole point.
Kit: DMM, **BNC T**, the FEC cable, a low-power laser preset.

**1. Impedance, unpowered — 30 seconds.**
Laser powered off, nothing connected to XB14. DMM in resistance mode across the
XB14 centre pin and shell. Resistance mode sources microamps into a 0–10 V analog
input, so this is harmless.
- ~50 Ω → **50 Ω terminated**: the 6323 cannot drive it; a buffer amp is required.
- Open / many kΩ → **high-Z**: the DAQ drives it directly. Go to step 3.

**2. Impedance, loaded — if step 1 is ambiguous.**
Protection diodes or an active front end can read oddly with the laser off. So:
laser on, FEC selected in the User app, **beam blocked / shutter closed**, cable
connected, BNC T at the *XB14 end* (not the DAQ end), DMM on the T. Command
0 / 2.5 / 5 / 7.5 / 10 V from the DAQ and read each.
- Tracks command within a few mV → high-Z.
- Collapses to well under a volt → 50 Ω.
- Droops a few percent → an intermediate load, e.g. the 1 kΩ that XS13 pin 24
  specifies. Drivable, but record it: that droop would otherwise be absorbed into
  the volts→mW curve as fake laser nonlinearity.

**3. Only then, the power sweep** (§3 of [BRINGUP_GUIDE.md](BRINGUP_GUIDE.md)).
Power meter at the sample plane, **low preset**, and measure the 0 V residual
first. This is a calibration you need saved to `laser.carbide_calibration_file`
regardless, not a throwaway diagnostic.

> **Why not just do step 3 and infer impedance from it?** Because a low reading at
> 10 V has at least four causes and the power number cannot separate them: 50 Ω
> loading; FEC not actually selected in the User app (so preset power is showing
> regardless of voltage); FEC full-scale not mapping to the preset maximum the way
> you assumed — itself untested, and being used as the reference; or a transfer
> curve that is not what the manual implies. The intermediate-load case is the
> nastiest: a few percent of DAQ sag reads as mild laser nonlinearity, gets written
> into the curve, and is never noticed. A DMM reading 9.7 V instead of 10.0 V says
> it immediately.

#### Fill in at the bench

| Field | Value | Filled in by / date |
|---|---|---|
| NI terminal used (e.g. `ao1`) | | |
| Physical screw-terminal / BNC breakout label | | |
| Cable label | | |
| **Polarity: does 0 V mean OFF?** | | |
| Measured residual output at 0 V (mW at sample) | | |
| Maximum safe command voltage | | |
| `laser.carbide_modulator_ao_channel` set in `configs/real.yaml` | ☐ | |
| `laser.carbide_voltage_max` raised 5.0 → 10.0 in `configs/real.yaml` | ☐ | |

Polarity is the one that can hurt: if 0 V means *full power* rather than off,
then every zero-on-error path in the software — `zeroQuiet`, the destructor,
`shutdown`, the BEAM OFF button — drives the laser to maximum instead of
minimum. **Verify it on a meter before connecting the beam to the sample**, and
record who verified it and when. The manual's "energy is linear in input voltage
over 0–10 V" implies 0 V is minimum, but that is an inference from a transfer
curve, not a stated safety property — measure it.

> **FEC attenuates; it does not block.** It modulates pulse energy and the manual
> specifies no residual leakage at 0 V. The real beam-off is the shutter (XS13
> pin 25 `SHUTTER_CTRL_TTL`, or XB3). Do not treat a 0 V command as a closed
> shutter in any procedure or interlock.

> **`carbide_voltage_max` is currently wrong.** `configs/real.yaml` carries
> `carbide_voltage_max: 5.0`, but FEC is a 0–10 V input — at 5 V you reach only
> half of full scale and halve the energy resolution. The 6323's AO range is
> ±10 V, so it covers the full span. Rig-side edit; `real.yaml` is not written
> from a dev machine.

### Other CARBIDE lines available (reference, nothing wired yet)

Not part of the modulator path, but this is the document to look them up in.
BNC connectors are §6.1 p86; XS13 pinout is Table 20 p89–90.

| Line | Type | Dir | Use here |
|---|---|---|---|
| `XB8` LASER_OUT | BNC, analog | out | Laser-output photodiode. **Candidate for the per-pixel stim-censor channel** — see [KILLER_DEMO_PLAN.md](KILLER_DEMO_PLAN.md). Check whether it sits before or after the pulse picker; only post-picker tells you which pulses actually left. |
| `XB4` OSC_OUT | BNC, analog | out | Oscillator pulse-train photodiode |
| `XB5` / `XB7` / `XB9` | BNC, 3.3 V, 50 Ω | out | Configurable digital outputs, set in the Service app (§5.14 p79) |
| `XS13.18` SYNC_OUT | TTL 3.3 V, 25 mA | out | ~500 ns sync, jitter ~0.5 ns — candidate hardware timebase for the DAQ |
| `XS13.16` PP_EN | TTL 3.3 V, 5 V-tol | in | External pulse-picker gate. On the shipped **XS13-A-BNC adapter** as the "PP" BNC — no soldering. Use **active low**: the pin has an internal pull-up, so default-high leaves the output closed (§5.8.1 p66). |
| `XS13.25` SHUTTER_CTRL_TTL | TTL 3.3 V, 5 V-tol | in | Shutter open on high — the real beam-off |

Oscilloscope note: read the 3.3 V digital outs with a **1 MΩ** input, not 50 Ω (p86).

### Arm transmission (laser → sample)

| Field | Value | Date |
|---|---|---|
| Power at the laser head (W) | | |
| Power at the sample plane (W) | | |
| Ratio → `laser.arm_transmission` | | |

Until this is measured, `tfp.util.assertPulseEnergySafe` uses the handoff §7a
figure of **0.182** and warns `:armTransmissionAssumed` on every call. The
warning is not noise: the volts→mW curve is measured *at the sample* while the
air-breakdown hazard sits at a pupil upstream of the whole arm, so a
sample-plane number understates the pupil pulse energy by roughly 5.5×.

Entering the laser's **front-panel average power** in the GUI's laser-state
panel sidesteps the assumption entirely, which is why the app asks for it.

---

## Why the modulator is the only laser parameter software can move

The CARBIDE control software runs on the Holo/SLM PC and this repo
deliberately does not talk to it [USER 2026-08-19]. Rep rate, pulse-picker
division and shutter are set by a human on that machine and typed into the
GUI's laser-state panel, where they are stamped into every saved calibration.

That is not squeamishness about sockets — it is what makes the interlock
tractable. Every pulse-energy calculation in
`tfp.util.assertPulseEnergySafe` assumes the rep rate is what the operator
said it was. If software could change the rep rate, every such calculation
would be racing a value it does not own.
