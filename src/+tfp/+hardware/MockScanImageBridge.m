classdef MockScanImageBridge < handle
%MockScanImageBridge Simulated ScanImage bridge for mock all-optical pipeline.
%   Implements the ScanImageBridge interface from ARCHITECTURE.md.  Uses an
%   array of tfp.sim.CellResponseModel objects together with the active DMD
%   pattern (set via setActivePattern) to generate GCaMP-like ΔF/F traces
%   through tfp.sim.SyntheticImaging.
%
%   Typical call sequence in the Sequencer loop:
%     bridge.armForExternalTrigger(nFrames)
%     bridge.setActivePattern(mask, stimOnsetSec, stimDurationSec)
%     daq.start()
%     ...
%     bridge.waitForCompletion(timeoutS)
%     [~, ts] = bridge.getLastAcquisition()
%     result  = bridge.getSyntheticResult()
%
%   Log format matches MockDMD/MockDAQ: getLog() returns a struct array
%   with fields {timestamp, eventType, payload}.
%
%   See ARCHITECTURE.md "ScanImageBridge" and CLAUDE.md Phase 1.5 notes.

    properties (Access = private)
        nFrames_           % set by armForExternalTrigger
        frameRate_         % Hz (from config, default 30)
        cells_             % array of tfp.sim.CellResponseModel
        lastResult_        % most recent SyntheticImaging output struct
        log_               % struct array {timestamp, eventType, payload}
        stimOnsetSec_      % set by setActivePattern
        stimDurationSec_   % set by setActivePattern
        activePattern_     % logical mask, set by setActivePattern
        simulateLatency_   % logical; if false, waitForCompletion skips pause
    end

    methods
        function obj = MockScanImageBridge(cells, config)
            %MockScanImageBridge Construct a mock ScanImage bridge.
            %
            %   MockScanImageBridge(cells, config)
            %     cells:  scalar or array of tfp.sim.CellResponseModel
            %     config: struct; recognised fields:
            %               .frameRate       (default 30, Hz)
            %               .simulateLatency (default false)
            %             Pass struct() or omit for all defaults.
            if nargin < 2 || isempty(config)
                config = struct();
            end
            if ~iscell(cells)
                cells = num2cell(cells);
            end
            obj.cells_           = cells;
            obj.frameRate_       = configField(config, 'frameRate',       30);
            obj.simulateLatency_ = logical(configField(config, 'simulateLatency', false));
            obj.nFrames_         = 0;
            obj.lastResult_      = [];
            obj.stimOnsetSec_    = 0;
            obj.stimDurationSec_ = 0;
            obj.activePattern_   = [];
            obj.log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {});
        end

        function armForExternalTrigger(obj, nFrames)
            %armForExternalTrigger Prepare to acquire nFrames imaging frames.
            %   Call this before setActivePattern and daq.start().
            if ~isnumeric(nFrames) || ~isscalar(nFrames) || ...
                    ~isfinite(nFrames) || nFrames < 1
                error('tfp:sim:MockScanImageBridge:badNFrames', ...
                    'nFrames must be a positive finite scalar.');
            end
            obj.nFrames_ = round(nFrames);
            obj.logEvent('armForExternalTrigger', struct('nFrames', obj.nFrames_));
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
            %   If config.simulateLatency is true, pauses for min(nFrames/frameRate,
            %   timeoutS) to approximate real acquisition time.  False by default
            %   so tests return immediately without real wall-clock delays.
            actualWaitS = obj.nFrames_ / obj.frameRate_;
            if obj.simulateLatency_
                pause(min(actualWaitS, timeoutS));
            end
            obj.logEvent('waitForCompletion', ...
                struct('simulatedWaitS', actualWaitS, 'timeoutS', timeoutS));
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

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    methods (Access = private)
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
