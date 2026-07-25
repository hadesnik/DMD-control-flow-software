function calib = measurePSF(dmd, camera, sampleSlab, options)
%measurePSF Measure the temporal-focusing point-spread function on a thin slab.
%   Projects a single small DMD spot onto a thin fluorescent film and
%   captures images on the substage widefield camera. Fits a 2D Gaussian to
%   the intensity profile to extract lateral PSF widths (sigma_x, sigma_y).
%   Optionally steps the objective through a series of z positions to
%   characterise the axial PSF as well.
%
%   Temporal-focusing geometry note:
%     Lateral confinement is set by the DMD pixel size and the optical
%     magnification from DMD to sample. Axial confinement arises from
%     spectral dispersion at the grating: only at the nominal focal plane
%     does the full bandwidth recombine to produce a short pulse and
%     efficient 2-photon excitation. The axial PSF width (sigma_z) is
%     therefore the primary figure of merit for temporal focusing.
%
%   Required hardware:
%     dmd        - tfp.hardware.DMD-derived object (real or mock), initialised.
%                  Projects the calibration spot pattern.
%     camera     - tfp.hardware.SubstageCamera-derived object, initialised.
%                  Captures fluorescence images of the slab.
%                  NOTE: ScanImage cannot image DMD spots — it uses a PMT
%                  point detector, not a widefield camera. Use a substage
%                  camera only.
%     sampleSlab - struct describing the fluorescent sample:
%                    .zStage     tfp.hardware.ZStage-derived object for axial
%                                stepping (required when options.measureAxial
%                                is true; ignored otherwise).
%                    .thicknessUm  nominal slab thickness in µm (informational).
%                    .fluorophore  char, e.g. 'fluorescein', 'FITC' (informational).
%
%   Algorithm:
%     1. Project a single small spot (radius = options.spotRadiusPx DMD pixels)
%        at the DMD centre onto the fluorescent slab.
%     2. Capture one image per z position on the substage camera. At the
%        nominal focal plane (z = 0) this is the only image (lateral PSF only).
%     3. For each image, fit a 2D Gaussian:
%          I(x,y) = A * exp(-((x-x0)^2/(2*sx^2) + (y-y0)^2/(2*sy^2))) + B
%        Extract sigma_x, sigma_y in camera pixels; convert to µm via
%        options.umPerPixel.
%     4. If options.measureAxial is true, repeat steps 1-3 at each z position
%        in options.zPositionsUm (requires sampleSlab.zStage). Fit a Gaussian
%        to the integrated fluorescence vs. z to obtain sigma_z.
%     5. Store all results in the output calib struct.
%
%   calib = measurePSF(dmd, camera, sampleSlab)
%   calib = measurePSF(dmd, camera, sampleSlab, options)
%
%   options fields (all optional):
%     .spotRadiusPx   — test-spot radius on DMD in pixels (default 3)
%     .exposureS      — camera exposure / settle time per capture (s) (default 0.05)
%     .umPerPixel     — camera pixel size at sample plane (µm/px) (default 1.56)
%     .measureAxial   — if true, step z and measure axial PSF (default false)
%     .zPositionsUm   — z positions relative to nominal focus (µm)
%                       (default linspace(-30, 30, 13), used when measureAxial true)
%     .nAverages      — frames averaged per z position (default 3)
%     .showFigure     — display diagnostic figure on completion (default true)
%     .saveImages     — store raw frames in calib.images (default false)
%     .notes          — char appended to calib.notes
%
%   Output calib struct:
%     .sigmaXUm       — lateral PSF 1/e half-width in x at focus (µm)
%     .sigmaYUm       — lateral PSF 1/e half-width in y at focus (µm)
%     .fwhmXUm        — FWHM in x (µm) = 2*sqrt(2*log(2))*sigmaXUm
%     .fwhmYUm        — FWHM in y (µm)
%     .sigmaZUm       — axial PSF 1/e half-width (µm); [] if not measured
%     .fwhmZUm        — axial FWHM (µm); [] if not measured
%     .zPositionsUm   — z positions sampled (µm); [] if not measured
%     .integratedF    — integrated fluorescence at each z (a.u.); [] if not measured
%     .spotCenterDMD  — [col, row] DMD pixel of the test spot
%     .gaussFitFocus  — fit-parameter vector [A, x0, y0, sx, sy, B] at focus
%     .umPerPixel     — camera pixel size used (µm/px)
%     .timestamp      — datetime of measurement
%     .notes          — string
%     .images         — cell array of raw frames; {} if options.saveImages false
%
%   See also tfp.calibration.alignDMDtoCamera, tfp.calibration.powerMeterSweep.

if nargin < 4
    options = struct();
end
if nargin < 3 || isempty(sampleSlab)
    sampleSlab = struct();
end

% --- options ---
spotRadiusPx    = configField(options, 'spotRadiusPx',     3);
exposureS       = configField(options, 'exposureS',        0.05);
umPerPixel      = configField(options, 'umPerPixel',       1.56);
measureAxial    = logical(configField(options, 'measureAxial', false));
nAverages       = configField(options, 'nAverages',        3);
showFigure      = logical(configField(options, 'showFigure', true));
saveImages      = logical(configField(options, 'saveImages', false));
cropHalfWidthPx = configField(options, 'cropHalfWidthPx',  30);
notes           = configField(options, 'notes',            'lateral PSF measurement');

% --- validate hardware ---
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:measurePSF:badCamera', ...
        ['camera must be a tfp.hardware.SubstageCamera; got %s. ' ...
         'ScanImage cannot image DMD spots (PMT point detector).'], class(camera));
end
if ~camera.isInitialized
    error('tfp:calibration:measurePSF:cameraNotInitialized', ...
        'camera must be initialized before calling measurePSF.');
end
if ~dmd.isInitialized
    error('tfp:calibration:measurePSF:dmdNotInitialized', ...
        'dmd must be initialized before calling measurePSF.');
end

% --- axial path is deferred: needs a ZStage abstraction not yet built ---
if measureAxial
    error('tfp:calibration:measurePSF:axialDeferred', ...
        ['Axial PSF measurement is not yet implemented: it requires a ' ...
         'tfp.hardware.ZStage abstraction (real + mock) that does not exist ' ...
         'yet. For preliminary data use pseudo-axial objective translation ' ...
         'and label it as such. Call measurePSF with measureAxial=false for ' ...
         'the lateral PSF.']);
end

% --- project one centered spot ---
spotCenterDMD = [round(dmd.nCols/2), round(dmd.nRows/2)];   % [col, row]
pattern = tfp.patterns.singleSpot(dmd, spotCenterDMD, spotRadiusPx);

seqOpts.exposureUs = max(1, round(exposureS * 1e6));
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(pattern, seqOpts);
dmd.armSequence();
dmd.advanceToPattern(1);

% --- capture and average frames ---
frame = [];
rawFrames = {};
for k = 1:max(1, nAverages)
    if exposureS > 0
        pause(exposureS);
    end
    f = camera.snap();
    if saveImages
        rawFrames{end+1} = f; %#ok<AGROW>
    end
    if isempty(frame)
        frame = f;
    else
        frame = frame + f;
    end
end
frame = frame / max(1, nAverages);

% --- locate spot, then fit a 2D Gaussian on a crop around it ---
centroid = findSpotCentroid(frame, 1);              % [x y] = [col row], private helper
g        = fitGaussian2D(frame, centroid, cropHalfWidthPx);

fwhmFactor = 2 * sqrt(2 * log(2));

calib.sigmaXUm      = g.sx * umPerPixel;
calib.sigmaYUm      = g.sy * umPerPixel;
calib.fwhmXUm       = fwhmFactor * calib.sigmaXUm;
calib.fwhmYUm       = fwhmFactor * calib.sigmaYUm;
calib.sigmaZUm      = [];
calib.fwhmZUm       = [];
calib.zPositionsUm  = [];
calib.integratedF   = [];
calib.spotCenterDMD = spotCenterDMD;
calib.gaussFitFocus = [g.A, g.x0, g.y0, g.sx, g.sy, g.B];
calib.umPerPixel    = umPerPixel;
calib.timestamp     = datetime('now');
calib.notes         = notes;
if saveImages
    calib.images = rawFrames;
else
    calib.images = {};
end

if showFigure
    plotPsfDiagnostic(frame, g, calib);
end
end

% =========================================================================
% Local functions
% =========================================================================

% fitGaussian2D was promoted to private/fitGaussian2D.m so it can be shared
% with measureFocalPlaneTilt (spot sharpness as a focus metric).

function plotPsfDiagnostic(frame, g, calib)
figure('Name', 'Lateral PSF', 'NumberTitle', 'off');
imagesc(frame);
axis image; colormap(gca, 'gray'); colorbar; hold on;
plot(g.x0, g.y0, 'r+', 'MarkerSize', 12, 'LineWidth', 1.5);
title(sprintf('Lateral PSF — FWHM_x = %.2f µm, FWHM_y = %.2f µm', ...
    calib.fwhmXUm, calib.fwhmYUm));
xlabel('Camera X (px)'); ylabel('Camera Y (px)');
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
