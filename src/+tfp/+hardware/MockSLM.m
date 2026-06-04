classdef MockSLM < tfp.hardware.SLM
    %MockSLM Simulated SLM device for pre-hardware development.
    %   Accepts and stores uint8 phase masks in memory, logs every public
    %   call with a timestamp, and provides getActivePattern() so downstream
    %   mocks and tests can inspect what was loaded.
    %
    %   Implements the DIMS CONVENTION: config.dims = [nCols, nRows].
    %   nCols = dims(1), nRows = dims(2).  A CGH mask sized [Ny x Nx] =
    %   [nRows x nCols] therefore passes loadPhaseMask's size check exactly.
    %
    %   If config has explicit nRows / nCols fields they override dims.
    %   Default dims = [1024 1024], pitch_um = 17 µm.
    %
    %   See ARCHITECTURE.md "Hardware abstraction".

    properties (SetAccess = protected)
        nRows         = []
        nCols         = []
        pitch_um      = []
        isInitialized = false
    end

    properties (Access = private)
        mask_         = []       % uint8(nRows, nCols), current loaded mask
        state_        = 'idle'   % 'idle' | 'loaded' | 'presenting'
        powerOn_      = false    % logical, LC drive voltage state
        debugFigure_  = false    % log renderToDebugFigure events if true
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        % ---------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Configure dimensions, pitch, and debug options.
            %   config fields (all optional):
            %     dims        [nCols nRows]  default [1024 1024]
            %     nCols       override dims(1)
            %     nRows       override dims(2)
            %     pitch_um    µm             default 17
            %     debugFigure logical        default false
            if ~isstruct(config)
                error('tfp:hardware:MockSLM:badConfig', ...
                    'config must be a struct.');
            end

            dims = configField(config, 'dims', [1024 1024]);
            obj.nCols         = configField(config, 'nCols', dims(1));
            obj.nRows         = configField(config, 'nRows', dims(2));
            obj.pitch_um      = configField(config, 'pitch_um', 17);
            obj.debugFigure_  = logical(configField(config, 'debugFigure', false));

            obj.mask_         = [];
            obj.state_        = 'idle';
            obj.powerOn_      = false;
            obj.isInitialized = true;

            obj.logEvent('initialize', config);
        end

        % ---------------------------------------------------------------- %
        function loadPhaseMask(obj, mask)
            %loadPhaseMask Validate and store a uint8 phase mask.
            %   mask: uint8([nRows nCols]).
            %   Errors:
            %     tfp:hardware:MockSLM:notInitialized  — initialize not called
            %     tfp:hardware:MockSLM:badMask         — not uint8
            %     tfp:hardware:MockSLM:badMaskShape    — wrong size
            if ~obj.isInitialized
                error('tfp:hardware:MockSLM:notInitialized', ...
                    'initialize() must be called before loadPhaseMask().');
            end
            if ~isa(mask, 'uint8')
                error('tfp:hardware:MockSLM:badMask', ...
                    'mask must be uint8; got %s.', class(mask));
            end
            if ~isequal(size(mask), [obj.nRows, obj.nCols])
                error('tfp:hardware:MockSLM:badMaskShape', ...
                    'mask must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(mask)));
            end

            obj.mask_  = mask;
            obj.state_ = 'loaded';
            obj.logEvent('loadPhaseMask', struct('size', size(mask)));
        end

        % ---------------------------------------------------------------- %
        function present(obj)
            %present Commit the loaded mask to the (simulated) SLM display.
            %   Transitions state to 'presenting'.
            if ~obj.isInitialized
                error('tfp:hardware:MockSLM:notInitialized', ...
                    'initialize() must be called before present().');
            end

            obj.state_ = 'presenting';
            obj.logEvent('present', []);

            if obj.debugFigure_
                obj.logEvent('renderToDebugFigure', []);
            end
        end

        % ---------------------------------------------------------------- %
        function blank(obj)
            %blank Load an all-zero mask and present it immediately.
            %   Transitions state to 'presenting'.
            if ~obj.isInitialized
                error('tfp:hardware:MockSLM:notInitialized', ...
                    'initialize() must be called before blank().');
            end

            obj.mask_  = zeros(obj.nRows, obj.nCols, 'uint8');
            obj.state_ = 'presenting';
            obj.logEvent('blank', []);
        end

        % ---------------------------------------------------------------- %
        function slmPower(obj, onTF)
            %slmPower Enable or disable the simulated LC drive voltage.
            %   onTF: logical scalar.
            if ~obj.isInitialized
                error('tfp:hardware:MockSLM:notInitialized', ...
                    'initialize() must be called before slmPower().');
            end

            obj.powerOn_ = logical(onTF);
            obj.logEvent('slmPower', struct('on', obj.powerOn_));
        end

        % ---------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Return a struct with current device state.
            %   Fields: state, isMaskLoaded, powerOn.
            status.state        = obj.state_;
            status.isMaskLoaded = ~isempty(obj.mask_);
            status.powerOn      = obj.powerOn_;
        end

        % ---------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Reset all state; logs the event.
            obj.mask_         = [];
            obj.state_        = 'idle';
            obj.powerOn_      = false;
            obj.isInitialized = false;
            obj.nRows         = [];
            obj.nCols         = [];
            obj.pitch_um      = [];
            obj.logEvent('cleanup', []);
        end

        % ---------------------------------------------------------------- %
        function mask = getActivePattern(obj)
            %getActivePattern Return the currently stored phase mask.
            %   Returns uint8(nRows, nCols) or [] if no mask has been loaded.
            mask = obj.mask_;
        end

        % ---------------------------------------------------------------- %
        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    % --------------------------------------------------------------------- %
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
