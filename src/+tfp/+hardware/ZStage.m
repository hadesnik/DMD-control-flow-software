classdef ZStage < handle
    %ZStage Abstract interface for the axial ground-truth ruler.
    %   The z-calibration (tfp.calibration.calibrateSlmDefocus /
    %   calibrateEtlPlanes) needs a commandable, readable objective-z axis
    %   in um. On this rig that is the Sutter MP-285 — currently serial on
    %   the imaging PC (RelayZStage via si_motor_helper), switchable to the
    %   DAQ PC via a manual serial switch box (MP285ZStage). ManualZStage
    %   keeps calibration unblocked with an operator turning the knob.
    %
    %   Convention: zUm increases toward deeper focus (same sign as the
    %   SLM defocus command convention, "positive = deeper into sample");
    %   z = 0 is wherever the axis was when the calibration started — all
    %   calibration fits use differences, never absolute stage positions.
    %   Which RAW stage direction is "deeper" depends on the mount: an
    %   objective-mount ruler (default rig) and a sample-mount ruler (spare
    %   MP-285 carrying slide + substage camera, objective fixed) map the
    %   same raw axis to OPPOSITE contract signs. MP285ZStage normalizes
    %   this via config zstage.direction_sign (bench-checked per mount).

    properties (Abstract, SetAccess = protected)
        isInitialized
    end

    methods (Abstract)
        initialize(obj, config)

        % Absolute move (um), BLOCKING until the stage has settled.
        moveToUm(obj, zUm)

        % Current position (um).
        zUm = getPositionUm(obj)

        % Relative move (um), blocking.
        moveRelativeUm(obj, dzUm)

        status = getStatus(obj)
        cleanup(obj)
    end

    methods
        function id = rulerId(obj)
            %rulerId Provenance string stamped into calibration structs
            %   (composeZCalibration warns when the SLM and ETL calibs were
            %   measured on different rulers). Backends with mount/sign/port
            %   variants override this to include them.
            id = class(obj);
        end
    end
end
