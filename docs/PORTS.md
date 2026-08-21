# msocket port map (single source of truth)

Every network link in the system, in one place. All links use the lab msocket
library (explicit handles: `mslisten`/`msaccept`/`msconnect`/`mssend`/`msrecv`/
`msclose`; structs only round-trip reliably when FLAT — prefer bare numeric
matrices or char).

| Port | Server (listens)   | Client (connects) | Payload | Code |
|------|--------------------|-------------------|---------|------|
| 3043 | **DAQ PC**         | imaging PC        | stim-metadata control channel (flat structs) | `ScanImageBridge` (msocket mode), `SImsocketPrep.m` |
| 3044 | **DAQ PC**         | imaging PC        | live per-frame F stream | `ScanImageBridge.armStreaming`, `si_frame_callback.m` |
| 3045 | **DAQ PC**         | imaging PC        | ROI centroids, bare Nx2 `[x y]` or Nx4 `[x y planeIdx zUm]` (3D) | `tfp.io.receiveROIsFromScanImage`, `si_send_rois.m` |
| 3046 | **SLM PC** ⚠      | DAQ PC            | mask SPEC (flat struct) + `'ADV'`/`'STATUS'`/`'BLANK'`/`'BYE'`/`'SHUTDOWN'`; replies `'READY'`/`'ADV_OK'`/... | `slm_server.m`, `tfp.hardware.MeadowlarkSLM` |
| 3047 | **imaging PC** ⚠  | DAQ PC            | z-motor commands, bare `[opcode arg]`; replies `[status (value)]` | `si_motor_helper.m`, `tfp.hardware.RelayZStage` |
| 3048 | **imaging PC** ⚠  | DAQ PC            | calibration control of ScanImage, bare `[opcode args...]`; replies `[status values...]` | `si_calib_helper.m`, `tfp.hardware.ScanImageCalibBridge` |

⚠ **Direction reversals**: 3046, 3047 and 3048 are the links where the DAQ PC
is the *client*. The SLM PC and the imaging-PC helpers must run their server
loops unattended (`slm_server`, `si_motor_helper`, `si_calib_helper`) before the
DAQ PC starts an experiment or calibration.

**Run one imaging-PC helper, not both.** A MATLAB can hold only one blocking
accept loop, so `si_motor_helper` and `si_calib_helper` cannot coexist in the
ScanImage process — and BRINGUP_GUIDE §6b needs the z ruler and per-plane
brightness in the *same* measurement loop. `si_calib_helper` is therefore a
**superset**: opcodes 1/2/3 are byte-identical to `si_motor_helper`'s, so
`RelayZStage` works against it unchanged once you set

```yaml
zstage:
  relay_port: 3048
```

Run `si_motor_helper` when the z ruler is all you need; run `si_calib_helper`
for the guided bringup. Whichever is running, the app's Preflight tab names the
one that is not answering.

Historical note: `configs/real.yaml` once said `frameStreamPort: 3043  # same
socket as control`, contradicting the bridge's 3044 constant — fixed to 3044
when this file was created. If a port must change, change it here first, then
in the configs and both endpoint scripts.
