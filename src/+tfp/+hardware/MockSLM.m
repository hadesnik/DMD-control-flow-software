classdef MockSLM < tfp.hardware.PLM
    %MockSLM Simulated Meadowlark 1K SLM (HSP1K class) for mock development.
    %   Sequence-capable phase modulator mock: prepareDefocusSequence
    %   computes the mask stack locally (same tfp.slm engine as the SLM-PC
    %   server), advanceToIndex steps through it — pulsing the injected
    %   ttlPulseFcn in 'ttl' mode — and getCurrentDefocusUm() exposes the
    %   commanded defocus to the mock imaging/camera chain
    %   (MockScanImageBridge, MockSubstageCamera).
    %
    %   Defaults are the Meadowlark 1024 x 1024, 17.0 um, 8-bit geometry at
    %   1038 nm (docs/optics_handoff.md §2, constants slm_cols/slm_rows/
    %   slm_pitch_um). Mock construct-then-initialize convention; getLog()
    %   per lab standard.

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
        stack_        = []       % uint8(nRows, nCols, N) prepared sequence
        dzListUm_     = []       % 1xN defocus commands, sequence order
        seqIndex_     = 0        % current 1-based position; 0 = none active
        triggerMode_  = ''       % '' | 'ttl' | 'software'
        settleS_      = 0        % settle pause after advance (s); 0 in mock
        ttlPulseFcn_  = []       % injected @() fcn pulsed once per advance step
        pattern_      = []       % uint8(nRows, nCols) single loaded pattern
        state_        = 'idle'   % 'idle' | 'loaded' | 'sequenced' | 'armed'
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if nargin < 2 || isempty(config)
                config = struct();
            end
            if ~isstruct(config)
                error('tfp:hardware:MockSLM:badConfig', ...
                    'config must be a struct.');
            end

            obj.nRows        = tfp.util.configField(config, 'nRows',        1024);
            obj.nCols        = tfp.util.configField(config, 'nCols',        1024);
            obj.pitchX_um    = tfp.util.configField(config, 'pitch_um',     17.0);
            obj.pitchY_um    = obj.pitchX_um;
            obj.nPhaseStates = tfp.util.configField(config, 'nStates',      256);
            % 1038 nm = measured CARBIDE [CERT], not the 1030 setpoint
            obj.lambda_nm    = tfp.util.configField(config, 'lambda_nm',    1038);
            obj.settleS_     = tfp.util.configField(config, 'settle_s',     0);
            if isfield(config, 'ttlPulseFcn')
                obj.setTtlPulseFcn(config.ttlPulseFcn);
            end

            obj.stack_        = [];
            obj.dzListUm_     = [];
            obj.seqIndex_     = 0;
            obj.triggerMode_  = '';
            obj.pattern_      = [];
            obj.state_        = 'idle';
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function setTtlPulseFcn(obj, fcn)
            %setTtlPulseFcn Inject the TTL pulse callable (one pulse = one step).
            %   Experiments pass @() daq.sendDigitalPulse(line, pulse_s).
            if ~isempty(fcn) && ~isa(fcn, 'function_handle')
                error('tfp:hardware:MockSLM:badPulseFcn', ...
                    'ttlPulseFcn must be a function handle or [].');
            end
            obj.ttlPulseFcn_ = fcn;
        end

        function loadPattern(obj, pattern)
            obj.requireInitialized('loadPattern');
            obj.validatePattern(pattern);
            obj.pattern_ = pattern;
            obj.state_   = 'loaded';
            obj.logEvent('loadPattern', struct('size', size(pattern)));
        end

        function configureTrigger(obj)
            %configureTrigger Legacy hook; arms the last-armed or software mode.
            obj.requireInitialized('configureTrigger');
            if isempty(obj.triggerMode_)
                obj.triggerMode_ = 'software';
            end
            obj.logEvent('configureTrigger', struct('mode', obj.triggerMode_));
        end

        function advancePattern(obj)
            %advancePattern Step one position forward in the prepared sequence.
            obj.requireInitialized('advancePattern');
            obj.requireSequence('advancePattern');
            next = obj.seqIndex_ + 1;
            if next > numel(obj.dzListUm_)
                next = 1;   % wrap, matching hardware sequence-loop behaviour
            end
            obj.advanceToIndex(next);
        end

        function status = getStatus(obj)
            status.state            = obj.state_;
            status.isPatternLoaded  = ~isempty(obj.pattern_);
            status.nSequenceMasks   = size(obj.stack_, 3);
            status.sequenceIndex    = obj.seqIndex_;
            status.triggerMode      = obj.triggerMode_;
        end

        function cleanup(obj)
            obj.stack_        = [];
            obj.dzListUm_     = [];
            obj.seqIndex_     = 0;
            obj.triggerMode_  = '';
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

        % ============================================================
        % Defocus-sequence interface
        % ============================================================

        function tf = supportsDefocusSequence(obj) %#ok<MANU>
            tf = true;
        end

        function prepareDefocusSequence(obj, dzListUm, sys)
            %prepareDefocusSequence Compute + "upload" the mask stack.
            %   dzListUm order = sequence order = depth-group order.
            obj.requireInitialized('prepareDefocusSequence');
            if nargin < 3 || isempty(sys)
                error('tfp:hardware:MockSLM:badSys', ...
                    'prepareDefocusSequence requires a sys struct (tfp.optics.buildDefocusSys).');
            end
            % Force device geometry from this object so the stack matches.
            sys.nRows    = obj.nRows;
            sys.nCols    = obj.nCols;
            sys.pitchXUm = obj.pitchX_um;
            sys.pitchYUm = obj.pitchY_um;
            sys.nStates  = obj.nPhaseStates;
            sys.lambdaNm = obj.lambda_nm;

            obj.stack_    = tfp.slm.computeDefocusStack(dzListUm, sys);
            obj.dzListUm_ = double(dzListUm(:)');
            obj.seqIndex_ = 0;
            obj.state_    = 'sequenced';
            obj.logEvent('prepareDefocusSequence', struct( ...
                'nMasks', numel(obj.dzListUm_), 'dzListUm', obj.dzListUm_));
        end

        function armSequenceTrigger(obj, mode)
            obj.requireInitialized('armSequenceTrigger');
            obj.requireSequence('armSequenceTrigger');
            mode = lower(char(mode));
            if ~any(strcmp(mode, {'ttl', 'software'}))
                error('tfp:hardware:MockSLM:badTriggerMode', ...
                    'mode must be ''ttl'' or ''software'' (got ''%s'').', mode);
            end
            if strcmp(mode, 'ttl') && isempty(obj.ttlPulseFcn_)
                error('tfp:hardware:MockSLM:noPulseFcn', ...
                    'ttl mode requires an injected ttlPulseFcn (setTtlPulseFcn).');
            end
            obj.triggerMode_ = mode;
            obj.state_       = 'armed';
            obj.logEvent('armSequenceTrigger', struct('mode', mode));
        end

        function advanceToIndex(obj, idx)
            %advanceToIndex Step to sequence position idx (1-based).
            %   In 'ttl' mode each step pulses ttlPulseFcn once (hardware
            %   semantics: one TTL edge = one frame advance, wrapping).
            obj.requireInitialized('advanceToIndex');
            obj.requireSequence('advanceToIndex');
            if isempty(obj.triggerMode_)
                error('tfp:hardware:MockSLM:notArmed', ...
                    'armSequenceTrigger must be called before advanceToIndex.');
            end
            N = numel(obj.dzListUm_);
            if ~isnumeric(idx) || ~isscalar(idx) || idx ~= round(idx) || ...
                    idx < 1 || idx > N
                error('tfp:hardware:MockSLM:badIdx', ...
                    'idx must be an integer in 1..%d (got %g).', N, idx);
            end
            if idx == obj.seqIndex_
                return   % already on this mask; nothing to do
            end
            current = obj.seqIndex_;
            if current == 0
                nSteps = idx;               % first advance from parked state
            else
                nSteps = mod(idx - current, N);
            end
            for s = 1:nSteps
                if strcmp(obj.triggerMode_, 'ttl')
                    obj.ttlPulseFcn_();
                end
                obj.logEvent('advanceStep', struct('mode', obj.triggerMode_));
            end
            obj.seqIndex_ = idx;
            obj.pattern_  = obj.stack_(:, :, idx);
            if obj.settleS_ > 0
                pause(obj.settleS_);
            end
            obj.logEvent('settle', struct('settleS', obj.settleS_, ...
                'index', idx, 'dzUm', obj.dzListUm_(idx)));
        end

        function idx = getSequenceIndex(obj)
            idx = obj.seqIndex_;
        end

        function t = settleTimeS(obj)
            t = obj.settleS_;
        end

        function dz = getCurrentDefocusUm(obj)
            %getCurrentDefocusUm Commanded defocus of the active mask (um).
            %   NaN when no sequence position is active. Consumed by the
            %   mock sim chain (MockSubstageCamera defocus blur,
            %   MockScanImageBridge 3D responses).
            if obj.seqIndex_ >= 1 && obj.seqIndex_ <= numel(obj.dzListUm_)
                dz = obj.dzListUm_(obj.seqIndex_);
            else
                dz = NaN;
            end
        end

        function pattern = getActivePattern(obj)
            %getActivePattern Return the active mask (sequence or loadPattern).
            pattern = obj.pattern_;
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function requireInitialized(obj, caller)
            if ~obj.isInitialized
                error('tfp:hardware:MockSLM:notInitialized', ...
                    'initialize() must be called before %s().', caller);
            end
        end

        function requireSequence(obj, caller)
            if isempty(obj.stack_)
                error('tfp:hardware:MockSLM:noSequence', ...
                    'prepareDefocusSequence must be called before %s().', caller);
            end
        end

        function validatePattern(obj, pattern)
            if ~isa(pattern, 'uint8')
                error('tfp:hardware:MockSLM:badPattern', ...
                    'pattern must be uint8; got %s.', class(pattern));
            end
            if ~isequal(size(pattern), [obj.nRows, obj.nCols])
                error('tfp:hardware:MockSLM:badPatternShape', ...
                    'pattern must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(pattern)));
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
