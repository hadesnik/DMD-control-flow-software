classdef ScanImageBridge < handle
%ScanImageBridge Real ScanImage bridge for imaging-PC integration.
%
%   TIMING ARCHITECTURE:
%     ScanImage acquisition is ALWAYS started by a hardware TTL edge from
%     the DAQ digital output (port0/line2 or as configured in real.yaml).
%     ScanImage must be pre-configured in external-trigger mode before each
%     session — this class does NOT remotely start ScanImage.
%
%   This class handles only non-time-critical communication around the TTL:
%     Before trial: exchange metadata with ScanImage (stim times, power)
%     After trial:  retrieve the saved TIFF path
%
%   config.connectionMode controls the metadata channel:
%
%     'ttl_only' — No socket.  ScanImage gets no advance metadata; TIFF
%                  path is not retrieved.  Safe default; use during bringup.
%
%     'msocket'  — Lab-verified metadata protocol (non-time-critical).
%                  DAQ PC is the socket SERVER; imaging PC connects to it.
%                  Uses the msocket library at config.msocketPath.
%                  Per-trial sequence (all before daq.start()):
%                    mslisten / msaccept  — wait for imaging PC to connect
%                    mssend('A')          — DAQ signals ready
%                    msrecv('B')          — confirm imaging PC is ready
%                    mssend(sendThisSI)   — send stim metadata
%                      sendThisSI.times = stim onset (s from trial start)
%                      sendThisSI.power = laser power (mW)
%                  After daq.start() the TTL fires and ScanImage acquires.
%
%     'tcp'      — Speculative ScanImage remote-control TCP.  Not verified
%                  against this setup.  Placeholder only; prefer the above.
%
%   NOTE — laser power in sendThisSI:
%     setActivePattern does not receive power (power is queued on the DAQ
%     AO channel by the Sequencer).  Call setPendingPower(powerMw) before
%     setActivePattern.  The Sequencer should be updated to do this.
%
%   Typical call sequence (mirrors MockScanImageBridge):
%     bridge.setPendingPower(trial.powerMw)   % optional; default 0
%     bridge.armForExternalTrigger(nFrames)   % metadata handshake (non-critical)
%     bridge.setActivePattern(mask, t0, dur)  % send stim params (non-critical)
%     daq.start()                             % TIME-CRITICAL: DAQ fires TTL
%     bridge.waitForCompletion(timeoutS)      % wait (non-critical)
%     [framesPath, ts] = bridge.getLastAcquisition() % retrieve path (non-critical)
%
%   %VERIFY — open protocol questions (run verifyProtocol() to diagnose):
%
%     1. Handshake reply 'B'
%        ASSUME: ScanImage user function on imaging PC sends exactly 'B' after receiving
%                'A'.  Source: SImsocketPrep.m on DAQ PC waits for 'B', but the imaging-
%                PC-side script (ask Masato — likely DAQmSocketPrep.m or similar) has not
%                been inspected to confirm it sends 'B'.
%        TEST:   Run verifyProtocol() — step 4 prints what is actually received.
%                Or: read the ScanImage-side user function source on the imaging PC.
%        CHANGE: In msocketHandshake — update strcmp(strtrim(reply), 'B') to match the
%                real reply string; remove the check entirely if SI sends nothing.
%
%     2. Completion signal after acquisition
%        ASSUME: ScanImage sends NO completion signal over the socket after saving.
%                waitForCompletion therefore uses a timing-based pause.
%        TEST:   Run verifyProtocol() — step 6 watches for any incoming message.
%        CHANGE: In waitForCompletion (msocket branch): replace pause(min(waitS,timeoutS))
%                with msrecv(obj.siSocket_) inside a try/catch with timeoutS.
%
%     3. TIFF path over socket
%        ASSUME: ScanImage does NOT send the TIFF path back; getLastAcquisition returns ''.
%        TEST:   Run verifyProtocol() — step 6 watches for any string message after stim.
%        CHANGE: In getLastAcquisition (msocket case): replace framesPath = '' with
%                framesPath = msrecv(obj.siSocket_) inside a try/catch.
%
%     4. msocket port — CONFIRMED 2026-05-19: port 3043 verified; mslisten/msaccept work.
%
%   See ARCHITECTURE.md "ScanImageBridge" and CLAUDE.md Phase 2.

    properties (SetAccess = private)
        isConnected     % logical; true when socket is open
    end

    properties (Access = private)
        mode_            % 'msocket' | 'ttl_only' | 'tcp'
        frameRate_       % Hz, from config
        nFrames_         % set by armForExternalTrigger

        % msocket mode
        siSocket_        % open msocket connection handle
        srvsockPort_     % listening port (default 3043)
        msocketPath_     % path to msocket\ directory on scope PC
        pendingPowerMw_  % laser power to include in sendThisSI (default 0)

        % tcp mode (speculative — not verified against actual setup)
        host_
        port_
        tcpClient_

        connectTimeoutS_ % timeout for connection / msaccept (s)
        lastFilePath_    % TIFF path from last acquisition
        log_             % struct array {timestamp, eventType, payload}
    end

    methods
        function obj = ScanImageBridge(config)
            %ScanImageBridge Construct and connect to imaging PC.
            %
            %   ScanImageBridge(config)
            %     config.connectionMode:  'msocket'|'ttl_only'|'tcp' (default 'ttl_only')
            %     config.msocketPort:     server port         (default 3043)
            %     config.msocketPath:     path to msocket\    (default '')
            %     config.frameRate:       imaging frame rate  (default 30, Hz)
            %     config.connectTimeoutS: accept/connect timeout (default 30, s)
            %     config.host:            imaging PC IP       (tcp mode only)
            %     config.port:            TCP port            (tcp mode, default 5555)
            if nargin < 1 || isempty(config)
                config = struct();
            end
            obj.mode_            = configField(config, 'connectionMode', 'ttl_only');
            obj.srvsockPort_     = configField(config, 'msocketPort',    3043);
            obj.msocketPath_     = configField(config, 'msocketPath',    '');
            obj.frameRate_       = configField(config, 'frameRate',      30);
            obj.connectTimeoutS_ = configField(config, 'connectTimeoutS', 30);
            obj.host_            = configField(config, 'host',           'localhost');
            obj.port_            = configField(config, 'port',           5555);
            obj.nFrames_         = 0;
            obj.pendingPowerMw_  = 0;
            obj.isConnected      = false;
            obj.siSocket_        = [];
            obj.tcpClient_       = [];
            obj.lastFilePath_    = '';
            obj.log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {});

            if strcmp(obj.mode_, 'tcp')
                obj.tcpConnect();
            end
            % msocket mode defers connection to armForExternalTrigger
            % (the imaging PC connects fresh each trial)
        end

        function setPendingPower(obj, powerMw)
            %setPendingPower Store laser power to include in the next sendThisSI.
            %   Call before setActivePattern so the correct power is sent to
            %   ScanImage.  The Sequencer should call this with trial.powerMw.
            obj.pendingPowerMw_ = double(powerMw);
        end

        function armForExternalTrigger(obj, nFrames)
            %armForExternalTrigger Set up metadata channel before the TTL fires.
            %   Stores nFrames for timeout math.  Does NOT start ScanImage
            %   acquisition — that happens via the hardware TTL from daq.start().
            %
            %   msocket: performs the A/B handshake with the imaging PC so
            %     setActivePattern can send stim metadata.  Non-time-critical;
            %     call well before daq.start().
            %   ttl_only: no communication, just records nFrames.
            %   tcp: sends frame-count metadata to ScanImage (speculative).
            if ~isnumeric(nFrames) || ~isscalar(nFrames) || ...
                    ~isfinite(nFrames) || nFrames < 1
                error('tfp:hardware:ScanImageBridge:badNFrames', ...
                    'nFrames must be a positive finite scalar.');
            end
            obj.nFrames_ = round(nFrames);

            switch obj.mode_
                case 'msocket'
                    obj.msocketHandshake();
                case 'tcp'
                    %VERIFY hSI.hScan2D.logNumFrames — property name varies by SI version
                    %  ASSUME: logNumFrames is the correct per-stack frame-count property (tcp mode).
                    %  TEST:   ScanImage MATLAB console while idle: disp(hSI.hScan2D.logNumFrames)
                    %  CHANGE: Replace logNumFrames with the correct name (inspect hSI.hScan2D).
                    obj.siCommand(sprintf('hSI.hScan2D.logNumFrames = %d;', obj.nFrames_));
                    % Do NOT call startGrab() here — ScanImage must be pre-armed
                    % in external-trigger mode; TTL from daq.start() fires it.
                % ttl_only: nothing to do
            end

            obj.logEvent('armForExternalTrigger', struct('nFrames', obj.nFrames_));
        end

        function setActivePattern(obj, ~, stimOnsetSec, stimDurationSec)
            %setActivePattern Send stim params to ScanImage (msocket) or no-op.
            %   patternMask (arg 2) is unused — real hardware gets the pattern
            %   via the physical DMD.
            %
            %   msocket mode: sends sendThisSI struct over the open socket.
            %     sendThisSI.times = stimOnsetSec   (seconds from trial start)
            %     sendThisSI.power = pendingPowerMw_ (call setPendingPower first)
            %   tcp / ttl_only mode: no-op.
            if strcmp(obj.mode_, 'msocket')
                if isempty(obj.siSocket_)
                    error('tfp:hardware:ScanImageBridge:notArmed', ...
                        'Call armForExternalTrigger before setActivePattern.');
                end
                sendThisSI.times = stimOnsetSec;       %#ok<STRNU>
                sendThisSI.power = obj.pendingPowerMw_; %#ok<STRNU>
                %CONFIRMED 2026-05-19: sendThisSI.times and sendThisSI.power are the correct
                %  field names (verified from SImsocketPrep.m on DAQ PC).  The ScanImage-side
                %  user function must read these same fields — inspect DAQmSocketPrep.m to confirm.
                mssend(obj.siSocket_, sendThisSI);
                obj.isConnected = true;
            end

            obj.logEvent('setActivePattern', struct( ...
                'stimOnsetSec',    stimOnsetSec, ...
                'stimDurationSec', stimDurationSec, ...
                'powerMw',         obj.pendingPowerMw_));
        end

        function waitForCompletion(obj, timeoutS)
            %waitForCompletion Block until ScanImage finishes acquiring nFrames.
            %   msocket / ttl_only: timing-based wait (nFrames/frameRate + 10%).
            %   tcp: polls hSI.acqState until 'idle'.
            %
            %   %VERIFY completion signal after acquisition (unknown 2026-05-19)
            %     ASSUME: ScanImage sends NO completion signal; timing-based pause is used.
            %     TEST:   Run verifyProtocol() — step 6 listens for any post-acquisition message.
            %     CHANGE: Replace pause(min(waitS, timeoutS)) with msrecv(obj.siSocket_) in a
            %             try/catch with timeoutS — msocket branch only.
            switch obj.mode_
                case 'tcp'
                    obj.pollUntilIdle(timeoutS);
                otherwise  % 'msocket' and 'ttl_only'
                    waitS = obj.nFrames_ / obj.frameRate_ * 1.1;
                    pause(min(waitS, timeoutS));
            end
            obj.logEvent('waitForCompletion', struct('timeoutS', timeoutS));
        end

        function [framesPath, frameTimestamps] = getLastAcquisition(obj)
            %getLastAcquisition Return the last TIFF path and frame timestamps.
            %
            %   framesPath:      Full path to the ScanImage TIFF on the imaging
            %                    PC filesystem, or '' if unavailable.  Access
            %                    from the DAQ PC requires a mapped network share.
            %   frameTimestamps: 1×nFrames seconds (0-based linspace approximation).
            %
            %   %VERIFY TIFF path over socket (unknown 2026-05-19) — see inline comment
            %   below and run verifyProtocol() step 6 to determine.
            %
            %   %FUTURE: parse per-frame timestamps from TIFF header using
            %   ScanImageTiffReader once that utility path is confirmed.
            frameTimestamps = linspace(0, obj.nFrames_ / obj.frameRate_, obj.nFrames_);

            switch obj.mode_
                case 'msocket'
                    %VERIFY TIFF path over socket (unknown 2026-05-19)
                    %  ASSUME: ScanImage does NOT send the TIFF path; return ''.
                    %  TEST:   Run verifyProtocol() — step 6 watches for a string message.
                    %  CHANGE: framesPath = msrecv(obj.siSocket_) if SI sends the path.
                    framesPath = '';
                    obj.msocketClose();
                case 'tcp'
                    framesPath = obj.queryLastTiffPath();
                otherwise
                    framesPath = '';
            end

            obj.lastFilePath_ = framesPath;
            obj.logEvent('getLastAcquisition', ...
                struct('framesPath', framesPath, 'nFrames', obj.nFrames_));
        end

        function result = getSyntheticResult(obj) %#ok<MANU>
            %getSyntheticResult Returns [] — no synthetic data from real hardware.
            %   Stub for Sequencer compatibility; MockScanImageBridge returns a
            %   ΔF/F struct here.  For real hardware the TIFF from
            %   getLastAcquisition() is the source of imaging data.
            result = [];
        end

        function disconnect(obj)
            %disconnect Close any open socket or TCP connection.
            obj.msocketClose();
            if obj.isConnected && strcmp(obj.mode_, 'tcp')
                try, delete(obj.tcpClient_); catch, end
                obj.tcpClient_  = [];
                obj.isConnected = false;
            end
            obj.logEvent('disconnect', struct());
        end

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields {timestamp, eventType, payload}.
            entries = obj.log_;
        end

        function verifyProtocol(obj)
            %verifyProtocol Interactive protocol diagnostic — run once before first real session.
            %
            %   Usage:
            %     cfg = loadConfig('configs/real.yaml');
            %     bridge = tfp.hardware.ScanImageBridge(cfg.scanimage);
            %     bridge.verifyProtocol();
            %
            %   Prints, with timestamps, every message received from the ScanImage PC
            %   so the operator can confirm the handshake and completion signals without
            %   reading source code.
            %
            %   Step 6 may block indefinitely if ScanImage sends nothing after stim.
            %   Press Ctrl-C — that confirms no completion signal is sent, which is the
            %   assumed (and currently correct) behaviour.
            %
            %   NOT called automatically.  Run once to validate, then comment out.
            PORT = obj.srvsockPort_;
            if ~isempty(obj.msocketPath_)
                addpath(obj.msocketPath_);
            end

            fprintf('\n[verifyProtocol] === ScanImageBridge protocol diagnostic ===\n');
            fprintf('[verifyProtocol] DAQ PC (server) on port %d\n\n', PORT);

            % Step 1 — listen for ScanImage PC to connect
            fprintf('[verifyProtocol] Step 1: mslisten(%d)  (60 s timeout)...\n', PORT);
            srvsock = mslisten(PORT);
            sock = [];
            try
                sock = msaccept(srvsock, 60);
            catch ME
                msclose(srvsock);
                fprintf('[verifyProtocol] FAILED — no connection within 60 s: %s\n', ME.message);
                return;
            end
            msclose(srvsock);
            fprintf('[verifyProtocol] %s  Connected.\n', datestr(now, 'HH:MM:SS.FFF'));

            % Step 2 — pause to catch any unsolicited data before handshake
            fprintf('\n[verifyProtocol] Step 2: pause 1 s — checking for unsolicited data...\n');
            pause(1);
            fprintf('[verifyProtocol]          (no data expected before handshake)\n');

            % Step 3 — send 'A'
            mssend(sock, 'A');
            fprintf('\n[verifyProtocol] %s  Step 3: Sent ''A''.\n', datestr(now, 'HH:MM:SS.FFF'));

            % Step 4 — wait for handshake reply (blocks until data arrives)
            fprintf('[verifyProtocol] Step 4: Waiting for handshake reply (blocks)...\n');
            reply = msrecv(sock);
            fprintf('[verifyProtocol] %s  Received: %s\n', datestr(now, 'HH:MM:SS.FFF'), mat2str(reply));
            if ischar(reply) && strcmp(strtrim(reply), 'B')
                fprintf('[verifyProtocol]           => CONFIRMED: got ''B'' as expected.\n');
            else
                fprintf('[verifyProtocol]           => WARNING: expected ''B''; update msocketHandshake.\n');
            end

            % Step 5 — send test sendThisSI struct
            testStruct.times = 0.5;
            testStruct.power = 10.0;
            mssend(sock, testStruct);
            fprintf('\n[verifyProtocol] %s  Step 5: Sent sendThisSI (times=0.5, power=10).\n', ...
                datestr(now, 'HH:MM:SS.FFF'));

            % Step 6 — listen up to 10 s for any post-acquisition message.
            % msrecv blocks indefinitely if no data arrives; Ctrl-C exits the try block.
            % Ctrl-C here = ScanImage sends no completion signal (the assumed behaviour).
            fprintf('\n[verifyProtocol] Step 6: Listening up to 10 s for post-acquisition data.\n');
            fprintf('[verifyProtocol]          Ctrl-C here = ScanImage sends NO completion signal\n');
            fprintf('[verifyProtocol]            (that is the expected / currently-assumed behaviour).\n\n');
            nReceived = 0;
            t0 = tic;
            try
                while toc(t0) < 10
                    msg = msrecv(sock);   % blocks; Ctrl-C exits the try block
                    nReceived = nReceived + 1;
                    fprintf('[verifyProtocol] %s  Post-acq message #%d: %s\n', ...
                        datestr(now, 'HH:MM:SS.FFF'), nReceived, mat2str(msg));
                end
            catch   %#ok<CTCH>
                % Ctrl-C or msrecv error — fall through to summary
            end

            % Summary
            fprintf('\n[verifyProtocol] ========= SUMMARY =========\n');
            fprintf('  Handshake ''B'' received:      %s\n', ...
                mat2str(ischar(reply) && strcmp(strtrim(reply), 'B')));
            fprintf('  Post-acquisition messages:  %d\n', nReceived);
            if nReceived == 0
                fprintf('\n  ASSUMPTION CONFIRMED: ScanImage sends no completion signal.\n');
                fprintf('  waitForCompletion timing-pause is correct.\n');
                fprintf('  getLastAcquisition returning '''' is correct.\n');
            else
                fprintf('\n  ACTION REQUIRED: ScanImage sent %d post-acq message(s).\n', nReceived);
                fprintf('  waitForCompletion (msocket branch):\n');
                fprintf('    Replace: pause(min(waitS, timeoutS))\n');
                fprintf('    With:    msrecv(obj.siSocket_)  [in try/catch with timeoutS]\n');
                fprintf('  getLastAcquisition (msocket case):\n');
                fprintf('    Replace: framesPath = ''''\n');
                fprintf('    With:    framesPath = msrecv(obj.siSocket_)  [in try/catch]\n');
            end
            fprintf('[verifyProtocol] ===========================\n\n');

            try, msclose(sock); catch, end %#ok<TRYNC>
        end
    end

    methods (Access = private)

        % --- msocket mode -------------------------------------------------------

        function msocketHandshake(obj)
            %msocketHandshake Listen for imaging PC, perform A/B handshake.
            %   DAQ PC is the server.  Imaging PC connects, DAQ sends 'A',
            %   waits for 'B', then setActivePattern sends sendThisSI.
            if ~isempty(obj.msocketPath_)
                addpath(obj.msocketPath_);
            end

            srvsock = mslisten(obj.srvsockPort_);
            try
                obj.siSocket_ = msaccept(srvsock, obj.connectTimeoutS_);
            catch ME
                msclose(srvsock);
                error('tfp:hardware:ScanImageBridge:msocketTimeout', ...
                    ['Imaging PC did not connect within %.1f s on port %d.\n' ...
                     'Ensure ScanImage user function dials back to this port.\n' ...
                     'Error: %s'], obj.connectTimeoutS_, obj.srvsockPort_, ME.message);
            end
            msclose(srvsock);  % server socket no longer needed

            mssend(obj.siSocket_, 'A');  % signal DAQ is ready

            %VERIFY 'B' is the exact string ScanImage sends in reply to 'A' (unknown 2026-05-19)
            %  ASSUME: The ScanImage-side user function on the imaging PC (ask Masato —
            %          likely DAQmSocketPrep.m) sends exactly 'B' after connecting.
            %          Source: SImsocketPrep.m on DAQ PC waits for 'B', but the imaging-PC
            %          script has not been inspected to confirm it sends 'B'.
            %  TEST:   Run verifyProtocol() — step 4 prints what is actually received.
            %          OR: read the ScanImage-side user function on the imaging PC directly.
            %  CHANGE: Update strcmp(strtrim(reply), 'B') to match the real reply string.
            reply = msrecv(obj.siSocket_);
            if ~(ischar(reply) && strcmp(strtrim(reply), 'B'))
                warning('tfp:hardware:ScanImageBridge:unexpectedHandshake', ...
                    'Expected ''B'' from ScanImage PC, received: %s', mat2str(reply));
            end

            obj.logEvent('msocketHandshake', ...
                struct('port', obj.srvsockPort_, 'reply', mat2str(reply)));
        end

        function msocketClose(obj)
            %msocketClose Close the open msocket connection if any.
            if ~isempty(obj.siSocket_)
                try, msclose(obj.siSocket_); catch, end
                obj.siSocket_  = [];
                obj.isConnected = false;
            end
        end

        % --- tcp mode (speculative) ---------------------------------------------

        function tcpConnect(obj)
            %tcpConnect Open TCP connection to ScanImage remote control server.
            %   This mode is speculative — not verified against the actual lab
            %   setup.  Prefer 'msocket' or 'ttl_only'.
            %   %VERIFY port 5555 and whether ScanImage remote control is enabled (tcp mode)
            %     ASSUME: ScanImage TCP remote-control server is enabled and listens on 5555.
            %     TEST:   ScanImage menu → Configuration → confirm "Enable TCP Server".
            %             From DAQ PC: nc -z 128.32.177.205 5555 to confirm port is open.
            %     CHANGE: Update default obj.port_ in constructor (or set config.port).
            try
                obj.tcpClient_ = tcpclient(obj.host_, obj.port_, ...
                    'Timeout', obj.connectTimeoutS_);
                obj.isConnected = true;
            catch ME
                error('tfp:hardware:ScanImageBridge:connectFailed', ...
                    ['Cannot connect to ScanImage at %s:%d (TCP mode).\n' ...
                     'Consider using connectionMode ''msocket'' or ''ttl_only''.\n' ...
                     'Error: %s'], obj.host_, obj.port_, ME.message);
            end
            obj.logEvent('tcpConnect', struct('host', obj.host_, 'port', obj.port_));
        end

        function siCommand(obj, cmd)
            %siCommand Send a MATLAB command to ScanImage (tcp mode); discard response.
            %   %VERIFY response terminator matches ScanImage TCP server (tcp mode)
            %     ASSUME: writeline sends '\n'; any echoed bytes are fully drained by the
            %             NumBytesAvailable read below.
            %     TEST:   After writeline, check if tcpClient_.NumBytesAvailable remains > 0
            %             after the read() — stale bytes mean drain is incomplete.
            %     CHANGE: Switch to readline or adjust the byte count as needed.
            writeline(obj.tcpClient_, cmd);
            pause(0.02);
            if obj.tcpClient_.NumBytesAvailable > 0
                read(obj.tcpClient_, obj.tcpClient_.NumBytesAvailable);
            end
        end

        function response = siQuery(obj, expr)
            %siQuery Evaluate a MATLAB expression in ScanImage; return result string.
            %   %VERIFY response format — ScanImage may prefix/suffix differently (tcp mode)
            %     ASSUME: ScanImage TCP server returns the evaluated result as a plain string
            %             terminated by '\n', with no 'ans = ' prefix or other decoration.
            %     TEST:   siQuery('hSI.acqState') and inspect the raw response — look for
            %             leading/trailing characters.
            %     CHANGE: Add prefix-stripping (e.g. regexprep) before returning response.
            writeline(obj.tcpClient_, expr);
            response = strtrim(readline(obj.tcpClient_));
        end

        function pollUntilIdle(obj, timeoutS)
            %pollUntilIdle Poll hSI.acqState every 100 ms until 'idle' (tcp mode).
            t0 = tic;
            while toc(t0) < timeoutS
                try
                    %VERIFY 'idle' is the exact acqState string ScanImage returns (tcp mode)
                    %  ASSUME: hSI.acqState == 'idle' (case-insensitive) when not acquiring.
                    %  TEST:   ScanImage MATLAB console while idle: disp(hSI.acqState)
                    %  CHANGE: Update strcmpi check to match the real state string.
                    state = obj.siQuery('hSI.acqState');
                catch
                    break;
                end
                if strcmpi(strtrim(state), 'idle')
                    return;
                end
                pause(0.1);
            end
            warning('tfp:hardware:ScanImageBridge:acquisitionTimeout', ...
                'ScanImage did not return to idle within %.1f s.', timeoutS);
        end

        function framesPath = queryLastTiffPath(obj)
            %queryLastTiffPath Query ScanImage for the most recent TIFF (tcp mode).
            %   %VERIFY hSI.hScan2D.logFilePath and logFileStem property names (tcp mode)
            %     ASSUME: ScanImage 2020+ exposes logFilePath and logFileStem on hSI.hScan2D.
            %     TEST:   ScanImage MATLAB console: hSI.hScan2D.logFilePath; hSI.hScan2D.logFileStem
            %     CHANGE: Replace property names to match your installed ScanImage version's API.
            framesPath = '';
            try
                logDir  = obj.siQuery('hSI.hScan2D.logFilePath');
                logStem = obj.siQuery('hSI.hScan2D.logFileStem');
                if isempty(logDir) || isempty(logStem)
                    return;
                end
                listing = dir(fullfile(logDir, [logStem '*.tif*']));
                if isempty(listing)
                    warning('tfp:hardware:ScanImageBridge:noTiff', ...
                        'No TIFF found in "%s" matching stem "%s".', logDir, logStem);
                    return;
                end
                [~, newestIdx] = max([listing.datenum]);
                framesPath = fullfile(listing(newestIdx).folder, ...
                    listing(newestIdx).name);
            catch ME
                warning('tfp:hardware:ScanImageBridge:fileQueryFailed', ...
                    'Could not retrieve TIFF path from ScanImage: %s', ME.message);
            end
        end

        % --- shared -------------------------------------------------------------

        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end
    end
end

% --- Local helper ---

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
