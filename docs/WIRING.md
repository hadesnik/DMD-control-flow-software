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

| Field | Value | Filled in by / date |
|---|---|---|
| NI terminal used (e.g. `ao1`) | | |
| Physical screw-terminal / BNC breakout label | | |
| Cable label | | |
| Control voltage range accepted by the CARBIDE | 0–5 V or 0–10 V? | |
| **Polarity: does 0 V mean OFF?** | | |
| Maximum safe command voltage | | |
| `laser.carbide_modulator_ao_channel` set in `configs/real.yaml` | ☐ | |

Polarity is the one that can hurt: if 0 V means *full power* rather than off,
then every zero-on-error path in the software — `zeroQuiet`, the destructor,
`shutdown`, the BEAM OFF button — drives the laser to maximum instead of
minimum. **Verify it on a meter before connecting the beam to the sample**, and
record who verified it and when.

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
