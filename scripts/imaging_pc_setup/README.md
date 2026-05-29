# Imaging PC Setup Scripts

These scripts run on the **IMAGING PC** (128.32.177.205), not the scope PC.
Copy this entire folder to the imaging PC before running experiments.

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

```matlab
SIStreamTeardown
```

This closes the socket and disables the frame callback cleanly.

## Files

| File | Purpose |
|------|---------|
| `imaging_pc_config.m` | Central settings (msocket path, scope-PC IP, ports); adds msocket to path |
| `imaging_pc_config_local.m.example` | Template for per-machine overrides (copy to `imaging_pc_config_local.m`) |
| `SIStreamSetup.m` | Run once per session to connect and register the callback |
| `si_frame_callback.m` | ScanImage `frameAcquired` callback — do not call directly |
| `si_send_rois.m` | Send ROI centroids to the scope PC after drawing ROIs |
| `SIStreamTeardown.m` | Run at end of session to disconnect cleanly |

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

**%VERIFY items** — several ScanImage property names in `si_frame_callback.m` must
be confirmed with Masato against the installed ScanImage version before first use.
