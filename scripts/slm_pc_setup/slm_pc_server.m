function slm_pc_server()
%slm_pc_server  Run the 3D-SHOT SLM hologram server on the SLM PC.
%
%   slm_pc_server() is the entry point for the SLM PC. It:
%     1. Loads configuration from slm_pc_config() (+ optional local override).
%     2. Builds the CGH context: params, calibration, efficiency map.
%     3. Instantiates the SLM hardware backend (mock or Meadowlark1024).
%     4. Listens on cfg.slmPort for a single client connection.
%     5. Sends a 'hello' handshake so the client (RemoteSLM) knows the server
%        is ready and can verify the SLM dimensions.
%     6. Dispatches incoming command structs via tfp.io.slmDispatch until
%        a 'shutdown' command is received or the connection drops.
%
%   Protocol (msocket, explicit-handle form — no msdisconnect):
%     Client sends:  struct('op', opName, 'payload', data)
%     Server sends:  reply struct (see tfp.io.slmDispatch for per-op shapes)
%     Shutdown:      client sends op='shutdown'; server sends reply, then exits.
%
%   %VERIFY (flat-struct round-trip):
%     This msocket build may not reliably round-trip nested MATLAB structs.
%     If slmDispatch replies arrive at RemoteSLM as plain doubles (the symptom
%     seen on the 3045 ROI path), fall back to sending the reply fields in a
%     known flat layout: struct with scalar/vector fields only, no nesting.
%     The 'projectTargets' reply is already flat (ok, nAccepted,
%     perCellDeliveredFraction, etaEffective) so no change is needed there.
%     For safety, keep all op reply structs flat in slmDispatch.
%
%   Usage (on the SLM PC, in MATLAB Command Window):
%     slm_pc_server      % runs indefinitely until shutdown or Ctrl-C
%
%   See also slm_pc_config, tfp.io.slmDispatch, tfp.hardware.RemoteSLM.

% =========================================================================
% 0. Load configuration
% =========================================================================

cfg = slm_pc_config();

fprintf('[slm_pc_server] Starting SLM PC server...\n');
fprintf('  backend       : %s\n', cfg.backend);
fprintf('  port          : %d\n', cfg.slmPort);
fprintf('  calib file    : %s\n', cfg.slmScanCalib_file);
fprintf('  effMap file   : %s\n', cfg.efficiencyMap_file);
fprintf('  dims          : [%d %d]  (nCols x nRows)\n', ...
    cfg.slmConfig.dims(1), cfg.slmConfig.dims(2));

% =========================================================================
% 1. Build CGH context  (params, calib, effMap)
% =========================================================================

% Build params from slmConfig, then merge in the three target-validation
% fields so that tfp.util.validateSLMTargets (called inside slmDispatch)
% can read them directly from ctx.params.
params = tfp.patterns.threeDShot.defaultParams(cfg.slmConfig);
params.maxCells             = cfg.slmConfig.maxCells;
params.addressableRadiusUm  = cfg.slmConfig.addressableRadiusUm;
params.minSpacingUm         = cfg.slmConfig.minSpacingUm;

calib  = tfp.patterns.threeDShot.loadSLMScanCalibration(cfg.slmScanCalib_file);
effMap = tfp.patterns.threeDShot.loadEfficiencyMap(cfg.efficiencyMap_file);

ctx = struct('params', params, 'calib', calib, 'effMap', effMap);

fprintf('[slm_pc_server] CGH context built (calib type: %s, effMap type: %s).\n', ...
    calib.type, effMap.type);

% =========================================================================
% 2. Instantiate SLM hardware
% =========================================================================

switch lower(cfg.backend)
    case 'mock'
        slm = tfp.hardware.MockSLM();
        slm.initialize(cfg.slmConfig);
        fprintf('[slm_pc_server] MockSLM initialized (%d x %d).\n', ...
            slm.nCols, slm.nRows);
    case 'meadowlark'
        slm = tfp.hardware.Meadowlark1024_SLM(cfg.slmConfig);
        fprintf('[slm_pc_server] Meadowlark1024_SLM initialized (%d x %d).\n', ...
            slm.nCols, slm.nRows);
    otherwise
        error('slm_pc_server:unknownBackend', ...
            'Unknown backend ''%s''. Use ''mock'' or ''meadowlark''.', cfg.backend);
end

% Register cleanup so the SLM is blanked and powered off if the script is
% interrupted (Ctrl-C) or errors out.
cleanupObj = onCleanup(@() serverCleanup(slm));

% =========================================================================
% 3. Outer loop — accept one client connection per iteration
%    (restart after a clean shutdown to allow re-use without restarting MATLAB)
% =========================================================================

acceptTimeoutS = 120;   % seconds to wait for a client to connect
pollTimeoutS   = 0.2;   % seconds per msrecv poll cycle

while true
    fprintf('[slm_pc_server] Listening on port %d (timeout %d s)...\n', ...
        cfg.slmPort, acceptTimeoutS);

    srvsock = [];
    sock    = [];
    try
        srvsock = mslisten(cfg.slmPort);
        sock    = msaccept(srvsock, acceptTimeoutS);
        msclose(srvsock);
        srvsock = [];
        fprintf('[slm_pc_server] Client connected.\n');
    catch ME
        if ~isempty(srvsock)
            try, msclose(srvsock); catch, end %#ok<TRYNC>
        end
        fprintf('[slm_pc_server] Accept timed out or failed: %s\n', ME.message);
        fprintf('[slm_pc_server] Retrying...\n');
        continue
    end

    % -----------------------------------------------------------------
    % 4. Send 'hello' handshake so RemoteSLM knows server is alive and
    %    can verify the SLM dimensions before submitting targets.
    % -----------------------------------------------------------------
    helloMsg = struct('op', 'hello', 'ok', true, ...
        'dims', [slm.nCols, slm.nRows]);
    try
        mssend(sock, helloMsg);
    catch ME
        fprintf('[slm_pc_server] Failed to send hello: %s. Closing connection.\n', ...
            ME.message);
        try, msclose(sock); catch, end %#ok<TRYNC>
        continue
    end

    % -----------------------------------------------------------------
    % 5. Inner dispatch loop — one command per iteration
    % -----------------------------------------------------------------
    shutdownRequested = false;
    tLastCmd = tic;
    idleTimeoutS = 3600;   % 1 h; protects against silent client drop

    while ~shutdownRequested
        % Poll with a short timeout so we never block MATLAB indefinitely.
        cmd = [];
        try
            cmd = msrecv(sock, pollTimeoutS);
        catch ME
            fprintf('[slm_pc_server] msrecv error (connection may have dropped): %s\n', ...
                ME.message);
            break
        end

        if isempty(cmd)
            % No data yet — check for idle timeout.
            if toc(tLastCmd) > idleTimeoutS
                fprintf('[slm_pc_server] Idle timeout (%.0f s). Closing connection.\n', ...
                    idleTimeoutS);
                break
            end
            continue
        end

        tLastCmd = tic;

        % Validate the command shape before dispatching.
        if ~isstruct(cmd) || ~isfield(cmd, 'op')
            fprintf('[slm_pc_server] Malformed command (no .op field). Ignoring.\n');
            badReply = struct('op', 'unknown', 'ok', false, ...
                'error', 'malformed command: missing .op');
            try, mssend(sock, badReply); catch, end %#ok<TRYNC>
            continue
        end

        % Normalise missing payload to empty.
        if ~isfield(cmd, 'payload')
            cmd.payload = [];
        end

        fprintf('[slm_pc_server] op=''%s''\n', cmd.op);

        % Dispatch through the shared controller.
        reply = tfp.io.slmDispatch(slm, ctx, cmd.op, cmd.payload);

        % Send reply.
        try
            mssend(sock, reply);
        catch ME
            fprintf('[slm_pc_server] mssend failed: %s. Closing connection.\n', ...
                ME.message);
            break
        end

        % Check if the dispatched op was a shutdown.
        if isfield(reply, 'shutdown') && reply.shutdown
            fprintf('[slm_pc_server] Shutdown command received. Exiting server.\n');
            shutdownRequested = true;
        end
    end

    % Close the data socket cleanly.
    try, msclose(sock); catch, end %#ok<TRYNC>

    if shutdownRequested
        break
    end

    fprintf('[slm_pc_server] Connection closed. Waiting for next client...\n');
end

fprintf('[slm_pc_server] Server exited.\n');
end   % slm_pc_server

% =========================================================================
% Local helpers
% =========================================================================

function serverCleanup(slm)
%serverCleanup  Best-effort blank + power-off + cleanup on exit or Ctrl-C.
try
    slm.blank();
catch
end
try
    slm.slmPower(false);
catch
end
try
    slm.cleanup();
catch
end
end   % serverCleanup
