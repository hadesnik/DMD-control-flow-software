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
    %     .zStage         — tfp.hardware.ZStage handle (optional; enables Z-aware
    %                       rendering for focal-plane-tilt testing)
    %     .truthTiltPlane — [a b z0]: best-focus Z (µm) = z0 + a*(col-cx) + b*(row-cy)
    %                       in DMD coords. When set with zStage, the rendered spot's
    %                       brightness peaks and sigma minimises on this tilted plane.
    %     .focusWaistZUm  — axial brightness falloff (µm, default 5)
    %     .zRayleighUm    — axial sigma-broadening scale (µm, default 8)
    %
    %   See also tfp.calibration.alignDMDtoCamera, tfp.calibration.measureFocalPlaneTilt.

    properties (SetAccess = protected)
        nRows         = []
        nCols         = []
        isInitialized = false
    end

    properties (Access = private)
        dmd_            = []
        truthAffine_    = []
        noiseLevel_     = 0.05
        spotSigmaPx_    = 4
        scanRect_       = []   % [x1 y1 width height] 1-indexed px; renders scan rectangle
        lastFrame_      = []
        zStage_         = []   % optional tfp.hardware.ZStage handle (Z-aware rendering)
        truthTiltPlane_ = []   % [a b z0]: best-focus Z (µm) = z0 + a*(col-cx) + b*(row-cy)
        focusWaistZUm_  = 5    % axial brightness falloff (µm)
        zRayleighUm_    = 8    % axial sigma-broadening scale (µm)
        log_            = struct('timestamp', {}, 'eventType', {}, 'payload', {})
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
            if isfield(config, 'scanRect')
                r = config.scanRect;
                if ~isnumeric(r) || numel(r) ~= 4 || any(r < 1)
                    error('tfp:hardware:MockSubstageCamera:badScanRect', ...
                        'scanRect must be [x1 y1 width height] with all values >= 1.');
                end
                obj.scanRect_ = r(:)';
            end
            if isfield(config, 'truthAffine')
                A = config.truthAffine;
                if ~isnumeric(A) || ~isequal(size(A), [3 3])
                    error('tfp:hardware:MockSubstageCamera:badAffine', ...
                        'truthAffine must be a 3x3 numeric matrix.');
                end
                obj.truthAffine_ = A;
            end
            if isfield(config, 'zStage')
                obj.zStage_ = config.zStage;
            end
            if isfield(config, 'truthTiltPlane')
                p = config.truthTiltPlane;
                if ~isnumeric(p) || numel(p) ~= 3
                    error('tfp:hardware:MockSubstageCamera:badTiltPlane', ...
                        'truthTiltPlane must be [a b z0].');
                end
                obj.truthTiltPlane_ = p(:)';
            end
            obj.focusWaistZUm_ = configField(config, 'focusWaistZUm', 5);
            obj.zRayleighUm_   = configField(config, 'zRayleighUm',   8);

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

                        % Z-aware rendering: if a ZStage + tilt plane are set,
                        % modulate brightness/sigma by the defocus dz = stage Z
                        % minus the best-focus Z at this spot (tilted plane).
                        amp        = 1;
                        sigmaScale = 1;
                        if ~isempty(obj.zStage_) && ~isempty(obj.truthTiltPlane_)
                            cx = size(pattern, 2) / 2;   % DMD centre (col)
                            cy = size(pattern, 1) / 2;   % DMD centre (row)
                            a  = obj.truthTiltPlane_(1);
                            b  = obj.truthTiltPlane_(2);
                            z0 = obj.truthTiltPlane_(3);
                            zFocus = z0 + a*(dmdCol - cx) + b*(dmdRow - cy);
                            dz = obj.zStage_.getPosition() - zFocus;
                            amp        = exp(-dz^2 / (2 * obj.focusWaistZUm_^2));
                            sigmaScale = sqrt(1 + (dz / obj.zRayleighUm_)^2);
                        end
                        frame = frame + obj.gaussianSpot(camX, camY, amp, sigmaScale);
                    end
                end
            end

            if ~isempty(obj.scanRect_)
                x1 = max(1, round(obj.scanRect_(1)));
                y1 = max(1, round(obj.scanRect_(2)));
                x2 = min(obj.nCols, round(obj.scanRect_(1) + obj.scanRect_(3) - 1));
                y2 = min(obj.nRows, round(obj.scanRect_(2) + obj.scanRect_(4) - 1));
                if x2 >= x1 && y2 >= y1
                    frame(y1:y2, x1:x2) = 0.8 + 0.1 * rand(y2-y1+1, x2-x1+1);
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
            obj.isInitialized   = false;
            obj.dmd_            = [];
            obj.truthAffine_    = [];
            obj.scanRect_       = [];
            obj.lastFrame_      = [];
            obj.zStage_         = [];
            obj.truthTiltPlane_ = [];
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function spot = gaussianSpot(obj, cx, cy, amp, sigmaScale)
            if nargin < 4 || isempty(amp),        amp = 1;        end
            if nargin < 5 || isempty(sigmaScale), sigmaScale = 1; end
            [cols, rows] = meshgrid(1:obj.nCols, 1:obj.nRows);
            s   = obj.spotSigmaPx_ * sigmaScale;
            spot = amp * exp(-((cols - cx).^2 + (rows - cy).^2) / (2 * s^2));
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
