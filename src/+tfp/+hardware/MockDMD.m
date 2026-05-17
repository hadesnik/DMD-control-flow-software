classdef MockDMD < tfp.hardware.DMD
    %MockDMD Simulated DMD device for pre-hardware development.
    %   Stores patterns in memory, advances through them on softTrigger
    %   or advanceToPattern calls, and logs every public call with a
    %   timestamp so tests and trial scripts can be validated
    %   end-to-end without real hardware.
    %
    %   Debug-figure rendering is not implemented in Phase 1; the
    %   tfp.util.DebugFigure class is not yet scaffolded. When
    %   config.debugFigure = true is passed to initialize(), the mock
    %   logs a 'renderToDebugFigure' event instead of drawing.
    %
    %   TODO(Phase 2): wire up real rendering once tfp.util.DebugFigure
    %   exists.
    %
    %   See ARCHITECTURE.md "MockDMD".

    properties (SetAccess = protected)
        nRows = []
        nCols = []
        maxPatternRate = []
        isInitialized = false
    end

    properties (Access = private)
        patterns_ = []
        options_ = []
        state_ = 'idle'
        currentPatternIdx_ = 0
        lastTriggerTime_ = NaT
        log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {})
        loadLatencyMsPerPattern_ = 10
        debugFigure_ = false
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MockDMD:badConfig', ...
                    'config must be a struct.');
            end

            obj.nRows                    = configField(config, 'nRows', 800);
            obj.nCols                    = configField(config, 'nCols', 1280);
            obj.maxPatternRate           = configField(config, 'maxPatternRate', 12500);
            obj.debugFigure_             = logical(configField(config, 'debugFigure', false));
            obj.loadLatencyMsPerPattern_ = configField(config, 'loadLatencyMsPerPattern', 10);

            obj.state_             = 'idle';
            obj.currentPatternIdx_ = 0;
            obj.lastTriggerTime_   = NaT;
            obj.patterns_          = [];
            obj.options_           = [];
            obj.isInitialized      = true;

            obj.logEvent('initialize', config);
        end

        function loadPatternSequence(obj, patterns, options)
            if ~obj.isInitialized
                error('tfp:hardware:MockDMD:notInitialized', ...
                    'initialize() must be called before loadPatternSequence().');
            end
            if ~islogical(patterns)
                error('tfp:hardware:MockDMD:badPatterns', ...
                    'patterns must be a logical array.');
            end
            if ndims(patterns) > 3 || size(patterns, 1) ~= obj.nRows ...
                    || size(patterns, 2) ~= obj.nCols
                error('tfp:hardware:MockDMD:badPatternShape', ...
                    'patterns must be [%d x %d x N]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(patterns)));
            end
            if ~isstruct(options) ...
                    || ~isfield(options, 'exposureUs') ...
                    || ~isfield(options, 'darkTimeUs')
                error('tfp:hardware:MockDMD:badOptions', ...
                    'options must be a struct with .exposureUs and .darkTimeUs.');
            end

            obj.patterns_          = patterns;
            obj.options_           = options;
            obj.state_             = 'idle';
            obj.currentPatternIdx_ = 0;

            nPatterns = size(patterns, 3);
            obj.logEvent('loadPatternSequence', struct('nPatterns', nPatterns));

            if obj.loadLatencyMsPerPattern_ > 0
                pause(obj.loadLatencyMsPerPattern_ * nPatterns / 1000);
            end

            if obj.debugFigure_
                obj.logEvent('renderToDebugFigure', struct('patternIdx', 1));
            end
        end

        function armSequence(obj)
            if isempty(obj.patterns_)
                error('tfp:hardware:MockDMD:noPatterns', ...
                    'cannot arm without patterns loaded.');
            end
            obj.state_             = 'armed';
            obj.currentPatternIdx_ = 0;
            obj.logEvent('armSequence', []);
        end

        function softTrigger(obj)
            if ~ismember(obj.state_, {'armed', 'running'})
                error('tfp:hardware:MockDMD:notArmed', ...
                    'softTrigger requires armSequence first; got state %s.', obj.state_);
            end
            nPatterns = size(obj.patterns_, 3);
            obj.currentPatternIdx_ = mod(obj.currentPatternIdx_, nPatterns) + 1;
            obj.state_             = 'running';
            obj.lastTriggerTime_   = datetime('now');
            obj.logEvent('softTrigger', struct('patternIdx', obj.currentPatternIdx_));
        end

        function advanceToPattern(obj, idx)
            if ~ismember(obj.state_, {'armed', 'running'})
                error('tfp:hardware:MockDMD:notArmed', ...
                    'advanceToPattern requires armSequence first; got state %s.', obj.state_);
            end
            nPatterns = size(obj.patterns_, 3);
            if ~isnumeric(idx) || ~isscalar(idx) || ~isfinite(idx) ...
                    || idx < 1 || idx > nPatterns || idx ~= round(idx)
                error('tfp:hardware:MockDMD:badIdx', ...
                    'idx must be a positive integer in 1..%d; got %g.', nPatterns, idx);
            end
            obj.currentPatternIdx_ = idx;
            obj.state_             = 'running';
            obj.lastTriggerTime_   = datetime('now');
            obj.logEvent('advanceToPattern', struct('patternIdx', idx));
        end

        function status = getStatus(obj)
            status.state             = obj.state_;
            status.currentPatternIdx = obj.currentPatternIdx_;
            if isempty(obj.patterns_)
                status.nPatternsLoaded = 0;
            else
                status.nPatternsLoaded = size(obj.patterns_, 3);
            end
            status.lastTriggerTime = obj.lastTriggerTime_;
        end

        function cleanup(obj)
            obj.patterns_          = [];
            obj.options_           = [];
            obj.state_             = 'idle';
            obj.currentPatternIdx_ = 0;
            obj.lastTriggerTime_   = NaT;
            obj.isInitialized      = false;
            obj.nRows              = [];
            obj.nCols              = [];
            obj.maxPatternRate     = [];
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
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
