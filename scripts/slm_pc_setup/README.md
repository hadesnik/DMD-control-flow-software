# SLM PC setup (Meadowlark 1K via Blink SDK)

The Meadowlark HSP1K lives on its own Windows PC with the PCIe controller and
the Blink SDK. The DAQ PC never sends pixels — it sends a small **mask spec**
(defocus list + optics parameters) and this PC recomputes the masks with the
same shared `tfp.slm` engine, uploads them, and arms sequencing. Runtime
advance is a TTL from the DAQ PC (port0/line8) or the network `'ADV'` fallback.

## One-time setup

1. **Clone this repo** onto the SLM PC (any path).
2. **Install MATLAB** (R2019b+) and make sure the Blink SDK / Meadowlark
   software that shipped with the PCIe controller is installed.
3. **Vendor the SDK header** (blocking gate for real hardware):
   - locate the Blink C wrapper header + DLL in the Meadowlark install;
   - copy the header (+ SDK manual PDF) into `vendor/meadowlark/official/`
     in the repo (strip any `.git/` from copied folders);
   - complete `docs/blink-api-audit.md` — every function `BlinkSLM.m` needs,
     cross-referenced to header line numbers; confirm whether this unit
     supports onboard sequence memory + external-trigger advance;
   - fill in the `%VENDOR-AUDIT` blocks in `src/+tfp/+hardware/BlinkSLM.m`.
   Never invent Blink function names.
4. **Edit `slm_pc_config.m`**: port (default 3046), msocket path, Blink DLL /
   header / LUT paths. Keep `dryRun = true` until step 3 is complete.
5. **Get the msocket library** onto this PC (same library the imaging PC
   uses) and point `cfg.msocketPath` at it.

## Running

```matlab
cd <repo>; addpath('src'); addpath('scripts/slm_pc_setup');
slm_server            % listens on port 3046 until SHUTDOWN / Ctrl-C
```

Leave it running; the DAQ PC connects per experiment
(`tfp.hardware.MeadowlarkSLM`). `dryRun = true` exercises the full protocol
(spec → masks → READY) without touching hardware — use it to verify the link
before the Blink audit lands.

## Wiring

- **TTL advance**: DAQ PC `port0/line8` ("SLM trigger out") → the SLM
  controller's external trigger input. Only used once the Blink audit
  confirms hardware-trigger sequencing; until then `trigger_mode: software`
  in the rig config uses the network `'ADV'` path (between-depth-group
  advances are hundreds of ms apart, so latency is immaterial).
- **Network**: the SLM PC must be reachable from the DAQ PC; this PC is the
  msocket **server** (direction reversed vs every other lab link — it has to
  accept connections unattended).
