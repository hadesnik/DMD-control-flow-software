classdef BaslerSubstageCamera < tfp.hardware.SubstageCamera
    %BaslerSubstageCamera Basler acA2500-14um USB3 Vision camera via MATLAB Image Acquisition Toolbox.
    %   Uses the 'gentl' adaptor (GenICam GenTL). Requires MATLAB Image
    %   Acquisition Toolbox and Basler pylon 6+ with the pylon GenTL Producer
    %   installed (pylon Software Suite for Windows, USB3 Vision transport layer).
    %
    %   Config fields:
    %     .deviceId    - integer from imaqhwinfo('gentl'); default 1
    %     .format      - GenICam format string; default 'Mono8'
    %     .exposureMs  - exposure time in ms; default 10
    %     .gain        - analog gain in dB; default 0 (minimum)
    %
    %   Physical sensor (acA2500-14um): 2592 x 1944 pixels, 2.2 um pitch.
    %   nRows/nCols are read back from the adaptor after open so they
    %   reflect any ROI or binning configured on the camera.

    properties (SetAccess = protected)
        nRows         = 1944;
        nCols         = 2592;
        isInitialized = false;
    end

    properties (Access = private)
        vid_    = []   % videoinput object
        src_    = []   % getselectedsource handle
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:BaslerSubstageCamera:badConfig', ...
                    'config must be a struct.');
            end

            deviceId   = configField(config, 'deviceId',   1);
            formatStr  = configField(config, 'format',     'Mono8');
            exposureMs = configField(config, 'exposureMs', 10);
            gain       = configField(config, 'gain',       0);

            % Release any stale videoinput objects (prevents "device in use" errors).
            existingObjs = imaqfind;
            if ~isempty(existingObjs)
                delete(existingObjs);
            end

            try
                obj.vid_ = videoinput('gentl', deviceId, formatStr);
            catch ME
                error('tfp:hardware:BaslerSubstageCamera:openFailed', ...
                    'Could not open Basler camera (gentl, device %d, format %s). Check pylon GenTL Producer is installed. %s', ...
                    deviceId, formatStr, ME.message);
            end

            obj.src_ = getselectedsource(obj.vid_);

            % ExposureTime in us (GenICam standard on Basler cameras).
            % Older firmware exposes it as ExposureTimeAbs; try both.
            try
                obj.src_.ExposureTime = exposureMs * 1e3;
            catch
                try
                    obj.src_.ExposureTimeAbs = exposureMs * 1e3;
                catch
                    warning('tfp:hardware:BaslerSubstageCamera:exposureNotSet', ...
                        'Could not set ExposureTime - using camera default.');
                end
            end

            % Gain in dB; older firmware uses integer GainRaw.
            try
                obj.src_.Gain = gain;
            catch
                try
                    obj.src_.GainRaw = gain;
                catch
                    warning('tfp:hardware:BaslerSubstageCamera:gainNotSet', ...
                        'Could not set Gain - using camera default.');
                end
            end

            % Snap mode: one frame per software trigger.
            obj.vid_.FramesPerTrigger = 1;
            triggerconfig(obj.vid_, 'manual');

            % Read back actual dimensions (respects any pre-set ROI or binning).
            info      = imaqhwinfo(obj.vid_);
            obj.nRows = info.MaxHeight;
            obj.nCols = info.MaxWidth;

            obj.isInitialized = true;
        end

        function frame = snap(obj)
            obj.assertInitialized();
            obj.vid_.FramesPerTrigger = 1;
            triggerconfig(obj.vid_, 'manual');
            start(obj.vid_);
            trigger(obj.vid_);
            raw   = getdata(obj.vid_, 1);   % nRows x nCols x 1 x 1
            stop(obj.vid_);
            frame = obj.toDouble(raw);
        end

        function startLive(obj)
            obj.assertInitialized();
            obj.vid_.FramesPerTrigger = Inf;
            triggerconfig(obj.vid_, 'immediate');
            start(obj.vid_);
        end

        function stopLive(obj)
            if ~isempty(obj.vid_) && isvalid(obj.vid_)
                stop(obj.vid_);
            end
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

        function cleanup(obj)
            if ~isempty(obj.vid_) && isvalid(obj.vid_)
                stop(obj.vid_);
                delete(obj.vid_);
            end
            obj.vid_          = [];
            obj.src_          = [];
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

        function frame = toDouble(~, raw)
            raw = raw(:,:,1,1);
            if isinteger(raw)
                frame = double(raw) / double(intmax(class(raw)));
            else
                frame = double(raw);
            end
        end
    end
end

% ---------------------------------------------------------------------------
function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
