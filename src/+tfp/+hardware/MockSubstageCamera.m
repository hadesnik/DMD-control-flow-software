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
    %   Defocus-blur model (z-calibration mock; all optional — with none of
    %   these set, behaviour is identical to the pre-3D camera):
    %     .slm          — handle with getCurrentDefocusUm() (MockSLM)
    %     .zstage       — tfp.hardware.ZStage handle (objective z, um)
    %     .slmUmPerCmd  — TRUTH slope: um of focal shift per commanded
    %                     defocus um (default 1.0). calibrateSlmDefocus
    %                     must recover this.
    %     .filmZUm      — z of the fluorescent film (default 0)
    %     .zRUm         — blur "Rayleigh range" (default 10): the spot
    %                     sigma grows as sigma0*sqrt(1+(dEff/zR)^2) with
    %                     dEff = slmUmPerCmd*dzCmd - (zStage - filmZUm),
    %                     so best focus sits at zStage = filmZUm +
    %                     slmUmPerCmd*dzCmd. Peak drops as 1/(1+(dEff/zR)^2)
    %                     (energy conservation).
    %
    %   See also tfp.calibration.alignDMDtoCamera,
    %   tfp.calibration.throughFocusSweep.

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
        scanRect_     = []   % [x1 y1 width height] 1-indexed px; renders scan rectangle
        lastFrame_    = []
        % Defocus-blur model refs (z-calibration mock; [] = disabled)
        slm_          = []
        zstage_       = []
        slmUmPerCmd_  = 1.0
        filmZUm_      = 0
        zRUm_         = 10
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
            if isfield(config, 'slm'),    obj.slm_    = config.slm;    end
            if isfield(config, 'zstage'), obj.zstage_ = config.zstage; end
            obj.slmUmPerCmd_ = configField(config, 'slmUmPerCmd', 1.0);
            obj.filmZUm_     = configField(config, 'filmZUm',     0);
            obj.zRUm_        = configField(config, 'zRUm',        10);
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
            obj.isInitialized = false;
            obj.dmd_          = [];
            obj.truthAffine_  = [];
            obj.scanRect_     = [];
            obj.lastFrame_    = [];
            obj.slm_          = [];
            obj.zstage_       = [];
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function spot = gaussianSpot(obj, cx, cy)
            [cols, rows] = meshgrid(1:obj.nCols, 1:obj.nRows);
            % Defocus blur: widen sigma + drop peak by the effective
            % defocus between the excitation focus and the film.
            dEff = obj.effectiveDefocusUm();
            grow = 1 + (dEff / obj.zRUm_)^2;
            s    = obj.spotSigmaPx_ * sqrt(grow);
            amp  = 1 / grow;
            spot = amp * exp(-((cols - cx).^2 + (rows - cy).^2) / (2 * s^2));
        end

        function dEff = effectiveDefocusUm(obj)
            %effectiveDefocusUm Excitation focus minus film plane (um).
            dEff = 0;
            dzCmd = 0;
            if ~isempty(obj.slm_)
                dzCmd = obj.slm_.getCurrentDefocusUm();
                if isnan(dzCmd), dzCmd = 0; end
            end
            zPos = obj.filmZUm_;
            if ~isempty(obj.zstage_)
                zPos = obj.zstage_.getPositionUm();
            end
            dEff = obj.slmUmPerCmd_ * dzCmd - (zPos - obj.filmZUm_);
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
