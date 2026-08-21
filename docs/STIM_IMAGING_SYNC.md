# Stim/imaging synchronisation — killing the photostim fluorescence artifact

**Status: analysis, 2026-08-21. Nothing wired, nothing implemented.** This document
settles one specific question that will otherwise keep coming back, then lays out the
trigger topology that does work.

Numbers marked *(est.)* are back-of-envelope. Everything attributed to a manual carries
its section reference; those are quotes, not recollections.

Related: [WIRING.md](WIRING.md) (the physical pin record), [SYNC.md](SYNC.md) /
[SYNC_FRAME.md](SYNC_FRAME.md) / [SYNC_EPISODIC.md](SYNC_EPISODIC.md) (trial↔frame
alignment, a different problem), [KILLER_DEMO_PLAN.md](KILLER_DEMO_PLAN.md) §"Imaging
artifact" (the censor-channel sketch this document extends).

---

## The problem

The 1038 nm CARBIDE stim beam directly two-photon-excites GCaMP. Every stim pulse
produces a burst of real fluorescence that the non-descanned PMT collects along with
the imaging signal, because the stim targets are inside the imaged field. It is not
scattered stim light leaking past an emission filter — it is the indicator doing
exactly what it is supposed to do, driven by the wrong laser.

## The idea that does not work, and why

> Phase-lock the CARBIDE to the Chameleon Ultra II's 80 MHz so the stim pulses land
> exactly halfway between imaging pulses (6.25 ns), and have ScanImage sample the PMT
> only in a window around the Ti:Sapph pulse. The stim-driven transient then falls
> outside every sampling window.

The physics is real — this is how temporal multiplexing works in 2p imaging (Cheng et
al., *Nat Methods* 2011, interleaving beams at exactly 6.25 ns). It fails here on **two
independent grounds, either of which is sufficient.**

### 1. The CARBIDE cannot be phase-locked to 6.25 ns

From `CARBIDE-CB3-40W-User-Manual.pdf`:

| § | Finding |
|---|---|
| 3.1, 3.3 p24 | The RA fires on the CARBIDE's **own free-running ~65 MHz Kerr-lens oscillator**: `OSC freq / N = RA freq`. Output pulses are quantised to that ~15.4 ns seed comb. The oscillator is "managed automatically by the laser's internal firmware" — no user-accessible cavity-length actuator. |
| 5.8.2 p67 | Standard external pulse-picker trigger: jitter = `1/f_RA` = **0.5–25 µs**. SPPT / Pulse-on-Demand: jitter **16 ns**, plus a *fixed* delay of `2/f_RA + ~300 ns`. |
| 5.8.4 p70 | `SYNC_IN` (XS13 pin 14) locks the RA **frequency** to an external clock — it selects which seed pulse gets amplified. It does **not** lock the seed oscillator's phase. |
| E1023 p105 | "External RA sync is not compatible with SPPT mode." The two best options are mutually exclusive. |

**16 ns of jitter against a 12.5 ns period means the stim pulse lands at a uniformly
random phase within the imaging period.** That is the opposite of phase-locked, and it
is the best the laser offers.

Even granting a miracle lock: 65 and 80 MHz share a 5 MHz subharmonic (13 × 15.3846 ns
= 16 × 12.5 ns = 200 ns), so achievable offsets fall on a 0.96 ns grid and you could
land within ~0.5 ns of the midpoint. Academic. Coherent's product for locking an
oscillator to an external reference, Synchrolock-AP, supports **Mira and Vitara-T
only** — not Chameleon — and in any case it is the *Ti:Sapph* it moves, while the
un-lockable oscillator here is the CARBIDE's.

### 2. Even with a perfect lock, gating buys only ~10×

GCaMP is a GFP-family fluorophore, lifetime commonly **2.3–3.5 ns**. At a 6.25 ns
offset, `exp(−6.25/3) ≈ 12%` of the stim-driven fluorescence is still in flight when
the imaging pulse arrives. **Suppression is ~8–12×, not elimination** — the same limit
the multiplexing literature states outright ("the degree of temporal multiplexing is
limited by the fluorescence lifetime of the excited fluorophore").

That would be fine if the two signals were comparable. They are not. Two-photon yield
per pulse scales as `E² / (τ_p · A)`:

| | per-pulse energy | pulse width | spot area |
|---|---|---|---|
| Chameleon imaging, ~30 mW @ 80 MHz | 0.375 nJ | 140 fs | ~0.3 µm² |
| CARBIDE, one target @ 20 mW, 100 kHz | 200 nJ | 205 fs | ~79 µm² (Ø10 µm) |

Ratio ≈ **700×** *(est.)* — one CARBIDE pulse yields ~700× the fluorescence of one
imaging pulse, from a **single** target. It scales linearly with simultaneous target
count (`E²/A ∝ N²/N = N`), so a 50-cell ensemble is ~3×10⁴. Against 10²–10⁴, a factor
of 10 is not a fix.

### 3. The scheme gates the wrong element

Even at infinite suppression ratio, a digitizer sampling window **cannot un-saturate a
PMT**. The photon burst hits the GaAsP tube regardless of when the ADC looks; space
charge and preamp recovery persist for microseconds, far beyond the ~3 ns fluorescence
decay. Any real protection has to sit *upstream* of the detector — a gated PMT or a
blanked preamp — or accept the hit and censor the affected samples.

**This is the deepest reason the idea fails, and it survives every hardware upgrade.**

---

## What ScanImage can actually do

Three features that are easy to conflate. Only one of them is gating.

| Feature | What it does | Use here |
|---|---|---|
| **Synchronization to Laser Clock** | Slaves the sample clock to the laser so each pixel gets a constant number of pulses. vDAQ accepts 1–125 MHz on `CLK IN` (SMB). | **Not gating.** Nice-to-have for imaging stability; irrelevant to the artifact. |
| **Acquisition Gating for low rep rate Lasers** | *Is* a sampling window drawn relative to the laser pulse, in both resonant and linear mode. Built for **<10 MHz** (3-photon). | Useless at 80 MHz on a standard vDAQ: 125 MHz max sample rate gives **one sample per 12.5 ns period**, so there is no sub-period window to draw. SI's own sizing rule (`capture length > 4 × sample_rate / laser_freq`) degenerates to 6 ticks. |
| **vDAQ-HS photon counting** | 2.0–2.7 GHz sampling, sub-ns resolution, photons binned into **up to 32 virtual channels by temporal windows defined relative to each laser pulse**; laser clock 62.5–84.375 MHz. | The only ScanImage path to genuine intra-period gating. We do not have the HS card, and per §2 above it would still only buy ~10×. |

**Out of the box, ScanImage does not sample only around the oscillator pulse.** Each
pixel is the mean of the PMT signal over the full dwell time.

---

## The signals that do exist

All confirmed against manuals; none wired yet. Electrical detail and fill-in tables
live in [WIRING.md](WIRING.md) — this table is the map, that document is the record.

| Signal | Source | Nature | Role here |
|---|---|---|---|
| **Fast photo diode (sync out)** | Chameleon Ultra II laser head, rear BNC | 80 MHz pulse-train reference | Confirmed present (Coherent Chameleon Ultra/Vision/Vision-S Operator's Manual doc 1313538, Table 5-1). Needed only if we ever pursue laser-clock sync; **not needed for any option below.** Spec unstated in the manual — scope it before trusting it. |
| **Period Clock** (a.k.a. SYNC / Trigger) | Resonant scanner **controller**, already wired to the digitizer | TTL, low→high "at a precise phase of the resonant mirror's scan motion"; one period = **two image lines** (bidirectional) | **The enabling signal for Option A.** T it out to the DAQ PC. |
| **`SYNC_OUT`** | CARBIDE XS13 **pin 18** | TTL 3.3 V, ~500 ns wide, at the RA rate, **jitter ~0.5 ns** | Marks every stim pulse. The right signal for PMT blanking and for post-hoc pixel censoring. Not on the XS13-A-BNC adapter — needs the D-SUB 25. |
| **`PP_EN`** | CARBIDE XS13 **pin 16** | TTL in, internal pull-up, active-low recommended | The gate. Broken out as the "PP" BNC on the shipped XS13-A-BNC adapter — no soldering. |
| **`XB8` LASER_OUT** | CARBIDE BNC | analog photodiode | Alternative censor channel (already noted in WIRING.md). Verify whether it taps before or after the pulse picker — only post-picker tells you which pulses actually left. |

---

## Option A — fire the CARBIDE only during resonant turnaround *(recommended)*

The resonant mirror spends a fixed fraction of every half-period outside the imaged
field. ScanImage discards those samples and **already attenuates the imaging beam
there** to avoid burning the sample. That dead time is free real estate: a stim pulse
placed inside it cannot contaminate a pixel, because no pixel is being acquired.

The artifact is then **structurally zero** — not suppressed, not censored, absent. No
gated PMT, no HS digitizer, no post-hoc interpolation.

### The budget

At ScanImage's default `fillFractionSpatial = 0.9`:

```
fillFractionTemporal = (2/π)·asin(0.9) = 0.713   →   28.7% of every half-period is dead
```

**This fraction is independent of resonant frequency** — 8 kHz and 12 kHz give the same
28.7%, just in differently sized slices.

| | 8 kHz resonant | 12 kHz resonant |
|---|---|---|
| Half-period | 62.5 µs | 41.7 µs |
| Imaged / dead | 44.6 µs / **17.9 µs** | 29.7 µs / **12.0 µs** |
| Turnaround windows per second | 16,000 | 24,000 |
| CARBIDE pulses landing in dead time @ `f_RA` = 100 kHz | ~1.8 per window → **~28,700/s** | ~1.2 per window → **~28,700/s** |

Keeping ~28.7% of a 100 kHz train costs **3.5× longer stimulation for the same
two-photon dose** (dose ∝ `N · E²`), or **1.9× the per-pulse energy** if you would
rather pay in power than in time. If that is too steep, raising `f_RA` to 1 MHz puts
~18 pulses in each 8 kHz turnaround — comfortably *more* stim pulses per second than
the 100 kHz plan delivers — at the cost of 10× lower per-pulse energy, which two-photon
excitation punishes quadratically. **Prefer buying time over rep rate.**

### Why this does not move the safety envelope

Gating `PP_EN` changes **pulse count, not per-pulse energy** — the RA keeps running at
`f_RA` and the picker dumps the rest. `tfp.util.assertPulseEnergySafe` gates per-pulse
energy at the pupil, which duty-cycling does not touch. Average power at the sample
falls to ~29%; the hazard calculation is unchanged.

This is the same structural fact that makes mirror-PWM grayscale safe in
[KILLER_DEMO_PLAN.md](KILLER_DEMO_PLAN.md) §"The neural LUT" — worth noticing that the
two mechanisms compose cleanly rather than fighting.

### Topology

```
resonant controller ──Period Clock (TTL, 8 kHz)──┬──> digitizer  (existing)
                                                 └──> DAQ PC PFI
                                                        │
                                        NI 6323 counter: retriggerable
                                        single pulse, delay D, width W
                                        (100 MHz timebase → 10 ns resolution)
                                                        │
                                                        v
                                         CARBIDE XS13.16 PP_EN  ("PP" BNC)
```

Three things to get right:

1. **Phase, `D`.** The Period Clock's edge sits at *some* phase of the mirror motion,
   not necessarily at a field edge — ScanImage exposes a Scan Phase control precisely
   because of this. `D` must be found on the bench against the actual scan, not
   computed. Sweep it and watch where the artifact goes.

2. **⚠️ The SPPT fixed delay can exceed the window.** SPPT's deterministic delay is
   `2/f_RA + ~300 ns` = **20.3 µs at `f_RA` = 100 kHz**, which is *longer than the
   17.9 µs turnaround* at 8 kHz. The trigger must therefore lead by more than a full
   half-line, landing its pulse in a *later* turnaround. Deterministic, so it is only a
   phase offset — but the DMD pattern must also be settled that far in advance, which
   couples this to sequence timing. At `f_RA` = 1 MHz the delay drops to 2.3 µs and the
   problem disappears. **Enable SPPT**; the alternative 0.5–25 µs jitter of standard
   external triggering is unusable against a ~18 µs window.

3. **Jitter is a non-issue.** 16 ns against 17.9 µs is 0.09%.

### Costs and caveats

- **The DMD becomes the pacing element.** 12,500 binary frames/s against 16,000
  turnarounds/s at 8 kHz — you can use at most ~78% of turnarounds if each carries a
  new pattern. One pattern per turnaround is a clean design point; it is also almost
  exactly the chip's ceiling, so there is no headroom above it.
- **Counter/timer work belongs behind the abstraction.** Per `CLAUDE.md`, no code
  outside `+hardware/` touches a hardware-specific API — this needs a method on the DAQ
  base class (e.g. `configureRetriggerablePulse`), not raw DAQmx in a script.
- **Linear/galvo scanning has no turnaround to hide in** at the same duty. This option
  is resonant-only.
- Not compatible with `SYNC_IN` frequency locking (error E1023), which we do not need.

---

## Option B — censor channel (post-hoc)

Already sketched in [KILLER_DEMO_PLAN.md](KILLER_DEMO_PLAN.md) §"Imaging artifact":
digitize a stim-pulse marker on a spare channel, bin it per-pixel like another colour
channel, censor a **~1 µs window** (not just the coincident pixel — a PMT hit that hard
rings afterwards). At 100 kHz that is ~1% of pixels naively, ~10% with the window.

Two refinements from this analysis:

- **Prefer `SYNC_OUT` (XS13.18, 0.5 ns jitter) over the `XB8` analog photodiode** where
  a digital marker suffices — it is cleaner, already conditioned, and needs no
  threshold. Keep XB8 in reserve for the question SYNC_OUT cannot answer: whether a
  pulse actually left the laser (SYNC_OUT is derived from the OSC/`SYNC_IN`, so verify
  whether it tracks the pulse picker before relying on it for that).
- **⚠️ Option A and the "dither the stim trigger phase" advice in KILLER_DEMO_PLAN are
  mutually exclusive.** Dithering deliberately randomises stim phase against the line
  rate so contaminated pixels scatter instead of forming stripes. Option A deliberately
  *locks* stim phase to the line rate so contaminated pixels do not exist. Do not do
  both — locking with a wrong `D` gives you the worst case, a fixed stripe. **Pick a
  branch:** Option A if the phase can be held reliably, dithering + censoring if not.

Option B remains the right answer for linear scanning, and is worth building regardless
as the verification channel that tells you Option A is actually working.

## Option C — blank the PMT

Drive a gated PMT (e.g. Hamamatsu H11706P-40 with a gating socket) or a fast blanking
switch on the preamp from `SYNC_OUT`. ~1 µs blank at 100 kHz costs 10% duty cycle,
uniformly and correctably. This is what Yang et al. (*eLife* 2018, 32671) point at:
"an alternative method is to gate the PMT, or the PMT's output during the
photostimulation pulse, though this requires dedicated additional electronics."

It is the only option that protects the tube itself, so it is the fallback if Options A
and B both leave visible ringing. It is also the most hardware to buy and integrate —
do not start here.

---

## Recommendation

1. **Build Option B first** (censor channel on `SYNC_OUT`). It is a wire, a DI line and
   post-processing; it works in every scan mode; and it is the instrument that measures
   whether anything else is working.
2. **Then attempt Option A.** If the turnaround phase holds, the artifact disappears
   entirely and B becomes a verification channel rather than a correction.
3. **Hold Option C in reserve** for evidence of PMT ringing that survives A.
4. **Do not pursue laser phase-locking.** Revisit only if the stim laser is replaced
   with one having a lockable oscillator *and* a vDAQ-HS is acquired — and even then,
   re-read §3 above first, because the PMT is still upstream of the digitizer.

### Bench checklist

- [ ] Scope the resonant controller's Period Clock; confirm polarity and that it is
      free to T without loading the digitizer input.
- [ ] Scope CARBIDE `SYNC_OUT` (XS13.18) on **1 MΩ**, not 50 Ω. Confirm it fires at
      `f_RA`, and determine whether it tracks the **pulse picker** or only the RA.
- [ ] Confirm `PP_EN` active-low gating closes the output by default (internal
      pull-up, §5.8.1 p66).
- [ ] Enable SPPT in the CARBIDE User App; confirm preset applies (§5.8.2 p68) and note
      the measured fixed delay against `2/f_RA + 300 ns`.
- [ ] Sweep the counter delay `D` and record where the artifact minimises.
- [ ] Measure how many pixels remain contaminated, and for how long after a pulse — the
      PMT ringing duration is the number that decides whether Option C is needed.

---

## ⚠️ Adjacent config gap found while writing this

`Sequencer.m` defaults `daq.frameClockLine` to **`port0/line2`**, but **no config file
sets the key**, and `configs/real.yaml` wires the ScanImage frame clock on
**`port0/line1`** (its `daq.digitalInChannels` lists only `port0/line1`). So on the rig
the default would not match the wired line and frame-clock capture would be dropped.

This is caught, not silent: `Sequencer.resolveDiLines` warns
`tfp:trial:Sequencer:noFrameClockLine` — "frame-clock capture disabled for this
session" — and `buildSessionCfg` then passes `frameClockLine: ''`, after which the
alignment path returns without decoding. Loud at session start, quiet thereafter, which
is the right shape but easy to scroll past in a long run log.

Fix belongs on the rig side: add `frameClockLine: 'port0/line1'` under `daq:` in
`real.yaml`. That file is not written from a dev machine. Changing the code default to
`port0/line1` would also work and is arguably better, since the default currently
documents a wire-up that exists nowhere — but it would silently change behaviour for
any rig that *had* been relying on `line2`, so it is a rig decision either way.
