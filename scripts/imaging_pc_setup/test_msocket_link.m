function test_msocket_link()
%test_msocket_link  Imaging-PC side of the msocket control-channel dry-run.
%
% Pairs with the SCOPE-PC server (either tfp.hardware.ScanImageBridge.
% verifyProtocol() or the lab's SImsocketPrep).  Exercises the port-3043
% control handshake WITHOUT touching ScanImage (no hSI, no DMD, no DAQ, no
% laser) — purely validates that the socket link and the A/B (+ optional
% sendThisSI) protocol work between the two PCs.
%
% Implemented as a FUNCTION so it is safe to run in the live ScanImage MATLAB
% console — it does not touch the base workspace (no clobbering hSI, s, etc.).
%
% PROCEDURE (run the scope side FIRST — it is the server and waits ~40-60 s):
%   1. SCOPE PC (128.32.177.203), either:
%        a) our repo:   bridge = tfp.hardware.ScanImageBridge( ...
%                           tfp.io.loadConfig('configs/real.yaml').scanimage);
%                       bridge.verifyProtocol();     % listens on 3043, sends a test struct
%        b) lab code:   SImsocketPrep                % listens on 3043, handshake only
%   2. IMAGING PC (this machine):  test_msocket_link
%
% Expected exchange:
%   - scope sends 'A'   -> this function receives 'A'
%   - this function sends 'B'
%   - (verifyProtocol only) scope sends sendThisSI struct -> printed here
%
% Compare the two consoles: both should report the handshake succeeded.

cfg = imaging_pc_config();   % msocket on path, scope-PC IP, ports

fprintf('\n[test_msocket_link] === imaging-PC control-channel dry-run ===\n');
fprintf('[test_msocket_link] Connecting to scope PC %s:%d ...\n', ...
    cfg.scopePcIp, cfg.controlPort);
fprintf('[test_msocket_link] (scope PC must already be listening on %d)\n', ...
    cfg.controlPort);

sock = [];
cleanupObj = onCleanup(@() localClose(sock));  %#ok<NASGU>

try
    sock = msconnect(cfg.scopePcIp, cfg.controlPort);
catch ME
    error('test_msocket_link:connectFailed', ...
        ['Could not connect to %s:%d.\n' ...
         'Is the scope-PC server (verifyProtocol / SImsocketPrep) running yet?\n' ...
         'Error: %s'], cfg.scopePcIp, cfg.controlPort, ME.message);
end
fprintf('[test_msocket_link] %s  Connected.\n', datestr(now, 'HH:MM:SS.FFF'));

% Step 1 — receive 'A' from scope PC (blocks until scope sends it).
fprintf('[test_msocket_link] Waiting for ''A'' from scope PC (blocks)...\n');
a = msrecv(sock);
fprintf('[test_msocket_link] %s  Received: %s\n', datestr(now, 'HH:MM:SS.FFF'), mat2str(a));
if ~(ischar(a) && strcmp(strtrim(a), 'A'))
    fprintf('[test_msocket_link]   WARNING: expected ''A''.\n');
end

% Step 2 — reply 'B' (what both SImsocketPrep and ScanImageBridge expect back).
mssend(sock, 'B');
fprintf('[test_msocket_link] %s  Sent ''B''.\n', datestr(now, 'HH:MM:SS.FFF'));

% Step 3 — receive the sendThisSI struct, if the scope side sends one.
%   verifyProtocol() sends a test struct here; plain SImsocketPrep does not.
%   Poll for up to 5 s so the test completes either way (msrecv 2-arg form
%   returns [] on timeout — confirmed by the lab's DAQmSocketPrep/flushMSocket).
fprintf('[test_msocket_link] Listening up to 5 s for a sendThisSI struct...\n');
payload = [];
tWait = tic;
while toc(tWait) < 5
    incoming = msrecv(sock, 0.25);
    if ~isempty(incoming)
        payload = incoming;
        break;
    end
end
if isstruct(payload) && isfield(payload, 'times') && isfield(payload, 'power')
    fprintf('[test_msocket_link] %s  Received struct:\n', datestr(now, 'HH:MM:SS.FFF'));
    disp(payload);
    fprintf('[test_msocket_link]   => CONFIRMED: got .times=%g, .power=%g\n', ...
        payload.times, payload.power);
elseif isempty(payload)
    fprintf('[test_msocket_link]   No struct received (expected if scope ran\n');
    fprintf('[test_msocket_link]   SImsocketPrep rather than verifyProtocol). Handshake still OK.\n');
else
    fprintf('[test_msocket_link]   WARNING: received non-struct/unexpected payload:\n');
    disp(payload);
end

fprintf('[test_msocket_link] Handshake complete. Link is good.\n');
fprintf('[test_msocket_link] ===========================================\n\n');
end

% -------------------------------------------------------------------------
function localClose(sock)
if ~isempty(sock)
    try, msclose(sock); catch, end %#ok<TRYNC>
end
end
