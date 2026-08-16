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

⚠ **Direction reversals**: 3046 and 3047 are the only links where the DAQ PC
is the *client*. The SLM PC and the imaging-PC helper must run their server
loops unattended (`slm_server`, `si_motor_helper`) before the DAQ PC starts an
experiment or calibration.

Historical note: `configs/real.yaml` once said `frameStreamPort: 3043  # same
socket as control`, contradicting the bridge's 3044 constant — fixed to 3044
when this file was created. If a port must change, change it here first, then
in the configs and both endpoint scripts.
