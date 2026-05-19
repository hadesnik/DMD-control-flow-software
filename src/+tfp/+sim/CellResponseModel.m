classdef CellResponseModel < handle
%CellResponseModel Simulated GCaMP-expressing cell for mock all-optical pipeline.
%   Models a single neuron's fluorescence response to patterned photostimulation.
%   The response amplitude scales with the fraction of the cell's DMD footprint
%   that is illuminated, then convolves the result with GCaMP6s kinetics to
%   produce a ΔF/F trace sampled at imaging frame timestamps.
%
%   Usage:
%     c = tfp.sim.CellResponseModel([col row], radiusDmd)
%     c = tfp.sim.CellResponseModel([col row], radiusDmd, 'amplitude', 1.5, ...)
%     trace = c.computeTrace(mask, frameTimestamps, stimOnsetSec, stimDurationSec)
%
%   See ARCHITECTURE.md "+tfp.+sim" and CLAUDE.md Phase 1.5 notes.

    properties
        positionDmd   % [col, row] DMD pixel coords, 1-indexed, top-left origin
        radiusDmd     % cell footprint radius in DMD pixels
        amplitude     % peak ΔF/F when stim is centred on cell (distance = 0)
        sigma         % Gaussian falloff σ in DMD pixels; FWHM = 2.355 × sigma
        aiChannel     % AI channel index (reserved for future patch-clamp mode)
        responseTag   % label string, e.g. 'cell_01'
    end

    methods
        function obj = CellResponseModel(positionDmd, radiusDmd, varargin)
            %CellResponseModel Construct a mock cell response model.
            %
            %   CellResponseModel(positionDmd, radiusDmd)
            %   CellResponseModel(..., 'amplitude', 1.5,
            %                        'sigma',      10,
            %                        'aiChannel',   0,
            %                        'responseTag', 'cell')
            %
            %   positionDmd: [col row] in DMD pixels
            %   radiusDmd:   scalar, cell footprint radius in DMD pixels
            %   sigma:       Gaussian falloff std-dev (DMD px); default 10
            if ~isnumeric(positionDmd) || numel(positionDmd) ~= 2
                error('tfp:sim:CellResponseModel:badPosition', ...
                    'positionDmd must be a 2-element numeric [col row].');
            end
            if ~isnumeric(radiusDmd) || ~isscalar(radiusDmd) || ...
                    ~isfinite(radiusDmd) || radiusDmd <= 0
                error('tfp:sim:CellResponseModel:badRadius', ...
                    'radiusDmd must be a positive finite scalar.');
            end
            p = inputParser();
            addParameter(p, 'amplitude',   1.5);
            addParameter(p, 'sigma',       10);
            addParameter(p, 'aiChannel',   0);
            addParameter(p, 'responseTag', 'cell');
            parse(p, varargin{:});

            obj.positionDmd = double(positionDmd(:)');
            obj.radiusDmd   = double(radiusDmd);
            obj.amplitude   = double(p.Results.amplitude);
            obj.sigma       = double(p.Results.sigma);
            obj.aiChannel   = double(p.Results.aiChannel);
            obj.responseTag = char(p.Results.responseTag);
        end

        function trace = computeTrace(obj, patternMask, frameTimestamps, ...
                                       stimOnsetSec, stimDurationSec)
            %computeTrace Simulate a ΔF/F trace for this cell given a DMD pattern.
            %
            %   trace = computeTrace(obj, patternMask, frameTimestamps,
            %                        stimOnsetSec, stimDurationSec)
            %
            %   patternMask:     logical(nRows, nCols), active DMD pattern
            %   frameTimestamps: 1×T double, imaging frame times in seconds
            %   stimOnsetSec:    scalar, time of stim onset within the trial (s)
            %   stimDurationSec: scalar, stim on-duration (s); used to define the
            %                    rectangular drive waveform for convolution
            %
            %   Returns 1×T double trace in ΔF/F units.
            %   Peak amplitude equals obj.amplitude × overlap when fully illuminated.

            frameTimestamps = double(frameTimestamps(:)');  % enforce row vector
            T = numel(frameTimestamps);

            % --- Gaussian falloff: response scales with distance from stim centroid ---
            patternMask = logical(patternMask(:,:,1));  % take first slice if 3D
            [onRows, onCols] = find(patternMask);
            if isempty(onRows)
                scaledAmplitude = 0;
            else
                centroidCol = mean(onCols);
                centroidRow = mean(onRows);
                dist = sqrt((obj.positionDmd(1) - centroidCol).^2 + ...
                            (obj.positionDmd(2) - centroidRow).^2);
                scaledAmplitude = obj.amplitude * exp(-dist.^2 / (2 * obj.sigma.^2));
            end

            if scaledAmplitude < eps
                %ASSUMED baseline noise sigma = 0.10 dF/F units
                trace = randn(1, T) * 0.10;
                return;
            end

            % --- GCaMP6s alpha-function kernel ---
            %ASSUMED GCaMP6s kinetics: tau_rise=150ms, tau_decay=1500ms
            %   (Chen et al. 2013, Fig 1 for GCaMP6s in mouse V1)
            tRise  = 0.150;  % s
            tDecay = 1.500;  % s

            %ASSUMED convolution time resolution = 1ms (adequate for 150ms rise)
            dt   = 1e-3;
            tEnd = max(frameTimestamps) + 5 * tDecay;
            tConv = (0:dt:tEnd);

            % Stim: rectangular pulse from stimOnsetSec to stimOnsetSec+stimDurationSec
            stimPulse = double(tConv >= stimOnsetSec & ...
                               tConv <  (stimOnsetSec + stimDurationSec));

            % Alpha kernel: h(t) = exp(-t/tau_d) - exp(-t/tau_r), peak-normalised to 1
            tKernel  = (0:dt:(5 * tDecay));
            rawK     = exp(-tKernel / tDecay) - exp(-tKernel / tRise);
            rawK(rawK < 0) = 0;  % causal: negative lobe of alpha-fn is unphysical
            kernel   = rawK / max(rawK);  % normalise so peak = 1.0 per spec

            % Convolve (discrete approx. of continuous convolution, *dt for units)
            respConv = conv(stimPulse, kernel) * dt;
            respConv = respConv(1:numel(tConv));  % retain causal part only

            % Rescale so peak of computed response = scaledAmplitude
            % (makes amplitude independent of stimDurationSec)
            pkResp = max(respConv);
            if pkResp > eps
                respConv = respConv * (scaledAmplitude / pkResp);
            end

            % Sample at imaging frame timestamps via linear interpolation
            traceDet = interp1(tConv, respConv, frameTimestamps, 'linear', 0);

            %ASSUMED baseline noise sigma = 0.10 dF/F units
            trace = traceDet + randn(1, T) * 0.10;
        end
    end
end
