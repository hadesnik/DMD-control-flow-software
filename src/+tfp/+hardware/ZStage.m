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
end
