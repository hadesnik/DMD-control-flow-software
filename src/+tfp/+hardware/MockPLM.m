classdef MockPLM < tfp.hardware.PLM
    %MockPLM Simulated PLM device for pre-hardware development.
    %   Accepts and stores uint8 phase patterns in memory, logs every public
    %   call with a timestamp so trial scripts can be validated end-to-end
    %   without real hardware. getActivePattern() returns the current
    %   pattern for downstream mock inspection (e.g. synthesising defocused
    %   images in CellResponseModel or SyntheticImaging).
    %
    %   configureTrigger and advancePattern are logged as events but perform
    %   no hardware I2C calls. computeDefocusPattern and exportPatternImages
    %   are inherited from PLM (exportPatternImages writes real PNG files).
    %
    %   See ARCHITECTURE.md "Hardware abstraction".

    properties (SetAccess = protected)
        nRows         = []
        nCols         = []
        pitchX_um     = []
        pitchY_um     = []
        nPhaseStates  = []
        lambda_nm     = []
        isInitialized = false
    end

    properties (Access = private)
        pattern_       = []       % uint8(nRows, nCols), current loaded pattern
        state_         = 'idle'   % 'idle' | 'loaded'
        log_           = struct('timestamp', {}, 'eventType', {}, 'payload', {})
        loadLatencyMs_ = 0        % simulated load latency, ms
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MockPLM:badConfig', ...
                    'config must be a struct.');
            end

            obj.nRows         = configField(config, 'nRows',         800);
            obj.nCols         = configField(config, 'nCols',         904);
            obj.pitchX_um     = configField(config, 'pitchX_um',     16.2);
            obj.pitchY_um     = configField(config, 'pitchY_um',     10.8);
            obj.nPhaseStates  = configField(config, 'nPhaseStates',  32);
            obj.lambda_nm     = configField(config, 'lambda_nm',     1030);
            obj.loadLatencyMs_ = configField(config, 'loadLatencyMs', 0);

            obj.pattern_      = [];
            obj.state_        = 'idle';
            obj.isInitialized = true;

            obj.logEvent('initialize', config);
        end

        function loadPattern(obj, pattern)
            if ~obj.isInitialized
                error('tfp:hardware:MockPLM:notInitialized', ...
                    'initialize() must be called before loadPattern().');
            end
            obj.validatePattern(pattern);

            obj.pattern_ = pattern;
            obj.state_   = 'loaded';
            obj.logEvent('loadPattern', struct('size', size(pattern)));

            if obj.loadLatencyMs_ > 0
                pause(obj.loadLatencyMs_ / 1000);
            end
        end

        function configureTrigger(obj)
            %configureTrigger Log the trigger-configure request; I2C TBD.
            if ~obj.isInitialized
                error('tfp:hardware:MockPLM:notInitialized', ...
                    'initialize() must be called before configureTrigger().');
            end
            obj.logEvent('configureTrigger', []);
        end

        function advancePattern(obj)
            %advancePattern Log the advance request; trigger line TBD.
            if ~obj.isInitialized
                error('tfp:hardware:MockPLM:notInitialized', ...
                    'initialize() must be called before advancePattern().');
            end
            obj.logEvent('advancePattern', []);
        end

        function status = getStatus(obj)
            status.state           = obj.state_;
            status.isPatternLoaded = ~isempty(obj.pattern_);
        end

        function cleanup(obj)
            obj.pattern_      = [];
            obj.state_        = 'idle';
            obj.isInitialized = false;
            obj.nRows         = [];
            obj.nCols         = [];
            obj.pitchX_um     = [];
            obj.pitchY_um     = [];
            obj.nPhaseStates  = [];
            obj.lambda_nm     = [];
            obj.logEvent('cleanup', []);
        end

        function pattern = getActivePattern(obj)
            %getActivePattern Return the currently loaded pattern.
            %   Returns uint8(nRows, nCols) or [] if no pattern is loaded.
            %   Used by downstream mocks to synthesise defocused images.
            pattern = obj.pattern_;
        end

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function validatePattern(obj, pattern)
            if ~isa(pattern, 'uint8')
                error('tfp:hardware:MockPLM:badPattern', ...
                    'pattern must be uint8; got %s.', class(pattern));
            end
            if ~isequal(size(pattern), [obj.nRows, obj.nCols])
                error('tfp:hardware:MockPLM:badPatternShape', ...
                    'pattern must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(pattern)));
            end
            if any(pattern(:) >= obj.nPhaseStates)
                error('tfp:hardware:MockPLM:badPatternValues', ...
                    'pattern values must be in 0..%d; got max %d.', ...
                    obj.nPhaseStates - 1, max(pattern(:)));
            end
        end

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
