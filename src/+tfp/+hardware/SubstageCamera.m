classdef SubstageCamera < handle
    %SubstageCamera Abstract base for a substage widefield camera.
    %   The substage camera is a separate widefield detector used for
    %   DMD spatial calibration. It is NOT ScanImage: ScanImage uses a PMT
    %   point detector and cannot image DMD illumination spots. This camera
    %   views the sample from below (trans-illumination or epi-fluorescence)
    %   and captures a full field image for each projected DMD pattern.
    %
    %   Minimum interface required by tfp.calibration.alignDMDtoCamera.
    %
    %   See ARCHITECTURE.md "+tfp.+hardware".

    properties (Abstract, SetAccess = protected)
        nRows           % sensor height in pixels
        nCols           % sensor width in pixels
        isInitialized
    end

    methods (Abstract)
        initialize(obj, config)
            % config is a struct; subclass defines required fields.

        frame = snap(obj)
            % Blocking single-frame acquisition. Returns double(nRows, nCols),
            % intensity in arbitrary units (subclass normalises if needed).

        startLive(obj)
            % Begin continuous acquisition (e.g. for interactive alignment).

        stopLive(obj)
            % Stop continuous acquisition.

        frame = getFrame(obj)
            % Return the most recently acquired frame without triggering a
            % new exposure. Behaviour during live mode is implementation-
            % defined (may block until the next frame arrives).

        cleanup(obj)
    end
end
