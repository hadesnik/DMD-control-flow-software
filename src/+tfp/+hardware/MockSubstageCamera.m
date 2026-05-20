classdef MockSubstageCamera < tfp.hardware.SubstageCamera
    %MockSubstageCamera Simulated substage camera for pre-hardware calibration testing.
    %   snap() returns a synthetic image: Gaussian noise background plus a
    %   rendered Gaussian spot whose position is derived from the currently
    %   active DMD pattern (via a supplied truth affine). If no DMD reference
    %   is provided, snap() returns pure noise.
    %
    %   Configure by passing a struct to initialize():
    %     .nRows          — sensor height (default 512)
    %     .nCols          — sensor width (default 512)
    %     .noiseLevel     — background noise amplitude in [0,1] (default 0.05)
    %     .spotSigmaPx    — Gaussian spot sigma in camera pixels (default 4)
    %     .dmd            — tfp.hardware.MockDMD handle (optional)
    %     .truthAffine    — 3x3 affine, DMD [col,row] → camera [x,y] (optional;
    %                       required if dmd is set)
    %
    %   See also tfp.calibration.alignDMDtoCamera.

    properties (SetAccess = protected)
        nRows         = []
        nCols         = []
        isInitialized = false
    end

    properties (Access = private)
        dmd_          = []
        truthAffine_  = []
        noiseLevel_   = 0.05
        spotSigmaPx_  = 4
        lastFrame_    = []
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MockSubstageCamera:badConfig', ...
                    'config must be a struct.');
            end

            obj.nRows        = configField(config, 'nRows',       512);
            obj.nCols        = configField(config, 'nCols',       512);
            obj.noiseLevel_  = configField(config, 'noiseLevel',  0.05);
            obj.spotSigmaPx_ = configField(config, 'spotSigmaPx', 4);

            if isfield(config, 'dmd')
                obj.dmd_ = config.dmd;
            end
            if isfield(config, 'truthAffine')
                A = config.truthAffine;
                if ~isnumeric(A) || ~isequal(size(A), [3 3])
                    error('tfp:hardware:MockSubstageCamera:badAffine', ...
                        'truthAffine must be a 3x3 numeric matrix.');
                end
                obj.truthAffine_ = A;
            end

            obj.isInitialized = true;
            obj.lastFrame_    = [];
            obj.logEvent('initialize', config);
        end

        function frame = snap(obj)
            %snap Return a synthetic camera frame.
            %   Background is Gaussian noise. If a DMD and truthAffine were
            %   supplied at initialize(), the currently active DMD pattern
            %   centroid is transformed to camera space and a Gaussian spot
            %   is added at that position.
            if ~obj.isInitialized
                error('tfp:hardware:MockSubstageCamera:notInitialized', ...
                    'initialize() must be called before snap().');
            end

            frame = obj.noiseLevel_ * rand(obj.nRows, obj.nCols);

            if ~isempty(obj.dmd_) && ~isempty(obj.truthAffine_)
                pattern = obj.dmd_.getActivePattern();
                if ~isempty(pattern)
                    % Find the centroid of the active DMD pattern (spot centre).
                    [rowIdx, colIdx] = find(pattern);
                    if ~isempty(rowIdx)
                        dmdCol = mean(colIdx);
                        dmdRow = mean(rowIdx);
                        p = obj.truthAffine_ * [dmdCol; dmdRow; 1];
                        camX = p(1);   % camera column (x)
                        camY = p(2);   % camera row (y)
                        frame = frame + obj.gaussianSpot(camX, camY);
                    end
                end
            end

            frame       = min(max(frame, 0), 1);   % clip to [0,1]
            obj.lastFrame_ = frame;
            obj.logEvent('snap', struct('hasDmdRef', ~isempty(obj.dmd_)));
        end

        function startLive(obj)
            obj.logEvent('startLive', []);
        end

        function stopLive(obj)
            obj.logEvent('stopLive', []);
        end

        function frame = getFrame(obj)
            if isempty(obj.lastFrame_)
                frame = obj.snap();
            else
                frame = obj.lastFrame_;
            end
        end

        function cleanup(obj)
            obj.isInitialized = false;
            obj.dmd_          = [];
            obj.truthAffine_  = [];
            obj.lastFrame_    = [];
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function spot = gaussianSpot(obj, cx, cy)
            [cols, rows] = meshgrid(1:obj.nCols, 1:obj.nRows);
            s   = obj.spotSigmaPx_;
            spot = exp(-((cols - cx).^2 + (rows - cy).^2) / (2 * s^2));
        end

        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end
    end
end

% --- Local helper ---

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
