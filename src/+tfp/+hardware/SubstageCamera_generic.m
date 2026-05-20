classdef SubstageCamera_generic < tfp.hardware.SubstageCamera
    %SubstageCamera_generic Placeholder for the real substage camera.
    %   Fill in the SDK calls below once the camera model is known.
    %   Most scientific cameras connect via one of:
    %     - MATLAB Image Acquisition Toolbox (videoinput / imaq)
    %       Common adaptors: 'winvideo', 'gentl' (GigE/USB3), 'dcam' (Hamamatsu)
    %     - Manufacturer SDK called via loadlibrary / calllib (like the ALP)
    %     - A vendor-supplied MATLAB wrapper (e.g. Thorlabs, PCO, Andor)
    %   The structure below assumes Image Acquisition Toolbox; adapt as needed.
    %
    %   Config fields (all required unless marked optional):
    %     .adaptorName   — IAT adaptor, e.g. 'gentl', 'winvideo', 'dcam'
    %     .deviceId      — integer device index from imaqhwinfo(adaptorName)
    %     .format        — format string, e.g. 'Mono16' (optional; uses default)
    %     .exposureMs    — exposure time in ms (optional)

    properties (SetAccess = protected)
        nRows         = []
        nCols         = []
        isInitialized = false
    end

    properties (Access = private)
        vid_    = []   % videoinput object
    end

    methods
        function initialize(obj, config)
            % TODO: replace body with real SDK initialisation.
            %
            % Example using Image Acquisition Toolbox:
            %
            %   adaptor = config.adaptorName;   % e.g. 'gentl'
            %   devId   = config.deviceId;
            %   if isfield(config, 'format')
            %       obj.vid_ = videoinput(adaptor, devId, config.format);
            %   else
            %       obj.vid_ = videoinput(adaptor, devId);
            %   end
            %   src = getselectedsource(obj.vid_);
            %   if isfield(config, 'exposureMs')
            %       src.ExposureTime = config.exposureMs * 1e3;  % µs on most GigE cameras
            %   end
            %   obj.vid_.TriggerRepeat = 0;
            %   triggerconfig(obj.vid_, 'manual');
            %   info      = imaqhwinfo(obj.vid_);
            %   obj.nRows = info.MaxHeight;
            %   obj.nCols = info.MaxWidth;
            %   obj.isInitialized = true;

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.initialize() is a placeholder. ' ...
                'Fill in SDK calls for the actual camera model.');
        end

        function frame = snap(obj)
            % TODO: trigger a single exposure and return the image.
            %
            % Example using Image Acquisition Toolbox:
            %
            %   start(obj.vid_);
            %   trigger(obj.vid_);
            %   raw   = getdata(obj.vid_, 1);    % nRows × nCols × 1 × 1
            %   stop(obj.vid_);
            %   frame = double(raw(:,:,1,1));
            %   frame = frame / double(intmax(class(raw)));  % normalise to [0,1]

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.snap() is a placeholder.');
        end

        function startLive(obj)
            % TODO: begin free-running acquisition for interactive alignment.
            %
            % Example:
            %   obj.vid_.FramesPerTrigger = Inf;
            %   triggerconfig(obj.vid_, 'immediate');
            %   start(obj.vid_);

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.startLive() is a placeholder.');
        end

        function stopLive(obj)
            % TODO:
            %   stop(obj.vid_);

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.stopLive() is a placeholder.');
        end

        function frame = getFrame(obj)
            % TODO: return the most recently acquired frame during live mode.
            %
            % Example:
            %   raw   = peekdata(obj.vid_, 1);
            %   frame = double(raw(:,:,1,1)) / double(intmax(class(raw)));

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.getFrame() is a placeholder.');
        end

        function cleanup(obj)
            % TODO: release the device.
            %
            % Example:
            %   if ~isempty(obj.vid_) && isvalid(obj.vid_)
            %       stop(obj.vid_);
            %       delete(obj.vid_);
            %   end
            %   obj.vid_          = [];
            %   obj.isInitialized = false;

            error('tfp:hardware:SubstageCamera_generic:notImplemented', ...
                'SubstageCamera_generic.cleanup() is a placeholder.');
        end
    end
end
