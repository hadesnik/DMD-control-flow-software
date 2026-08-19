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
    %   Field-tilt model (all optional; 0 = flat, so existing tests are
    %   unaffected):
    %     .tiltGradientUmPerUm — excitation-plane depth gradient along the
    %                     DISPERSION diagonal, um of focal shift per um of
    %                     sample-plane travel. The handoff's design value is
    %                     0.02929. Best focus at a field point therefore sits
    %                     at filmZUm + slmUmPerCmd*dzCmd + tilt(point), which
    %                     is exactly what tfp.calibration.measureFieldTilt
    %                     must recover.
    %     .tiltGrooveUmPerUm — same along the GROOVE diagonal (expected ~0;
    %                     a large fitted value means the tilt is not along the
    %                     dispersion axis at all).
    %     .dmdSize      — [nRows nCols] of the chip the tilt is computed on
    %                     (default: taken from the .dmd handle when present).
    %
    %   Runtime controls (exposure, gain, binning, ROI, pixel format) are
    %   implemented so headless tests can exercise the same code paths the GUI
    %   drives. Binning here defaults to AVERAGE mode, unlike a real Basler
    %   which defaults to SUM — averaging keeps the [0,1] scale intact so a
    %   test can see the noise drop without everything saturating. Set
    %   .binningMode = 'sum' for the hardware-like behaviour.
    %
    %   See also tfp.calibration.alignDMDtoCamera,
    %   tfp.calibration.throughFocusSweep, tfp.calibration.measureFieldTilt.

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
        tiltDisp_     = 0     % um focal shift per um along the dispersion axis
        tiltGroove_   = 0     % ... along the groove axis
        dmdSize_      = []    % [nRows nCols]; from the dmd handle when absent
        % runtime controls
        baseRows_     = 512
        baseCols_     = 512
        refExposureMs_ = 10
        exposureMs_   = 10
        gainDb_       = 0
        binning_      = 1
        binningMode_  = 'average'
        roi_          = []    % [x y w h] on the UNBINNED sensor; [] = full
        format_       = 'Mono8'
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MockSubstageCamera:badConfig', ...
                    'config must be a struct.');
            end

            obj.baseRows_    = configField(config, 'nRows',       512);
            obj.baseCols_    = configField(config, 'nCols',       512);
            obj.noiseLevel_  = configField(config, 'noiseLevel',  0.05);
            obj.spotSigmaPx_ = configField(config, 'spotSigmaPx', 4);

            obj.tiltDisp_    = configField(config, 'tiltGradientUmPerUm', 0);
            obj.tiltGroove_  = configField(config, 'tiltGrooveUmPerUm',   0);
            obj.dmdSize_     = configField(config, 'dmdSize',             []);

            obj.refExposureMs_ = configField(config, 'exposureMs', 10);
            obj.exposureMs_    = obj.refExposureMs_;
            obj.gainDb_        = configField(config, 'gain',        0);
            obj.binning_       = configField(config, 'binning',     1);
            obj.binningMode_   = char(configField(config, 'binningMode', 'average'));
            obj.format_        = char(configField(config, 'format',  'Mono8'));
            obj.roi_           = configField(config, 'roi',         []);

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
            obj.refreshGeometry_();
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

            % Render on the full sensor first, then apply ROI, then binning:
            % the optical image does not know about the readout window.
            frame = obj.noiseLevel_ * rand(obj.baseRows_, obj.baseCols_);

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
                        frame = frame + obj.gaussianSpot(camX, camY, dmdCol, dmdRow, ...
                            size(pattern));
                    end
                end
            end

            if ~isempty(obj.scanRect_)
                x1 = max(1, round(obj.scanRect_(1)));
                y1 = max(1, round(obj.scanRect_(2)));
                x2 = min(obj.baseCols_, round(obj.scanRect_(1) + obj.scanRect_(3) - 1));
                y2 = min(obj.baseRows_, round(obj.scanRect_(2) + obj.scanRect_(4) - 1));
                if x2 >= x1 && y2 >= y1
                    frame(y1:y2, x1:x2) = 0.8 + 0.1 * rand(y2-y1+1, x2-x1+1);
                end
            end

            % Exposure and gain act on the collected signal, as they do on a
            % real sensor: doubling exposure doubles the electrons.
            frame = frame * (obj.exposureMs_ / obj.refExposureMs_) * 10^(obj.gainDb_ / 20);

            frame = obj.applyRoi_(frame);
            frame = obj.applyBinning_(frame);
            frame = min(max(frame, 0), 1);   % clip to [0,1] (saturation)
            frame = obj.quantise_(frame);
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

        % --- runtime controls -------------------------------------------
        function caps = getCapabilities(~)
            caps = struct('exposure', true, 'gain', true, 'binning', true, ...
                'roi', true, 'pixelFormat', true, 'exposureLimits', true, ...
                'bitDepth', true);
        end

        function setExposureMs(obj, ms)
            if ~isnumeric(ms) || ~isscalar(ms) || ~isfinite(ms) || ms <= 0
                error('tfp:hardware:MockSubstageCamera:badExposure', ...
                    'exposure must be a positive finite scalar in ms.');
            end
            lim = obj.getExposureLimitsMs();
            obj.exposureMs_ = min(max(ms, lim(1)), lim(2));
            obj.logEvent('setExposureMs', struct('exposureMs', obj.exposureMs_));
        end

        function ms  = getExposureMs(obj),        ms  = obj.exposureMs_;  end
        function lim = getExposureLimitsMs(~),    lim = [0.02, 1000];     end

        function setGain(obj, g)
            if ~isnumeric(g) || ~isscalar(g) || ~isfinite(g)
                error('tfp:hardware:MockSubstageCamera:badGain', ...
                    'gain must be a finite scalar.');
            end
            obj.gainDb_ = g;
            obj.logEvent('setGain', struct('gain', g));
        end

        function g = getGain(obj), g = obj.gainDb_; end

        function setBinning(obj, n)
            if ~isnumeric(n) || ~isscalar(n) || ~ismember(n, [1 2 4])
                error('tfp:hardware:MockSubstageCamera:badBinning', ...
                    'binning must be 1, 2 or 4; got %s.', mat2str(n));
            end
            obj.binning_ = n;
            obj.refreshGeometry_();
            obj.logEvent('setBinning', struct('binning', n));
        end

        function n = getBinning(obj), n = obj.binning_; end

        function setRoi(obj, roi)
            if ~isnumeric(roi) || numel(roi) ~= 4 || any(~isfinite(roi)) ...
                    || any(roi(3:4) < 1) || roi(1) < 1 || roi(2) < 1
                error('tfp:hardware:MockSubstageCamera:badRoi', ...
                    'roi must be [x y width height], 1-indexed, size >= 1.');
            end
            obj.roi_ = double(roi(:)');
            obj.refreshGeometry_();
            obj.logEvent('setRoi', struct('roi', obj.roi_));
        end

        function roi = getRoi(obj), roi = obj.effectiveRoi_(); end

        function resetRoi(obj)
            obj.roi_ = [];
            obj.refreshGeometry_();
            obj.logEvent('resetRoi', []);
        end

        function setPixelFormat(obj, fmt)
            obj.format_ = char(fmt);
            obj.logEvent('setPixelFormat', struct('format', obj.format_));
        end

        function f = getPixelFormat(obj), f = obj.format_; end

        function nBits = getBitDepth(obj)
            nBits = tfp.hardware.BaslerSubstageCamera.bitsForFormat(obj.format_);
        end
    end

    methods (Access = private)
        function spot = gaussianSpot(obj, cx, cy, dmdCol, dmdRow, patternSize)
            [cols, rows] = meshgrid(1:obj.baseCols_, 1:obj.baseRows_);
            % Defocus blur: widen sigma + drop peak by the effective
            % defocus between the excitation focus and the film.
            dEff = obj.effectiveDefocusUm(dmdCol, dmdRow, patternSize);
            grow = 1 + (dEff / obj.zRUm_)^2;
            s    = obj.spotSigmaPx_ * sqrt(grow);
            amp  = 1 / grow;
            spot = amp * exp(-((cols - cx).^2 + (rows - cy).^2) / (2 * s^2));
        end

        function dEff = effectiveDefocusUm(obj, dmdCol, dmdRow, patternSize)
            %effectiveDefocusUm Excitation focus minus film plane (um).
            dzCmd = 0;
            if ~isempty(obj.slm_)
                dzCmd = obj.slm_.getCurrentDefocusUm();
                if isnan(dzCmd), dzCmd = 0; end
            end
            zPos = obj.filmZUm_;
            if ~isempty(obj.zstage_)
                zPos = obj.zstage_.getPositionUm();
            end
            zTilt = obj.tiltOffsetUm(dmdCol, dmdRow, patternSize);
            dEff  = obj.slmUmPerCmd_ * dzCmd + zTilt - (zPos - obj.filmZUm_);
        end

        function zUm = tiltOffsetUm(obj, dmdCol, dmdRow, patternSize)
            %tiltOffsetUm Native excitation depth at a DMD field position.
            %   The excitation surface is a tilted plane along the chip
            %   diagonals (handoff section 5). Uses tfp.optics.dmdToDispersionUm
            %   rather than re-deriving the 45-degree mapping, which is the one
            %   place it is allowed to live.
            zUm = 0;
            if obj.tiltDisp_ == 0 && obj.tiltGroove_ == 0
                return
            end
            dmdSize = obj.dmdSize_;
            if isempty(dmdSize) && nargin >= 4 && numel(patternSize) >= 2
                dmdSize = patternSize(1:2);
            end
            if isempty(dmdSize)
                return
            end
            [xDisp, yGroove] = tfp.optics.dmdToDispersionUm( ...
                [dmdCol, dmdRow], dmdSize);
            zUm = obj.tiltDisp_ * xDisp + obj.tiltGroove_ * yGroove;
        end

        % --- runtime-control internals ---------------------------------
        function refreshGeometry_(obj)
            roi = obj.effectiveRoi_();
            obj.nCols = floor(roi(3) / obj.binning_);
            obj.nRows = floor(roi(4) / obj.binning_);
        end

        function roi = effectiveRoi_(obj)
            if isempty(obj.roi_)
                roi = [1, 1, obj.baseCols_, obj.baseRows_];
            else
                roi = obj.roi_;
            end
        end

        function frame = applyRoi_(obj, frame)
            if isempty(obj.roi_), return; end
            r  = obj.roi_;
            x1 = max(1, round(r(1)));
            y1 = max(1, round(r(2)));
            x2 = min(obj.baseCols_, x1 + round(r(3)) - 1);
            y2 = min(obj.baseRows_, y1 + round(r(4)) - 1);
            frame = frame(y1:y2, x1:x2);
        end

        function frame = applyBinning_(obj, frame)
            n = obj.binning_;
            if n <= 1, return; end
            nr = floor(size(frame, 1) / n);
            nc = floor(size(frame, 2) / n);
            frame = frame(1:nr*n, 1:nc*n);
            frame = reshape(frame, n, nr, n, nc);
            if strcmpi(obj.binningMode_, 'sum')
                frame = squeeze(sum(sum(frame, 1), 3));
            else
                frame = squeeze(mean(mean(frame, 1), 3));
            end
        end

        function frame = quantise_(obj, frame)
            levels = 2^obj.getBitDepth() - 1;
            frame  = round(frame * levels) / levels;
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
