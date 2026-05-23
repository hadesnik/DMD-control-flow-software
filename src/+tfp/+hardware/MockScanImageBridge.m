classdef MockScanImageBridge < handle
%MockScanImageBridge Simulated ScanImage bridge for mock all-optical pipeline.
%   Implements the ScanImageBridge interface from ARCHITECTURE.md.  Uses an
%   array of tfp.sim.CellResponseModel objects together with the active DMD
%   pattern (set via setActivePattern) to generate GCaMP-like ΔF/F traces
%   through tfp.sim.SyntheticImaging.
%
%   Two usage modes:
%
%   1. Legacy synthetic-imaging mode (Phase 1.5; unchanged):
%        bridge.armForExternalTrigger(nFrames)
%        bridge.setActivePattern(mask, stimOnsetSec, stimDurationSec)
%        daq.start()
%        ...
%        bridge.waitForCompletion(timeoutS)
%        [~, ts] = bridge.getLastAcquisition()
%        result  = bridge.getSyntheticResult()
%
%   2. Episodic API (T-EP-1c, per docs/SYNC_EPISODIC.md §9):
%        bridge.beginSession(opts)
%        for each trial:
%            bridge.armForExternalTrigger(nFrames)
%            ... fire start-acq TTL via DAQ ...
%            bridge.waitForCompletion(timeoutS)
%            tiffPath = bridge.getLastTiffPath()   % .mat sidecar
%        bridge.disconnect()
%
%      Episodic mode writes a per-trial .mat sidecar under mockTiffDir_
%      containing a `meta` struct matching the shape produced by
%      tfp.io.readScanImageTiff (SYNC_EPISODIC.md §6.2 / §9.7). Test
%      hooks injectFrameDrop/injectSpuriousEdge perturb the synthesised
%      timestamps for the NEXT trial only.
%
%   Log format matches MockDMD/MockDAQ: getLog() returns a struct array
%   with fields {timestamp, eventType, payload}.
%
%   See ARCHITECTURE.md "ScanImageBridge", CLAUDE.md Phase 1.5 notes, and
%   docs/SYNC_EPISODIC.md §9 for the locked episodic API contract.

    properties (Access = private)
        % Legacy synthetic-imaging fields (Phase 1.5)
        nFrames_           % set by armForExternalTrigger
        frameRate_         % Hz (from config, default 30) — used by legacy path
        cells_             % array of tfp.sim.CellResponseModel
        lastResult_        % most recent SyntheticImaging output struct
        log_               % struct array {timestamp, eventType, payload}
        stimOnsetSec_      % set by setActivePattern
        stimDurationSec_   % set by setActivePattern
        activePattern_     % logical mask, set by setActivePattern
        simulateLatency_   % logical; if false, waitForCompletion skips pause

        % Episodic API fields (T-EP-1c, SYNC_EPISODIC §9)
        state_              % 'idle' | 'armed' | 'acquiring' | 'completed'
        sessionActive_      % logical; gates the episodic state machine
        startAcqNum_        % uint32 — session snapshot from beginSession
        logFileStem_        % char   — session snapshot from beginSession
        logFileSaveDir_     % char   — session snapshot from beginSession
        acqNumWidth_        % uint8  — session snapshot from beginSession
        trialCounter_       % uint32 — incremented per armForExternalTrigger
        nFramesExpected_    % uint32 — set by armForExternalTrigger (episodic)
        mockTiffDir_        % char   — sidecar directory
        frameRateHz_        % double — used to synthesise sidecar timestamps
        injectedDrops_      % uint32 row vector; cleared in waitForCompletion
        injectedSpurious_   % uint32 row vector; cleared in waitForCompletion
        lastTiffPath_       % char   — path returned by getLastTiffPath
    end

    methods
        function obj = MockScanImageBridge(cells, config)
            %MockScanImageBridge Construct a mock ScanImage bridge.
            %
            %   MockScanImageBridge(cells, config)
            %     cells:  scalar or array of tfp.sim.CellResponseModel
            %             (may be [] or omitted for pure episodic-API use)
            %     config: struct; recognised fields:
            %               .frameRate       (default 30, Hz)
            %               .frameRateHz     (alias for frameRate; default 30)
            %               .simulateLatency (default false)
            %               .mockTiffDir     (default
            %                                 fullfile(tempdir(),
            %                                 'tfp_mock_tiffs'))
            %             Pass struct() or omit for all defaults.
            if nargin < 1
                cells = {};
            end
            if nargin < 2 || isempty(config)
                config = struct();
            end
            if ~iscell(cells)
                cells = num2cell(cells);
            end
            obj.cells_           = cells;
            obj.frameRate_       = configField(config, 'frameRate',       30);
            obj.frameRateHz_     = configField(config, 'frameRateHz', obj.frameRate_);
            obj.simulateLatency_ = logical(configField(config, 'simulateLatency', false));
            obj.nFrames_         = 0;
            obj.lastResult_      = [];
            obj.stimOnsetSec_    = 0;
            obj.stimDurationSec_ = 0;
            obj.activePattern_   = [];
            obj.log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {});

            % Episodic-API initialisation
            obj.state_            = 'idle';
            obj.sessionActive_    = false;
            obj.startAcqNum_      = uint32(0);
            obj.logFileStem_      = '';
            obj.logFileSaveDir_   = '';
            obj.acqNumWidth_      = uint8(5);
            obj.trialCounter_     = uint32(0);
            obj.nFramesExpected_  = uint32(0);
            obj.mockTiffDir_      = configField(config, 'mockTiffDir', ...
                fullfile(tempdir(), 'tfp_mock_tiffs'));
            obj.injectedDrops_    = uint32([]);
            obj.injectedSpurious_ = uint32([]);
            obj.lastTiffPath_     = '';
        end

        function setPendingPower(obj, powerMw)
            %setPendingPower No-op stub matching ScanImageBridge interface.
            obj.logEvent('setPendingPower', struct('powerMw', double(powerMw)));
        end

        function armForExternalTrigger(obj, nFrames)
            %armForExternalTrigger Prepare to acquire nFrames imaging frames.
            %
            %   Two modes:
            %     - Legacy (sessionActive_ == false): existing Phase 1.5
            %       behaviour — just records nFrames_ for getLastAcquisition.
            %     - Episodic (sessionActive_ == true): enforces the state
            %       machine in SYNC_EPISODIC.md §9.3; transitions idle→armed
            %       and increments trialCounter_.
            if ~isnumeric(nFrames) || ~isscalar(nFrames) || ...
                    ~isfinite(nFrames) || nFrames < 1
                error('tfp:hardware:ScanImageBridge:badNFrames', ...
                    'nFrames must be a positive finite scalar.');
            end
            obj.nFrames_ = round(nFrames);

            if obj.sessionActive_
                if ~strcmp(obj.state_, 'idle')
                    error('tfp:hardware:ScanImageBridge:badState', ...
                        ['armForExternalTrigger requires state_==''idle''' ...
                         ' (got ''%s'').'], obj.state_);
                end
                obj.nFramesExpected_ = uint32(obj.nFrames_);
                obj.trialCounter_    = obj.trialCounter_ + uint32(1);
                obj.state_           = 'armed';
            end
            obj.logEvent('armForExternalTrigger', struct( ...
                'nFrames',        obj.nFrames_, ...
                'sessionActive',  obj.sessionActive_, ...
                'trialCounter',   obj.trialCounter_));
        end

        function setActivePattern(obj, patternMask, stimOnsetSec, stimDurationSec)
            %setActivePattern Provide the DMD pattern and stim timing for the next trial.
            %   Call this after armForExternalTrigger and before daq.start().
            %   patternMask:     logical(nRows, nCols) or (nRows, nCols, N)
            %   stimOnsetSec:    stim onset time within the trial window (s)
            %   stimDurationSec: stim on-duration (s), e.g. pulseWidth_s
            obj.activePattern_   = logical(patternMask);
            obj.stimOnsetSec_    = double(stimOnsetSec);
            obj.stimDurationSec_ = double(stimDurationSec);
            obj.logEvent('setActivePattern', struct( ...
                'stimOnsetSec',    stimOnsetSec, ...
                'stimDurationSec', stimDurationSec));
        end

        function waitForCompletion(obj, timeoutS)
            %waitForCompletion Simulate waiting for ScanImage to complete acquisition.
            %
            %   Legacy mode: pauses for min(nFrames/frameRate, timeoutS) if
            %   simulateLatency is true; otherwise returns immediately.
            %
            %   Episodic mode (sessionActive_ == true): writes the per-trial
            %   .mat sidecar described in SYNC_EPISODIC.md §9.7 and
            %   transitions state_ → 'completed'. Honours
            %   injectFrameDrop/injectSpuriousEdge for this trial only.
            actualWaitS = obj.nFrames_ / obj.frameRate_;
            if obj.simulateLatency_
                pause(min(actualWaitS, timeoutS));
            end

            if obj.sessionActive_
                if ~ismember(obj.state_, {'armed', 'acquiring'})
                    error('tfp:hardware:ScanImageBridge:badState', ...
                        ['waitForCompletion requires state_ in {armed,' ...
                         ' acquiring} (got ''%s'').'], obj.state_);
                end
                obj.writeEpisodicSidecar_();
                obj.state_ = 'completed';
            end

            obj.logEvent('waitForCompletion', ...
                struct('simulatedWaitS', actualWaitS, 'timeoutS', timeoutS, ...
                       'sessionActive', obj.sessionActive_));
        end

        function [framesPath, frameTimestamps] = getLastAcquisition(obj)
            %getLastAcquisition Return mock timestamps and generate synthetic imaging data.
            %
            %   framesPath:      '' (no real TIFF in mock)
            %   frameTimestamps: 1 × nFrames linspace from 0 to nFrames/frameRate
            %
            %   Also populates obj.lastResult_ via tfp.sim.SyntheticImaging.
            %   Retrieve the result with getSyntheticResult().
            framesPath      = '';
            frameTimestamps = linspace(0, obj.nFrames_ / obj.frameRate_, obj.nFrames_);

            if ~isempty(obj.cells_) && ~isempty(obj.activePattern_)
                obj.lastResult_ = tfp.sim.SyntheticImaging( ...
                    obj.cells_, obj.activePattern_, frameTimestamps, ...
                    obj.stimOnsetSec_, obj.stimDurationSec_);
            else
                obj.lastResult_ = [];
            end

            obj.logEvent('getLastAcquisition', struct('nFrames', obj.nFrames_));
        end

        function result = getSyntheticResult(obj)
            %getSyntheticResult Return the Fall.mat-like struct from the last acquisition.
            %   Returns [] if getLastAcquisition has not been called yet.
            result = obj.lastResult_;
        end

        function F = getLiveTraces(obj)
            %getLiveTraces Return the synthetic F matrix from the last trial.
            %   Returns lastResult_.F (nCells × nFrames), or [] if
            %   getLastAcquisition has not yet been called.
            %   In the mock, F is computed all at once in getLastAcquisition
            %   rather than streamed per-frame — the interface is identical
            %   to the real ScanImageBridge for liveFigures compatibility.
            if isempty(obj.lastResult_)
                F = [];
            else
                F = obj.lastResult_.F;
            end
        end

        function clearLiveTraces(obj)
            %clearLiveTraces No-op for mock: SyntheticImaging computes F
            %   all at once in getLastAcquisition; no per-frame accumulator.
            obj.logEvent('clearLiveTraces', struct());
        end

        function tf = supportsStreaming(obj) %#ok<MANU>
            %supportsStreaming Returns false — mock does not use the streaming socket.
            %   Real ScanImageBridge returns true when config.streamLiveF is set.
            tf = false;
        end

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields {timestamp, eventType, payload}.
            entries = obj.log_;
        end

        % ============================================================
        % Episodic API (T-EP-1c, SYNC_EPISODIC.md §9)
        % ============================================================

        function sessionInfo = beginSession(obj, opts)
            %beginSession Snapshot ScanImage session context (mock version).
            %   See SYNC_EPISODIC.md §9.2. For the mock, snapshot fields are
            %   taken from opts or defaults; no real ScanImage is contacted.
            if nargin < 2 || isempty(opts)
                opts = struct();
            end
            if ~strcmp(obj.state_, 'idle')
                error('tfp:hardware:ScanImageBridge:badState', ...
                    ['beginSession requires state_==''idle'' (got ''%s'').'], ...
                    obj.state_);
            end
            if obj.sessionActive_
                error('tfp:hardware:ScanImageBridge:badState', ...
                    'beginSession called while a session is already active.');
            end

            obj.startAcqNum_    = uint32(configField(opts, 'startAcqNumOverride', uint32(1)));
            obj.logFileStem_    = char(configField(opts, 'logFileStemOverride', 'mock_trial'));
            obj.logFileSaveDir_ = char(configField(opts, 'logFileSaveDirOverride', obj.mockTiffDir_));
            obj.acqNumWidth_    = uint8(5);
            obj.trialCounter_   = uint32(0);
            obj.sessionActive_  = true;

            if ~exist(obj.logFileSaveDir_, 'dir')
                mkdir(obj.logFileSaveDir_);
            end

            sessionInfo = struct( ...
                'startAcqNum',          obj.startAcqNum_, ...
                'logFileStem',          obj.logFileStem_, ...
                'logFileSaveDir',       obj.logFileSaveDir_, ...
                'acqNumWidth',          obj.acqNumWidth_, ...
                'sessionStartDatetime', datetime('now'));

            obj.logEvent('beginSession', sessionInfo);
        end

        function tiffPath = getLastTiffPath(obj)
            %getLastTiffPath Return the .mat sidecar path for the just-completed trial.
            %   See SYNC_EPISODIC.md §9.5 / §9.7. Transitions completed→idle.
            if ~obj.sessionActive_
                error('tfp:hardware:ScanImageBridge:badState', ...
                    'getLastTiffPath requires sessionActive_==true.');
            end
            if ~strcmp(obj.state_, 'completed')
                error('tfp:hardware:ScanImageBridge:badState', ...
                    ['getLastTiffPath requires state_==''completed''' ...
                     ' (got ''%s'').'], obj.state_);
            end
            tiffPath  = obj.lastTiffPath_;
            obj.state_ = 'idle';
            obj.logEvent('getLastTiffPath', struct( ...
                'tiffPath',     tiffPath, ...
                'trialCounter', obj.trialCounter_));
        end

        function verifyEpisodicProtocol(obj)
            %verifyEpisodicProtocol Round-trip diagnostic (always restores state).
            %   See SYNC_EPISODIC.md §9.6. Never throws; prints PASS/FAIL.
            fprintf('verifyEpisodicProtocol (mock):\n');
            try
                savedSessionActive = obj.sessionActive_;
                savedState         = obj.state_;
                savedTrialCounter  = obj.trialCounter_;

                if obj.sessionActive_
                    fprintf('  Session already active; restoring after diagnostic.\n');
                else
                    obj.beginSession(struct());
                end

                obj.armForExternalTrigger(3);
                obj.waitForCompletion(5);
                tp = obj.getLastTiffPath();

                ok = ~isempty(tp) && exist(tp, 'file') == 2;
                if ok
                    fprintf('  PASS  arm → wait → getLastTiffPath round-trip\n');
                else
                    fprintf('  FAIL  sidecar not found: %s\n', tp);
                end

                % Restore previous session state.
                obj.sessionActive_ = savedSessionActive;
                obj.state_         = savedState;
                obj.trialCounter_  = savedTrialCounter;
            catch ME
                fprintf('  FAIL  %s: %s\n', ME.identifier, ME.message);
                % Best-effort restore.
                obj.state_         = 'idle';
            end
        end

        function disconnect(obj)
            %disconnect Reset session state; clears the episodic state machine.
            %   Preserves mockTiffDir_ (constructor-configured) and frameRateHz_.
            obj.state_            = 'idle';
            obj.sessionActive_    = false;
            obj.startAcqNum_      = uint32(0);
            obj.logFileStem_      = '';
            obj.logFileSaveDir_   = '';
            obj.acqNumWidth_      = uint8(5);
            obj.trialCounter_     = uint32(0);
            obj.nFramesExpected_  = uint32(0);
            obj.injectedDrops_    = uint32([]);
            obj.injectedSpurious_ = uint32([]);
            obj.lastTiffPath_     = '';
            obj.logEvent('disconnect', struct());
        end

        function injectFrameDrop(obj, frameIdx)
            %injectFrameDrop Test hook: remove frame `frameIdx` from the next
            %sidecar's synthesised timestamps. Applies to the NEXT trial only.
            obj.injectedDrops_(end+1) = uint32(frameIdx);
            obj.logEvent('injectFrameDrop', struct('frameIdx', uint32(frameIdx)));
        end

        function injectSpuriousEdge(obj, frameIdx)
            %injectSpuriousEdge Test hook: duplicate frame `frameIdx` in the
            %next sidecar's synthesised timestamps. Applies to the NEXT trial.
            obj.injectedSpurious_(end+1) = uint32(frameIdx);
            obj.logEvent('injectSpuriousEdge', struct('frameIdx', uint32(frameIdx)));
        end
    end

    methods (Access = private)
        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end

        function writeEpisodicSidecar_(obj)
            %writeEpisodicSidecar_ Build and save the .mat sidecar for this trial.
            n = double(obj.nFramesExpected_);
            if n <= 0
                frameTimestamps_s = zeros(0, 1);
            elseif n == 1
                frameTimestamps_s = 0;
            else
                frameTimestamps_s = linspace(0, (n - 1) / obj.frameRateHz_, n)';
            end

            % Apply injections (NEXT-trial only; cleared after this call).
            if ~isempty(obj.injectedSpurious_)
                spur = sort(double(obj.injectedSpurious_), 'descend');
                for k = 1:numel(spur)
                    idx = spur(k);
                    if idx >= 1 && idx <= numel(frameTimestamps_s)
                        frameTimestamps_s = [ ...
                            frameTimestamps_s(1:idx); ...
                            frameTimestamps_s(idx); ...
                            frameTimestamps_s(idx+1:end)];
                    end
                end
            end
            if ~isempty(obj.injectedDrops_)
                dropMask = false(numel(frameTimestamps_s), 1);
                for k = 1:numel(obj.injectedDrops_)
                    idx = double(obj.injectedDrops_(k));
                    if idx >= 1 && idx <= numel(frameTimestamps_s)
                        dropMask(idx) = true;
                    end
                end
                frameTimestamps_s(dropMask) = [];
            end

            meta = struct(); %#ok<NASGU>  -- used in save() below
            meta.numFrames                = uint32(numel(frameTimestamps_s));
            meta.numChannels              = uint32(1);
            meta.frameRateHz              = obj.frameRateHz_;
            meta.frameTimestamps_s        = frameTimestamps_s;
            meta.timestampsAreSynthesised = true;
            meta.sourceTiff               = '';
            meta.scanImageVersion         = 'mock';

            sidecarPath = fullfile(obj.mockTiffDir_, ...
                sprintf('mock_trial_%04d.mat', double(obj.trialCounter_)));
            if ~exist(obj.mockTiffDir_, 'dir')
                mkdir(obj.mockTiffDir_);
            end
            meta.sourceTiff = sidecarPath;

            save(sidecarPath, 'meta', '-v7.3');
            obj.lastTiffPath_ = sidecarPath;

            % Clear injection lists for next trial.
            obj.injectedDrops_    = uint32([]);
            obj.injectedSpurious_ = uint32([]);
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
