classdef MockZStage < tfp.hardware.ZStage
    %MockZStage Simulated axial stage for pre-hardware development and tests.
    %   Holds an in-memory position; moveTo/getPosition are instantaneous
    %   (optional simulated settle). Logs every public call with a timestamp so
    %   tests can verify move sequences, matching the other Mock* devices.
    %
    %   Configure via a struct passed to initialize():
    %     .rangeUm  — soft travel limits [lo hi] µm (default [-500 500])
    %     .startUm  — initial position (default 0)
    %     .settleS  — simulated settle pause per move, seconds (default 0)
    %
    %   See also tfp.calibration.measureFocalPlaneTilt.

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        settleS_ = 0
        log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if nargin < 2 || isempty(config)
                config = struct();
            end
            if ~isstruct(config)
                error('tfp:hardware:MockZStage:badConfig', 'config must be a struct.');
            end
            obj.rangeUm    = configField(config, 'rangeUm', [-500, 500]);
            obj.positionUm = configField(config, 'startUm', 0);
            obj.settleS_   = configField(config, 'settleS', 0);
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function moveTo(obj, zUm)
            if ~obj.isInitialized
                error('tfp:hardware:MockZStage:notInitialized', ...
                    'initialize() must be called before moveTo().');
            end
            obj.assertInRange_(zUm);
            if obj.settleS_ > 0
                pause(obj.settleS_);
            end
            obj.positionUm = zUm;
            obj.logEvent('moveTo', struct('zUm', zUm));
        end

        function z = getPosition(obj)
            if ~obj.isInitialized
                error('tfp:hardware:MockZStage:notInitialized', ...
                    'initialize() must be called before getPosition().');
            end
            z = obj.positionUm;
            obj.logEvent('getPosition', struct('zUm', z));
        end

        function cleanup(obj)
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            %getLog Return the in-memory call log (timestamp/eventType/payload).
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
