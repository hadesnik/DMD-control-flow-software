function test_fstream_recv()
%test_fstream_recv  Scope-PC side of the port-3044 F-stream dry-run.
%
% Self-contained (no tfp package required): mirrors
% tfp.hardware.ScanImageBridge.armStreaming + receiveLiveFrame so the live
% F-streaming path can be validated end-to-end against the imaging PC running
% SIStreamSetup + a ScanImage Focus — without launching a full experiment.
%
% PROCEDURE:
%   1. SCOPE PC (this machine, marta-ephy): run  test_fstream_recv
%        -> listens on 3044, waits for the imaging PC to connect.
%   2. IMAGING PC: run  SIStreamSetup   (connects, sends 'F_STREAM_READY',
%        registers the frameAcquired callback), then start a ScanImage FOCUS
%        with ROI Integration enabled and a few integration ROIs drawn.
%   3. Let it run a few seconds, then stop Focus. Run SIStreamTeardown on the
%        imaging PC. This script prints a summary when the stream ends or the
%        RUN_SECONDS window elapses.
%
% What it validates:
%   - the 3044 socket + 'F_STREAM_READY' handshake
%   - si_frame_callback actually mssends per-frame packets during Focus
%   - packet fields (frame, F, frameTimestamp) and ROI count
%   - the absolute->relative frame mapping yields a contiguous 1..N index
%     (this is the logic just added to ScanImageBridge.receiveLiveFrame)

%FILL if different: msocket path on the scope PC (matches SImsocketPrep.m)
addpath(genpath('C:\Users\adesniklab\Documents\MATLAB\msocket'));

STREAM_PORT = 3044;
RUN_SECONDS = 30;     % how long to keep listening for frames after connect

fprintf('\n[fstream] === scope-PC F-stream dry-run (port %d) ===\n', STREAM_PORT);
fprintf('[fstream] Listening... run SIStreamSetup on the imaging PC now.\n');

srvsock = mslisten(STREAM_PORT);
sock = [];
cleanupObj = onCleanup(@() localClose(sock, srvsock)); %#ok<NASGU>
try
    sock = msaccept(srvsock, 60);
catch ME
    error('test_fstream_recv:noConnect', ...
        'Imaging PC did not connect within 60 s on port %d.\n%s', ...
        STREAM_PORT, ME.message);
end
msclose(srvsock); srvsock = [];
fprintf('[fstream] %s  Imaging PC connected.\n', datestr(now,'HH:MM:SS.FFF'));

hs = msrecv(sock);
fprintf('[fstream] Handshake: %s', mat2str(hs));
if ischar(hs) && strcmp(strtrim(hs),'F_STREAM_READY')
    fprintf('  => OK\n');
else
    fprintf('  => WARNING: expected ''F_STREAM_READY''\n');
end
fprintf('[fstream] Start a ScanImage Focus on the imaging PC. Collecting %d s...\n', RUN_SECONDS);

firstFrame = [];
liveF      = [];
absFrames  = [];
nRecv      = 0;
t0 = tic;
while toc(t0) < RUN_SECONDS
    pkt = msrecv(sock, 0.1);      % 2-arg form: [] on timeout
    if isempty(pkt)
        continue;
    end
    if ischar(pkt) && strcmp(strtrim(pkt), 'F_STREAM_DONE')
        fprintf('[fstream] Received F_STREAM_DONE — stream closed by imaging PC.\n');
        break;
    end
    if ~isstruct(pkt) || ~isfield(pkt,'frame') || ~isfield(pkt,'F')
        fprintf('[fstream] (ignored non-frame message: %s)\n', class(pkt));
        continue;
    end

    nRecv = nRecv + 1;
    if isempty(firstFrame)
        firstFrame = pkt.frame;            % anchor — same logic as receiveLiveFrame
    end
    idx    = pkt.frame - firstFrame + 1;   % absolute -> 1-based relative index
    nCells = numel(pkt.F);
    if isempty(liveF)
        liveF = nan(nCells, 2000);
    end
    if idx >= 1 && idx <= size(liveF,2)
        liveF(1:nCells, idx) = pkt.F(:);
        absFrames(idx) = pkt.frame; %#ok<AGROW>
    end

    if nRecv <= 5 || mod(nRecv,25) == 0
        tsStr = '';
        if isfield(pkt,'frameTimestamp'), tsStr = sprintf(', tSI=%.3f', pkt.frameTimestamp); end
        fprintf('[fstream] pkt %3d: absFrame %d -> idx %d, %d ROIs, F(1)=%.3f%s\n', ...
            nRecv, pkt.frame, idx, nCells, pkt.F(1), tsStr);
    end
end
msclose(sock); sock = [];

% ---- Summary ----
fprintf('\n[fstream] ================ SUMMARY ================\n');
fprintf('  packets received     : %d\n', nRecv);
if nRecv > 0
    cols = find(any(~isnan(liveF),1));
    nGaps = (max(cols) - min(cols) + 1) - numel(cols);
    fprintf('  relative idx range   : %d .. %d\n', min(cols), max(cols));
    fprintf('  missing idx in range : %d  (0 = contiguous, no dropped frames)\n', nGaps);
    fprintf('  ROI count per frame  : %d\n', sum(any(~isnan(liveF),2)));
    df = diff(absFrames(absFrames~=0));
    fprintf('  abs-frame step       : min %d, max %d  (1 = no skipped frames)\n', ...
        min(df), max(df));
    fprintf('\n  PASS criteria: idx range starts at 1, 0 missing, ROI count = #ROIs drawn.\n');
else
    fprintf('  No frame packets received. Check: Focus running? ROI Integration on?\n');
    fprintf('  si_frame_callback registered (SIStreamSetup)? SIStreamSocket set?\n');
end
fprintf('[fstream] ==========================================\n\n');
end

% -------------------------------------------------------------------------
function localClose(sock, srvsock)
if ~isempty(sock),    try, msclose(sock);    catch, end, end %#ok<TRYNC>
if ~isempty(srvsock), try, msclose(srvsock); catch, end, end %#ok<TRYNC>
end
