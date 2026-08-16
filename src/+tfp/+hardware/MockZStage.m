classdef MockZStage < tfp.hardware.ZStage
    %MockZStage Simulated z axis for calibration tests.
    %   Instant (optionally settle-delayed) moves, perfect position
    %   readback, getLog() per lab convention. The indirect-calibration
    %   mock tests wire this into MockSubstageCamera so a through-focus
    %   sweep sees a consistent world.

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        zUm_     = 0
        settleS_ = 0
        log_     = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if nargin < 2 || isempty(config)
                config = struct();
            end
            obj.zUm_     = double(tfp.util.configField(config, 'startZUm', 0));
            obj.settleS_ = double(tfp.util.configField(config, 'settleS',  0));
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function moveToUm(obj, zUm)
            obj.requireInitialized('moveToUm');
            if ~isnumeric(zUm) || ~isscalar(zUm) || ~isfinite(zUm)
                error('tfp:hardware:MockZStage:badZ', ...
                    'zUm must be a finite numeric scalar.');
            end
            obj.zUm_ = double(zUm);
            if obj.settleS_ > 0
                pause(obj.settleS_);
            end
            obj.logEvent('moveToUm', struct('zUm', obj.zUm_));
        end

        function zUm = getPositionUm(obj)
            obj.requireInitialized('getPositionUm');
            zUm = obj.zUm_;
        end

        function moveRelativeUm(obj, dzUm)
            obj.moveToUm(obj.zUm_ + double(dzUm));
        end

        function status = getStatus(obj)
            status.zUm    = obj.zUm_;
            status.moving = false;
        end

        function cleanup(obj)
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function requireInitialized(obj, caller)
            if ~obj.isInitialized
                error('tfp:hardware:MockZStage:notInitialized', ...
                    'initialize() must be called before %s().', caller);
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
