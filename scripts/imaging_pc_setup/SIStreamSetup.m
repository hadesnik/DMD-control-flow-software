% SIStreamSetup  Connect to scope PC and register the frame-streaming callback.
%
% Run this ONCE at the start of each session on the imaging PC,
% BEFORE running the experiment on the scope PC.
%
% What it does:
%   1. Adds msocket to the MATLAB path (edit the addpath line below).
%   2. Connects to the scope PC on port 3044 (the scope PC's Sequencer opens
%      this port via armStreaming before the first trial).
%   3. Sends 'F_STREAM_READY' handshake so the scope PC knows streaming is live.
%   4. Registers si_frame_callback as a ScanImage frameAcquired user function.
%
% Port 3044 is the F-streaming channel (separate from the control channel on 3043).
%
% Prerequisites:
%   - msocket library installed on this PC
%   - ScanImage is open and ROI Integration is enabled with ROIs defined
%   - The scope PC experiment must be started first (it listens on 3044)
%
% See scripts/imaging_pc_setup/README.md for full session workflow.

global SIStreamSocket %#ok<GVMIS>

% Machine-local settings (msocket path, scope-PC IP, ports).
% Edit imaging_pc_config.m / imaging_pc_config_local.m, not this script.
cfg        = imaging_pc_config();
scopePcIp  = cfg.scopePcIp;
streamPort = cfg.streamPort;

disp('Connecting to scope PC for F streaming...');
disp('Make sure scope PC experiment has started (armStreaming opens port 3044).');

SIStreamSocket = msconnect(scopePcIp, streamPort); %#ok<NASGU>

mssend(SIStreamSocket, 'F_STREAM_READY');
disp(['Connected to ' scopePcIp ':' num2str(streamPort) '.']);

% Register si_frame_callback as a ScanImage frameAcquired user function.
% ScanImage stores these in hSI.hUserFunctions.userFunctionsCfg.
%
% %VERIFY: confirm with Masato that frameAcquired fires once per frame
%   (not once per volume) on this ScanImage version.
%   ScanImage 2020+ uses 'frameAcquired'; earlier versions may differ.
newEntry.Enable       = true;
newEntry.EventName    = 'frameAcquired';
newEntry.UserFcnName  = 'si_frame_callback';
newEntry.Arguments    = {};

hSI.hUserFunctions.userFunctionsCfg(end+1) = newEntry;

disp('Frame callback registered. Ready for experiment.');
disp('Run SIStreamTeardown at end of session.');
