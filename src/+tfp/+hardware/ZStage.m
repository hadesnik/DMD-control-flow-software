classdef ZStage < handle
    %ZStage Abstract base for an axial (focus) stage.
    %   Moves the objective (or camera) along the optical axis, in microns.
    %   Used by tfp.calibration.measureFocalPlaneTilt to sweep focus and, in
    %   future, by measurePSF's axial path. Concrete subclasses:
    %     MockZStage   - in-memory simulation (development / tests)
    %     SutterZStage - real Sutter MP-285 / MP-285A over serial
    %
    %   Convention: positionUm increases in one physical direction (the rig /
    %   subclass defines the sign). The absolute origin is arbitrary — tilt is a
    %   slope, so relative moves are what matter.
    %
    %   See ARCHITECTURE.md "+tfp.+hardware".

    properties (Abstract, SetAccess = protected)
        isInitialized
    end

    properties (SetAccess = protected)
        positionUm = NaN            % last commanded/queried position (µm)
        rangeUm    = [-Inf, Inf]    % soft travel limits (µm), inclusive
    end

    methods (Abstract)
        initialize(obj, config)
            % config is a struct; subclass defines required fields.

        moveTo(obj, zUm)
            % Blocking: command an absolute move to zUm (µm) and return only
            % once the stage has settled.

        z = getPosition(obj)
            % Query and return the current axial position (µm).

        cleanup(obj)
    end

    methods
        function moveBy(obj, dzUm)
            %moveBy Move relative to the current position by dzUm microns.
            if ~isnumeric(dzUm) || ~isscalar(dzUm) || ~isfinite(dzUm)
                error('tfp:hardware:ZStage:badDelta', ...
                    'dzUm must be a finite scalar; got %s.', mat2str(dzUm));
            end
            obj.moveTo(obj.getPosition() + dzUm);
        end

        function tf = inRange(obj, zUm)
            %inRange True if zUm is within the soft travel limits.
            tf = zUm >= obj.rangeUm(1) && zUm <= obj.rangeUm(2);
        end
    end

    methods (Access = protected)
        function assertInRange_(obj, zUm)
            %assertInRange_ Throw if zUm is not a finite scalar within rangeUm.
            if ~isnumeric(zUm) || ~isscalar(zUm) || ~isfinite(zUm)
                error('tfp:hardware:ZStage:badTarget', ...
                    'target zUm must be a finite scalar; got %s.', mat2str(zUm));
            end
            if zUm < obj.rangeUm(1) || zUm > obj.rangeUm(2)
                error('tfp:hardware:ZStage:outOfRange', ...
                    'target z = %.3f µm is outside travel limits [%.3f, %.3f] µm.', ...
                    zUm, obj.rangeUm(1), obj.rangeUm(2));
            end
        end
    end
end
