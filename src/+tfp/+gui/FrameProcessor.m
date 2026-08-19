classdef FrameProcessor
    %FrameProcessor Pure image math for the live camera display.
    %
    %   Static, stateless, graphics-free and hardware-free — so the entire
    %   display pipeline is testable under matlab -nodisplay while
    %   tfp.gui.CalibrationApp (which cannot be) stays a thin renderer.
    %
    %   WHY THESE OPERATIONS. Imaging 2p-excited fluorescence from a thin film
    %   or slab is photon-starved: the spot is faint, the background is not
    %   zero, and the failure mode at the bench is turning the exposure up
    %   until the centroid is a clipped plateau and the affine fit quietly
    %   degrades. Each method here exists to make one of those failures visible:
    %
    %     averageFrames    sqrt(N) read-noise reduction, free
    %     subtractDark     removes the non-zero pedestal that biases centroids
    %     autoscaleLimits  makes a dim spot visible without hand-tuning caxis
    %     saturationMask   shows clipping, the failure you cannot see by eye
    %     histogramCounts  shows whether you are photon- or read-noise-limited
    %     lineProfile      the focus metric an operator actually uses
    %     gaussianSigma    puts a number on that profile
    %     focusMetric      a single scalar to maximise while turning the focus
    %
    %   No Statistics or Image Processing Toolbox dependency: percentiles and
    %   line profiles are computed here rather than via prctile/improfile, so
    %   the live display works on a bare MATLAB install.
    %
    %   See also tfp.hardware.SubstageCamera, tfp.calibration.throughFocusSweep.

    methods (Static)

        function frame = averageFrames(frames)
            %averageFrames Mean across the 3rd dimension of a frame stack.
            if isempty(frames)
                error('tfp:gui:FrameProcessor:emptyStack', ...
                    'frames must be a non-empty array.');
            end
            frame = mean(double(frames), 3);
        end

        function frame = subtractDark(frame, dark)
            %subtractDark Subtract a dark/background frame, clamped at zero.
            %   Negative pixels are physically meaningless and drag centroids
            %   toward the frame centre, so they are clamped rather than kept.
            if isempty(dark)
                return
            end
            frame = double(frame);
            dark  = double(dark);
            if ~isequal(size(frame), size(dark))
                error('tfp:gui:FrameProcessor:darkSizeMismatch', ...
                    'dark frame is %s but the image is %s.', ...
                    mat2str(size(dark)), mat2str(size(frame)));
            end
            frame = max(frame - dark, 0);
        end

        function lims = autoscaleLimits(frame, pcts)
            %autoscaleLimits Display limits from percentiles of the frame.
            %   lims = autoscaleLimits(frame)              % [0.5 99.9]
            %   lims = autoscaleLimits(frame, [lo hi])
            %
            %   The high percentile is deliberately not 100: a handful of hot
            %   pixels would otherwise set the ceiling and black out the image.
            if nargin < 2 || isempty(pcts), pcts = [0.5 99.9]; end
            v = double(frame(:));
            v = v(isfinite(v));
            if isempty(v)
                lims = [0 1];
                return
            end
            lims = tfp.gui.FrameProcessor.percentile(v, pcts);
            if lims(2) <= lims(1)
                lims = [lims(1), lims(1) + max(eps, abs(lims(1)) * 1e-6)];
            end
        end

        function [mask, frac] = saturationMask(frame, options)
            %saturationMask Pixels at or above full scale.
            %   [mask, frac] = saturationMask(frame, options)
            %     options.fullScale  value counted as full scale (default 1,
            %                        matching the [0,1] normalisation the
            %                        SubstageCamera backends return)
            %     options.threshFrac fraction of full scale to count as
            %                        saturated (default 0.99 — a pixel one
            %                        count below the rail is already useless
            %                        for centroiding)
            if nargin < 2 || isempty(options), options = struct(); end
            fullScale  = tfp.util.configField(options, 'fullScale',  1);
            threshFrac = tfp.util.configField(options, 'threshFrac', 0.99);
            mask = double(frame) >= fullScale * threshFrac;
            frac = nnz(mask) / numel(mask);
        end

        function [counts, centres] = histogramCounts(frame, nBins, lims)
            %histogramCounts Intensity histogram over explicit limits.
            if nargin < 2 || isempty(nBins), nBins = 128; end
            v = double(frame(:));
            v = v(isfinite(v));
            if nargin < 3 || isempty(lims)
                if isempty(v)
                    lims = [0 1];
                else
                    lims = [min(v), max(v)];
                end
            end
            if lims(2) <= lims(1)
                lims(2) = lims(1) + eps;
            end
            edges   = linspace(lims(1), lims(2), nBins + 1);
            counts  = histcounts(v, edges);
            centres = edges(1:end-1) + diff(edges) / 2;
        end

        function [profile, distPx, coords] = lineProfile(frame, p1, p2, nSamples)
            %lineProfile Bilinear intensity profile along a segment.
            %   [profile, distPx, coords] = lineProfile(frame, [x1 y1], [x2 y2])
            %   Implemented with interp2 rather than improfile so the live
            %   display does not require the Image Processing Toolbox.
            if nargin < 4 || isempty(nSamples)
                nSamples = max(2, ceil(hypot(p2(1) - p1(1), p2(2) - p1(2))) + 1);
            end
            t  = linspace(0, 1, nSamples);
            xs = p1(1) + (p2(1) - p1(1)) * t;
            ys = p1(2) + (p2(2) - p1(2)) * t;
            profile = interp2(double(frame), xs, ys, 'linear', NaN);
            distPx  = t * hypot(p2(1) - p1(1), p2(2) - p1(2));
            coords  = [xs(:), ys(:)];
        end

        function [sigma, centre, amplitude] = gaussianSigma(profile, x)
            %gaussianSigma Background-subtracted intensity-weighted width.
            %   Moment-based rather than a nonlinear fit: no toolbox, no
            %   convergence failure mid-live-update, and for a focus readout
            %   the second moment is the quantity of interest anyway.
            profile = double(profile(:))';
            if nargin < 2 || isempty(x)
                x = 1:numel(profile);
            end
            x = double(x(:))';
            good = isfinite(profile) & isfinite(x);
            profile = profile(good);
            x       = x(good);
            if numel(profile) < 3
                sigma = NaN; centre = NaN; amplitude = NaN;
                return
            end
            w = profile - min(profile);          % subtract the pedestal
            s = sum(w);
            if s <= 0
                sigma = NaN; centre = NaN; amplitude = NaN;
                return
            end
            centre    = sum(w .* x) / s;
            sigma     = sqrt(max(0, sum(w .* (x - centre).^2) / s));
            amplitude = max(w);
        end

        function m = focusMetric(frame)
            %focusMetric Normalised-variance sharpness; larger is sharper.
            %   Normalising by the mean squared makes it insensitive to
            %   exposure, so the operator can turn the focus knob without the
            %   number moving for the wrong reason.
            v  = double(frame(:));
            v  = v(isfinite(v));
            mu = mean(v);
            if isempty(v) || mu <= 0
                m = 0;
                return
            end
            m = var(v) / mu^2;
        end

        function q = percentile(v, pcts)
            %percentile Linear-interpolated percentiles without a toolbox.
            v = sort(double(v(:)));
            n = numel(v);
            if n == 0
                q = nan(size(pcts));
                return
            end
            if n == 1
                q = repmat(v, size(pcts));
                return
            end
            % Midpoint convention: the k-th of n samples sits at (k-0.5)/n.
            pos = double(pcts(:))' / 100 * n + 0.5;
            pos = min(max(pos, 1), n);
            lo  = floor(pos);
            hi  = min(lo + 1, n);
            f   = pos - lo;
            q   = v(lo)' .* (1 - f) + v(hi)' .* f;
            q   = reshape(q, size(pcts));
        end
    end
end
