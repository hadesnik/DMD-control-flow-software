function sweep = throughFocusSweep(camera, zstage, zPositionsUm, options)
%throughFocusSweep Step the z ruler, image the spot, find best focus.
%
%   sweep = tfp.calibration.throughFocusSweep(camera, zstage, zPositionsUm)
%   sweep = tfp.calibration.throughFocusSweep(..., options)
%
%   The core measurement of the INDIRECT z-calibration: with a fixed spot
%   projected (DMD + a fixed SLM defocus), step the objective z
%   (tfp.hardware.ZStage) through zPositionsUm, snap the substage camera
%   at each step, measure the spot's size (findSpotCentroid stats), and
%   fit the best-focus z — the stage position where the excitation focus
%   lands on the fluorescent film.
%
%   options:
%     .nAverages       — frames averaged per z (default 3; measurePSF spec)
%     .backgroundFrame — no-stim frame subtracted before detection ([])
%     .threshFrac      — fraction-of-peak threshold (default 0.3; [] = Otsu)
%     .fitHalfWindow   — points on each side of the sigma minimum used in
%                        the parabolic vertex fit (default 2)
%     .minAreaPx       — blobs smaller than this are treated as noise and
%                        the plane recorded NaN (default 5; a real spot is
%                        never smaller than a few px, but a noise spike is
%                        exactly 1-2 px and would fake a sigma minimum)
%
%   sweep struct:
%     .zPositionsUm  1xN as commanded
%     .sigmaPx       1xN spot RMS radius (NaN where detection failed)
%     .integratedF   1xN background-subtracted integrated intensity
%     .centroids     Nx2 [x y] camera px
%     .bestFocusZUm  parabolic-vertex z of minimum sigma
%     .fwhmZUm       FWHM of the axial profile from a Gaussian fit to
%                    1/sigma^2 ... reported as 2.3548*sigma_z of the
%                    integrated-sharpness profile (NaN if unfittable)
%
%   Detection failures at individual planes are recorded as NaN and
%   excluded from the fit (the fitAffineCalib NaN-row convention).

if nargin < 4 || isempty(options)
    options = struct();
end
nAvg      = double(tfp.util.configField(options, 'nAverages', 3));
bgFrame   = tfp.util.configField(options, 'backgroundFrame', []);
threshFrac = tfp.util.configField(options, 'threshFrac', 0.3);
halfWin   = double(tfp.util.configField(options, 'fitHalfWindow', 2));
minAreaPx = double(tfp.util.configField(options, 'minAreaPx', 5));

if ~isa(zstage, 'tfp.hardware.ZStage')
    error('tfp:calibration:throughFocusSweep:badZStage', ...
        'zstage must be a tfp.hardware.ZStage.');
end
zPositionsUm = double(zPositionsUm(:)');
N = numel(zPositionsUm);
if N < 3
    error('tfp:calibration:throughFocusSweep:tooFewPlanes', ...
        'Need at least 3 z positions (got %d).', N);
end

sigmaPx     = nan(1, N);
integratedF = nan(1, N);
centroids   = nan(N, 2);

spotOpts = struct('backgroundFrame', bgFrame, 'threshFrac', threshFrac);

for k = 1:N
    zstage.moveToUm(zPositionsUm(k));
    frame = camera.snap();
    for a = 2:nAvg
        frame = frame + camera.snap();
    end
    frame = frame / nAvg;
    try
        [c, stats] = findSpotCentroid(frame, k, spotOpts);
        if stats.areaPx < minAreaPx
            continue   % noise spike, not a spot: leave this plane NaN
        end
        centroids(k, :) = c;
        sigmaPx(k)      = stats.sigmaPx;
        integratedF(k)  = stats.integrated;
    catch ME
        if any(strcmp(ME.identifier, ...
                {'tfp:calibration:findSpotCentroid:blankFrame', ...
                 'tfp:calibration:findSpotCentroid:noSpot'}))
            % Unusable plane: NaN row, fit continues without it.
            continue
        end
        rethrow(ME);
    end
end

sweep.zPositionsUm = zPositionsUm;
sweep.sigmaPx      = sigmaPx;
sweep.integratedF  = integratedF;
sweep.centroids    = centroids;
sweep.bestFocusZUm = fitBestFocus(zPositionsUm, sigmaPx, halfWin);
sweep.fwhmZUm      = fitAxialFwhm(zPositionsUm, sigmaPx);
end

% --- Local helpers ---

function zBest = fitBestFocus(zUm, sigmaPx, halfWin)
%fitBestFocus Parabolic vertex through sigma^2 around the sampled minimum.
valid = find(isfinite(sigmaPx));
if numel(valid) < 3
    zBest = NaN;
    return
end
[~, iMinRel] = min(sigmaPx(valid));
iMin  = valid(iMinRel);
lo    = max(1, iMin - halfWin);
hi    = min(numel(zUm), iMin + halfWin);
sel   = intersect(lo:hi, valid);
if numel(sel) < 3
    zBest = zUm(iMin);   % not enough neighbours; take the sampled minimum
    return
end
p = polyfit(zUm(sel), sigmaPx(sel).^2, 2);
if p(1) <= 0
    zBest = zUm(iMin);   % degenerate (no upward curvature): sampled minimum
    return
end
zBest = -p(2) / (2 * p(1));
% Clamp inside the sampled range — an extrapolated vertex means the sweep
% did not bracket focus; the sampled minimum is the honest answer then.
if zBest < min(zUm) || zBest > max(zUm)
    zBest = zUm(iMin);
end
end

function fwhm = fitAxialFwhm(zUm, sigmaPx)
%fitAxialFwhm FWHM of the sharpness profile 1/sigma^2 via moment fit.
valid = isfinite(sigmaPx) & sigmaPx > 0;
if nnz(valid) < 3
    fwhm = NaN;
    return
end
z = zUm(valid);
s = 1 ./ sigmaPx(valid).^2;      % sharpness peaks at focus
s = s - min(s);
if sum(s) <= 0
    fwhm = NaN;
    return
end
mu     = sum(s .* z) / sum(s);
sigmaZ = sqrt(sum(s .* (z - mu).^2) / sum(s));
fwhm   = 2 * sqrt(2 * log(2)) * sigmaZ;   % measurePSF FWHM convention
end
