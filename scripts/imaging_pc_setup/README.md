# Imaging PC Setup Scripts

These scripts run on the **IMAGING PC**, not the DAQ/scope PC.
Copy this entire folder to the imaging PC before running experiments.

Current rig addressing (confirmed 2026-08-05) — the two PCs talk over a
**private link**, not the campus subnet:

| PC | Hostname | IP | Role |
|----|----------|----|------|
| Imaging | `ScanImage-PC` | `192.168.10.104` | ScanImage SI2019bR0, MATLAB R2019b. Runs these scripts. |
| DAQ / scope | — | `192.168.10.110` | Timing master, DMD, NI PCIe-6323. msocket **server**. |

Earlier revisions of this repo document `128.32.177.205` / `128.32.177.203`.
Those are stale campus-subnet addresses — do not use them. Live values always
come from `imaging_pc_config()`, never from this table.

## What these scripts do

The scope PC drives all acquisition timing via TTL triggers. These scripts add
a second communication channel (port 3044) that streams per-frame ROI fluorescence
values back to the scope PC in real time, enabling live ΔF/F monitoring.

Port assignment:
- **3043** — control channel (ScanImage metadata, already in SImsocketPrep.m)
- **3044** — F-streaming channel (these scripts)

## Machine-local configuration

The msocket library path, the scope-PC IP, and the socket ports live in one
place: [`imaging_pc_config.m`](imaging_pc_config.m). The scripts call it — they
contain no hardcoded paths.

To adapt a new/reimaged imaging PC **without editing tracked code**, copy
`imaging_pc_config_local.m.example` to `imaging_pc_config_local.m` (gitignored)
and set only the fields that differ (typically `msocketPath` and `scopePcIp`).
Anything you omit keeps the rig default in `imaging_pc_config.m`.

## Session workflow

### Once per scope session (imaging PC, before first trial)

1. Open MATLAB on the imaging PC.
2. First run only: confirm `imaging_pc_config` is correct for this machine
   (msocket path + scope-PC IP). It adds msocket to the path automatically.
3. In ScanImage, enable **ROI Integration** and draw ROIs around your target cells.
4. Run:
   ```matlab
   SIStreamSetup
   ```
   The script connects to the scope PC and registers the frame callback.
   It will print "Frame callback registered. Ready for experiment." when done.
5. On the scope PC, run the experiment as normal (exp_ppsf_2d, etc.). The scope
   PC's `armStreaming` call in the Sequencer listens for the connection above.

### End of session (imaging PC)

**Stop the Focus/Grab first** — ScanImage won't let user functions be modified
during an active acquisition. Then:

```matlab
SIStreamTeardown
```

This closes the socket and removes the frame callback cleanly. (Likewise, run
`SIStreamSetup` while idle, *then* start Focus — both scripts now error early
with a clear message if ScanImage is acquiring.)

## Files

| File | Purpose |
|------|---------|
| `imaging_pc_config.m` | Central settings (msocket path, scope-PC IP, ports); adds msocket to path |
| `imaging_pc_config_local.m.example` | Template for per-machine overrides (copy to `imaging_pc_config_local.m`) |
| `probe_scanimage_config.m` | **Read-only** diagnostic — dumps this PC's live ScanImage config |
| `SIStreamSetup.m` | Run once per session to connect and register the callback |
| `si_frame_callback.m` | ScanImage `frameAcquired` callback — do not call directly |
| `si_send_rois.m` | Send ROI centroids to the scope PC after drawing ROIs |
| `SIStreamTeardown.m` | Run at end of session to disconnect cleanly |
| `test_msocket_link.m` | Control-channel dry-run; no ScanImage, no hardware |

## Checking this PC's ScanImage config

`probe_scanimage_config` reports the values the DAQ PC needs but cannot see:
which external-trigger terminals are available, how per-trial TIFF paths are
derived, the frame rate, and whether ROI integration is live. It is strictly
read-only — it never writes to `hSI` or touches `logFileCounter`.

```matlab
probe_scanimage_config     % with ScanImage open; run before first triggered session
```

Run it after any ScanImage upgrade or rig rewire, and paste groups 2 and 3 into
the rig log. Property names were confirmed against the installed **SI2019bR0**
source; anything reported `MISSING` means a property moved and the episodic
contracts in [`docs/SYNC_EPISODIC.md`](../../docs/SYNC_EPISODIC.md) need review.

## Prerequisites

- msocket library installed on the imaging PC
- ScanImage ROI Integration enabled with ROIs defined
- Scope PC must be running the experiment (Sequencer calls `armStreaming` which
  listens on port 3044 before the imaging PC connects)

## Troubleshooting

**"Connection refused" on imaging PC** — the scope PC is not yet listening.
Start the experiment on the scope PC first, which opens port 3044 before SIStreamSetup connects.

**Frames not appearing on scope PC** — verify ROI Integration is enabled in ScanImage
and that `hSI.hIntegrationRoiManager` is populated. Run SIStreamSetup after defining ROIs.

**%VERIFY items** — the ScanImage property names in `si_frame_callback.m` and
`SIStreamSetup.m` were confirmed against the installed **SI2019bR0** source on
2026-08-05 (citations inline in each file). Re-check with
`probe_scanimage_config` after any ScanImage upgrade.
