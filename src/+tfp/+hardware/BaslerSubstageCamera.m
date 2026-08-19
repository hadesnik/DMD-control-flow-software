classdef BaslerSubstageCamera < tfp.hardware.SubstageCamera
    %BaslerSubstageCamera Basler acA2500-14um USB3 Vision camera via the Image Acquisition Toolbox.
    %   Uses the 'gentl' adaptor (GenICam GenTL). Requires MATLAB Image
    %   Acquisition Toolbox and Basler pylon 6+ with the pylon GenTL Producer
    %   installed (pylon Software Suite for Windows, USB3 Vision transport layer).
    %
    %   Config fields:
    %     .deviceId    - integer from imaqhwinfo('gentl'); default 1
    %     .format      - GenICam format string; default 'Mono8'. 'Mono12' buys
    %                    four more bits of dynamic range, which matters because
    %                    the 2p-excited signal from a thin film is faint against
    %                    a non-zero background.
    %     .exposureMs  - exposure time in ms; default 10
    %     .gain        - analog gain in dB; default 0 (minimum)
    %     .binning     - 1 | 2 | 4; default 1. 2x2 gives 4x the signal per
    %                    pixel and, at 2.2 um sensor pitch against ~1.56 um/px
    %                    at the sample, costs essentially nothing for centroiding.
    %     .roi         - [x y width height], 1-indexed; default full sensor
    %
    %   Physical sensor (acA2500-14um): 2592 x 1944 pixels, 2.2 um pitch.
    %
    %   TWO MECHANICS worth knowing before editing this class:
    %
    %   1. videoinput properties such as ROIPosition are READ-ONLY while the
    %      object is running, so setRoi/setBinning stop acquisition, apply, call
    %      refreshGeometry_, then restore whatever live state was in force.
    %   2. Pixel format is a videoinput CONSTRUCTION argument. setPixelFormat
    %      therefore cannot mutate it — it tears the object down and
    %      re-initialises with the new format, preserving exposure, gain, ROI
    %      and binning. The imaqfind/delete sweep in initialize makes that safe.
    %
    %   TWO BUGS FIXED 2026-08-19, both of which corrupted calibration silently:
    %
    %   * GEOMETRY. nRows/nCols used to be read from imaqhwinfo(vid).MaxHeight /
    %     .MaxWidth, which are the SENSOR MAXIMA, not the current AOI. Any ROI
    %     or binning left the reported size disagreeing with the array snap()
    %     actually returns, so every affine fit was anchored to the wrong frame
    %     size. Geometry now comes from vid.ROIPosition.
    %   * BIT DEPTH. toDouble normalised by intmax(class(raw)). Mono12 arrives
    %     as uint16 with 12 significant bits, so intmax gave 65535 and every
    %     12-bit frame came back 16x too dim — exactly the mode you would reach
    %     for when the signal is faint. Normalisation now uses 2^bitDepth - 1.

    properties (SetAccess = protected)
        nRows         = 1944;
        nCols         = 2592;
        isInitialized = false;
    end

    properties (Access = private)
        vid_        = []      % videoinput object
        src_        = []      % getselectedsource handle
        deviceId_   = 1
        format_     = 'Mono8'
        exposureMs_ = 10
        gain_       = 0
        binning_    = 1
        wasLive_    = false
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:BaslerSubstageCamera:badConfig', ...
                    'config must be a struct.');
            end

            obj.deviceId_   = tfp.util.configField(config, 'deviceId',   1);
            obj.format_     = char(tfp.util.configField(config, 'format', 'Mono8'));
            obj.exposureMs_ = tfp.util.configField(config, 'exposureMs', 10);
            obj.gain_       = tfp.util.configField(config, 'gain',       0);
            requestedBin    = tfp.util.configField(config, 'binning',    1);
            requestedRoi    = tfp.util.configField(config, 'roi',        []);

            % Release any stale videoinput objects (prevents "device in use").
            existingObjs = imaqfind;
            if ~isempty(existingObjs)
                delete(existingObjs);
            end

            try
                obj.vid_ = videoinput('gentl', obj.deviceId_, obj.format_);
            catch ME
                error('tfp:hardware:BaslerSubstageCamera:openFailed', ...
                    ['Could not open Basler camera (gentl, device %d, format %s). ' ...
                     'Check the pylon GenTL Producer is installed. %s'], ...
                    obj.deviceId_, obj.format_, ME.message);
            end

            obj.src_ = getselectedsource(obj.vid_);

            obj.applyExposure_(obj.exposureMs_);
            obj.applyGain_(obj.gain_);

            % Snap mode: one frame per software trigger.
            obj.vid_.FramesPerTrigger = 1;
            triggerconfig(obj.vid_, 'manual');

            obj.isInitialized = true;

            if ~isempty(requestedBin) && requestedBin ~= 1
                obj.setBinning(requestedBin);
            else
                obj.binning_ = obj.readBinning_();
            end
            if ~isempty(requestedRoi)
                obj.setRoi(requestedRoi);
            else
                obj.refreshGeometry_();
            end
        end

        % --- capabilities ------------------------------------------------
        function caps = getCapabilities(~)
            caps = struct( ...
                'exposure',       true, ...
                'gain',           true, ...
                'binning',        true, ...
                'roi',            true, ...
                'pixelFormat',    true, ...
                'exposureLimits', true, ...
                'bitDepth',       true);
        end

        % --- acquisition --------------------------------------------------
        function frame = snap(obj)
            obj.assertInitialized();
            obj.vid_.FramesPerTrigger = 1;
            triggerconfig(obj.vid_, 'manual');
            start(obj.vid_);
            raw = getdata(obj.vid_, 1);   % nRows x nCols x 1 x 1
            stop(obj.vid_);
            frame = obj.toDouble(raw);
        end

        function startLive(obj)
            obj.assertInitialized();
            obj.vid_.FramesPerTrigger = Inf;
            triggerconfig(obj.vid_, 'immediate');
            start(obj.vid_);
            obj.wasLive_ = true;
        end

        function stopLive(obj)
            if ~isempty(obj.vid_) && isvalid(obj.vid_)
                stop(obj.vid_);
            end
            obj.wasLive_ = false;
        end

        function frame = getFrame(obj)
            obj.assertInitialized();
            raw = peekdata(obj.vid_, 1);
            if isempty(raw)
                frame = zeros(obj.nRows, obj.nCols);
                return;
            end
            frame = obj.toDouble(raw);
        end

        % --- exposure and gain --------------------------------------------
        function setExposureMs(obj, ms)
            obj.assertInitialized();
            if ~isnumeric(ms) || ~isscalar(ms) || ~isfinite(ms) || ms <= 0
                error('tfp:hardware:BaslerSubstageCamera:badExposure', ...
                    'exposure must be a positive finite scalar in ms; got %s.', mat2str(ms));
            end
            obj.applyExposure_(ms);
        end

        function ms = getExposureMs(obj)
            obj.assertInitialized();
            ms = obj.exposureMs_;
            try
                ms = obj.src_.ExposureTime / 1e3;
            catch
                try, ms = obj.src_.ExposureTimeAbs / 1e3; catch, end
            end
        end

        function lim = getExposureLimitsMs(obj)
            %getExposureLimitsMs Real device limits, queried not guessed.
            obj.assertInitialized();
            lim = [NaN NaN];
            for name = {'ExposureTime', 'ExposureTimeAbs'}
                try
                    info = propinfo(obj.src_, name{1});
                    if ~isempty(info.ConstraintValue)
                        lim = double(info.ConstraintValue(:)') / 1e3;   % us -> ms
                        return
                    end
                catch
                end
            end
        end

        function setGain(obj, g)
            obj.assertInitialized();
            if ~isnumeric(g) || ~isscalar(g) || ~isfinite(g)
                error('tfp:hardware:BaslerSubstageCamera:badGain', ...
                    'gain must be a finite scalar; got %s.', mat2str(g));
            end
            obj.applyGain_(g);
        end

        function g = getGain(obj)
            obj.assertInitialized();
            g = obj.gain_;
            try
                g = obj.src_.Gain;
            catch
                try, g = obj.src_.GainRaw; catch, end
            end
        end

        % --- binning, ROI, format -----------------------------------------
        function setBinning(obj, n)
            obj.assertInitialized();
            if ~isnumeric(n) || ~isscalar(n) || ~ismember(n, [1 2 4])
                error('tfp:hardware:BaslerSubstageCamera:badBinning', ...
                    'binning must be 1, 2 or 4; got %s.', mat2str(n));
            end
            obj.withAcquisitionStopped(@() obj.applyBinning_(n));
        end

        function n = getBinning(obj)
            obj.assertInitialized();
            n = obj.readBinning_();
        end

        function setRoi(obj, roi)
            obj.assertInitialized();
            if ~isnumeric(roi) || numel(roi) ~= 4 || any(~isfinite(roi)) || any(roi(3:4) < 1)
                error('tfp:hardware:BaslerSubstageCamera:badRoi', ...
                    'roi must be [x y width height] with width/height >= 1.');
            end
            obj.withAcquisitionStopped(@() obj.applyRoi_(double(roi(:)')));
        end

        function roi = getRoi(obj)
            obj.assertInitialized();
            roi = double(obj.vid_.ROIPosition);
            roi(1:2) = roi(1:2) + 1;    % ROIPosition is 0-indexed; we report 1-indexed
        end

        function resetRoi(obj)
            obj.assertInitialized();
            info = imaqhwinfo(obj.vid_);
            obj.setRoi([1, 1, info.MaxWidth, info.MaxHeight]);
        end

        function setPixelFormat(obj, fmt)
            %setPixelFormat Re-open the device in a new format.
            %   Format is a videoinput construction argument, so this is a
            %   teardown and rebuild; exposure, gain, binning and ROI are
            %   carried across.
            obj.assertInitialized();
            fmt = char(fmt);
            if strcmp(fmt, obj.format_), return; end

            keep = struct('deviceId', obj.deviceId_, 'format', fmt, ...
                'exposureMs', obj.getExposureMs(), 'gain', obj.getGain(), ...
                'binning', obj.getBinning(), 'roi', obj.getRoi());
            wasLive = obj.wasLive_;
            obj.cleanup();
            obj.initialize(keep);
            if wasLive, obj.startLive(); end
        end

        function f = getPixelFormat(obj)
            f = obj.format_;
        end

        function nBits = getBitDepth(obj)
            nBits = tfp.hardware.BaslerSubstageCamera.bitsForFormat(obj.format_);
        end

        function cleanup(obj)
            if ~isempty(obj.vid_) && isvalid(obj.vid_)
                stop(obj.vid_);
                delete(obj.vid_);
            end
            obj.vid_          = [];
            obj.src_          = [];
            obj.wasLive_      = false;
            obj.isInitialized = false;
        end
    end

    % -----------------------------------------------------------------------
    methods (Access = private)

        function assertInitialized(obj)
            if ~obj.isInitialized
                error('tfp:hardware:BaslerSubstageCamera:notInitialized', ...
                    'initialize() must be called before use.');
            end
        end

        function applyExposure_(obj, ms)
            % ExposureTime is in us (GenICam standard on Basler cameras);
            % older firmware exposes it as ExposureTimeAbs. Try both.
            try
                obj.src_.ExposureTime = ms * 1e3;
            catch
                try
                    obj.src_.ExposureTimeAbs = ms * 1e3;
                catch
                    warning('tfp:hardware:BaslerSubstageCamera:exposureNotSet', ...
                        'Could not set ExposureTime - using camera default.');
                    return
                end
            end
            obj.exposureMs_ = ms;
        end

        function applyGain_(obj, g)
            % Gain in dB; older firmware uses integer GainRaw.
            try
                obj.src_.Gain = g;
            catch
                try
                    obj.src_.GainRaw = g;
                catch
                    warning('tfp:hardware:BaslerSubstageCamera:gainNotSet', ...
                        'Could not set Gain - using camera default.');
                    return
                end
            end
            obj.gain_ = g;
        end

        function applyBinning_(obj, n)
            ok = false;
            try
                obj.src_.BinningHorizontal = n;
                obj.src_.BinningVertical   = n;
                ok = true;
            catch
                warning('tfp:hardware:BaslerSubstageCamera:binningNotSet', ...
                    'Could not set BinningHorizontal/Vertical - using camera default.');
            end
            if ok
                obj.binning_ = n;
            end
            obj.refreshGeometry_();
        end

        function n = readBinning_(obj)
            n = obj.binning_;
            try
                n = double(obj.src_.BinningHorizontal);
            catch
            end
        end

        function applyRoi_(obj, roi)
            % ROIPosition is [x y width height] with a 0-indexed origin.
            obj.vid_.ROIPosition = [roi(1) - 1, roi(2) - 1, roi(3), roi(4)];
            obj.refreshGeometry_();
        end

        function refreshGeometry_(obj)
            %refreshGeometry_ Adopt the CURRENT AOI, not the sensor maxima.
            %   Must be called after every ROI, binning or format change, or
            %   the first such change reintroduces the geometry bug.
            try
                roi = double(obj.vid_.ROIPosition);   % [x y width height]
                obj.nCols = roi(3);
                obj.nRows = roi(4);
            catch
                info = imaqhwinfo(obj.vid_);
                obj.nRows = info.MaxHeight;
                obj.nCols = info.MaxWidth;
                warning('tfp:hardware:BaslerSubstageCamera:geometryFallback', ...
                    ['ROIPosition unavailable; fell back to sensor maxima ' ...
                     '%dx%d. If an ROI or binning is set, reported geometry ' ...
                     'is wrong and affine fits will be misanchored.'], ...
                    obj.nCols, obj.nRows);
            end
        end

        function withAcquisitionStopped(obj, fcn)
            %withAcquisitionStopped Apply a read-only-while-running property.
            wasLive = obj.wasLive_;
            if ~isempty(obj.vid_) && isvalid(obj.vid_) && isrunning(obj.vid_)
                stop(obj.vid_);
            end
            fcn();
            if wasLive
                obj.startLive();
            end
        end

        function frame = toDouble(obj, raw)
            raw = raw(:, :, 1, 1);
            if isinteger(raw)
                frame = double(raw) / (2^obj.getBitDepth() - 1);
            else
                frame = double(raw);
            end
        end
    end

    % -----------------------------------------------------------------------
    methods (Static)
        function nBits = bitsForFormat(fmt)
            %bitsForFormat Significant bits in a GenICam pixel-format string.
            %   Mono12 rides in a uint16 container with only 12 significant
            %   bits, so the container width is the wrong normaliser.
            tok = regexp(char(fmt), '(\d+)', 'tokens', 'once');
            if isempty(tok)
                nBits = 8;
            else
                nBits = str2double(tok{1});
            end
            if ~isfinite(nBits) || nBits < 1 || nBits > 32
                nBits = 8;
            end
        end
    end
end
