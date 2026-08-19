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

    %   RUNTIME CONTROLS. Exposure, gain, binning, ROI and pixel format are
    %   declared below as CONCRETE methods that throw :notSupported by default,
    %   NOT as abstract methods. Adding an abstract method would break
    %   construction of every existing subclass — MockSubstageCamera,
    %   BaslerSubstageCamera, SubstageCamera_generic, and any subclass in the
    %   sibling read-only consumer repo — with a confusing "abstract method not
    %   implemented" error. Concrete-with-default is purely additive: old
    %   subclasses keep working, and callers feature-detect via
    %   getCapabilities() rather than by class name.
    %
    %   These are DEVICE controls only. Frame averaging beyond snapAveraged,
    %   dark subtraction, autoscale, saturation masking, histograms and line
    %   profiles are image math, not device API, and live in
    %   tfp.gui.FrameProcessor where they are testable without a camera.

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

    % =====================================================================
    % Optional runtime controls. Default implementations refuse; subclasses
    % that can honour a control override it AND advertise it in
    % getCapabilities.
    % =====================================================================
    methods
        function caps = getCapabilities(~)
            %getCapabilities Which runtime controls this backend honours.
            %   A struct of logical flags. Callers must branch on these rather
            %   than on the class name.
            caps = struct( ...
                'exposure',       false, ...
                'gain',           false, ...
                'binning',        false, ...
                'roi',            false, ...
                'pixelFormat',    false, ...
                'exposureLimits', false, ...
                'bitDepth',       false);
        end

        function setExposureMs(obj, ~)
            obj.notSupported('setExposureMs');
        end

        function ms = getExposureMs(obj)
            obj.notSupported('getExposureMs');
            ms = NaN;
        end

        function lim = getExposureLimitsMs(obj)
            %getExposureLimitsMs [min max] in ms, queried from the device.
            obj.notSupported('getExposureLimitsMs');
            lim = [NaN NaN];
        end

        function setGain(obj, ~)
            obj.notSupported('setGain');
        end

        function g = getGain(obj)
            obj.notSupported('getGain');
            g = NaN;
        end

        function setBinning(obj, ~)
            obj.notSupported('setBinning');
        end

        function n = getBinning(obj)
            obj.notSupported('getBinning');
            n = NaN;
        end

        function setRoi(obj, ~)
            obj.notSupported('setRoi');
        end

        function roi = getRoi(obj)
            %getRoi [x y width height], 1-indexed.
            roi = [1, 1, obj.nCols, obj.nRows];
        end

        function resetRoi(obj)
            obj.notSupported('resetRoi');
        end

        function setPixelFormat(obj, ~)
            obj.notSupported('setPixelFormat');
        end

        function f = getPixelFormat(obj)
            obj.notSupported('getPixelFormat');
            f = '';
        end

        function nBits = getBitDepth(~)
            %getBitDepth Significant bits per pixel of the current format.
            %   Default 8. Overriding this matters: snap() normalises by
            %   2^nBits - 1, and a 12-bit frame divided by 65535 comes back
            %   16x too dim — precisely the mode wanted for faint 2p signal.
            nBits = 8;
        end

        function frame = snapAveraged(obj, n)
            %snapAveraged Mean of n snap() frames.
            %   Concrete and hardware-free: sqrt(n) read-noise reduction for
            %   free, which is the cheapest real gain available when imaging
            %   2p-excited fluorescence from a thin film.
            if nargin < 2 || isempty(n), n = 1; end
            if ~isnumeric(n) || ~isscalar(n) || ~isfinite(n) || n < 1 || mod(n, 1) ~= 0
                error('tfp:hardware:SubstageCamera:badAverageCount', ...
                    'n must be a positive integer; got %s.', mat2str(n));
            end
            frame = obj.snap();
            for k = 2:n
                frame = frame + obj.snap();
            end
            frame = frame / double(n);
        end
    end

    methods (Access = protected)
        function notSupported(obj, what)
            error('tfp:hardware:SubstageCamera:notSupported', ...
                ['%s is not supported by %s. Check getCapabilities() before ' ...
                 'calling a runtime control.'], what, class(obj));
        end
    end
end
