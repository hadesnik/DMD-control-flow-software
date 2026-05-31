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

% Registering a user function requires ScanImage to be idle. Fail fast (before
% opening the socket) so the order is always: SIStreamSetup, THEN start Focus.
if isprop(hSI, 'acqState') && ~strcmpi(hSI.acqState, 'idle')
    error('SIStreamSetup:acquiring', ...
        ['ScanImage is acquiring (%s). Registering the frame callback requires idle.\n' ...
         'Stop Focus/Grab, run SIStreamSetup, THEN start Focus.'], hSI.acqState);
end

disp('Connecting to scope PC for F streaming...');
disp('Make sure scope PC experiment has started (armStreaming opens port 3044).');

SIStreamSocket = msconnect(scopePcIp, streamPort); %#ok<NASGU>

mssend(SIStreamSocket, 'F_STREAM_READY');
disp(['Connected to ' scopePcIp ':' num2str(streamPort) '.']);

% Register si_frame_callback as a ScanImage frameAcquired user function.
% ScanImage stores these in hSI.hUserFunctions.userFunctionsCfg.
%
% Field order MUST match ScanImage's record layout (EventName, UserFcnName,
% Arguments, Enable) — confirmed against SI2018b guis/userFunctionControlsV4.m.
% In R2018b, assigning a differently-ordered struct into a non-empty struct
% array errors with "dissimilar structures".
% 'frameAcquired' is a valid user-function event (SI.m notifies it).
% CONFIRMED (SI2018b source, SI.m ~L1178): frameAcquired fires per FRAME
% (per z-slice on stripeData.endOfFrame), NOT per volume. On a single-plane
% scan frame == volume, so the callback gets one fresh integration value per
% frame — correct, and what the 3044 dry-run validated. Multi-plane stacks are
% NOT supported here: the callback would fire once per slice while integration
% values only finalize per volume (duplicate sends + non-contiguous frame
% indices). Add dedupe-by-frame + volume indexing before streaming multi-plane.
% Idempotent: drop any prior si_frame_callback entries first, so re-running
% this script does not stack duplicate callbacks (each copy fires per frame
% and sends a redundant packet — observed as ~Nx duplicates in the stream).
existing = hSI.hUserFunctions.userFunctionsCfg;
if ~isempty(existing)
    keep = ~strcmp({existing.UserFcnName}, 'si_frame_callback');
    hSI.hUserFunctions.userFunctionsCfg = existing(keep);
end

newEntry.EventName    = 'frameAcquired';
newEntry.UserFcnName  = 'si_frame_callback';
newEntry.Arguments    = {};
newEntry.Enable       = true;

hSI.hUserFunctions.userFunctionsCfg(end+1) = newEntry;

disp('Frame callback registered. Ready for experiment.');
disp('Run SIStreamTeardown at end of session.');
