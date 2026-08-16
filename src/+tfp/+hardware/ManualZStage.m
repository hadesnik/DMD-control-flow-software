classdef ManualZStage < tfp.hardware.ZStage
    %ManualZStage Operator-in-the-loop z axis (no MATLAB-controllable motor).
    %   moveToUm prints an instruction and waits for confirmation;
    %   getPositionUm asks the operator to type the micrometer reading.
    %   Keeps the z-calibration unblocked when the MP-285 is switched away
    %   or the relay helper is not running. Slower, but zero new drivers.
    %
    %   promptFcn is injectable so -nodisplay tests never block on input():
    %     config.promptFcn = @(msg) '42.0'   % returns the operator's answer

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        promptFcn_ = []
        zUm_       = NaN   % last confirmed position
        log_       = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if nargin < 2 || isempty(config)
                config = struct();
            end
            if isfield(config, 'promptFcn') && ~isempty(config.promptFcn)
                if ~isa(config.promptFcn, 'function_handle')
                    error('tfp:hardware:ManualZStage:badPromptFcn', ...
                        'promptFcn must be a function handle.');
                end
                obj.promptFcn_ = config.promptFcn;
            else
                obj.promptFcn_ = @(msg) input(msg, 's');
            end
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function moveToUm(obj, zUm)
            obj.requireInitialized('moveToUm');
            answer = obj.promptFcn_(sprintf( ...
                ['[ManualZStage] Move the objective to z = %.2f um, ' ...
                 'then press Enter (or type the achieved reading): '], ...
                double(zUm)));
            if isempty(answer)
                obj.zUm_ = double(zUm);
            else
                v = str2double(answer);
                if isnan(v)
                    error('tfp:hardware:ManualZStage:badReading', ...
                        'Could not parse "%s" as a z reading (um).', answer);
                end
                obj.zUm_ = v;
            end
            obj.logEvent('moveToUm', struct('requestedUm', double(zUm), ...
                'confirmedUm', obj.zUm_));
        end

        function zUm = getPositionUm(obj)
            obj.requireInitialized('getPositionUm');
            if ~isnan(obj.zUm_)
                zUm = obj.zUm_;
                return
            end
            answer = obj.promptFcn_( ...
                '[ManualZStage] Type the current z reading (um): ');
            zUm = str2double(answer);
            if isnan(zUm)
                error('tfp:hardware:ManualZStage:badReading', ...
                    'Could not parse "%s" as a z reading (um).', answer);
            end
            obj.zUm_ = zUm;
        end

        function moveRelativeUm(obj, dzUm)
            obj.moveToUm(obj.getPositionUm() + double(dzUm));
        end

        function status = getStatus(obj)
            status.zUm    = obj.zUm_;
            status.manual = true;
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
                error('tfp:hardware:ManualZStage:notInitialized', ...
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
