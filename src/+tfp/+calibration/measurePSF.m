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
%   ======================================================================
%   SPOT SIZING — READ THIS BEFORE QUOTING A PSF NUMBER.
%   ======================================================================
%   This routine deliberately wants the SMALLEST usable spot, because the
%   quantity it reports is a convolution of the true optical PSF with whatever
%   spot was projected. That puts it, alone among the calibration routines, at
%   the DMD's rasterization floor — and at the floor the anisotropy correction
%   the rest of the repo relies on stops working. Three facts, all measured
%   against the shipped tfp.patterns.singleSpot (T-BU-3e, 2026-07-26):
%
%   1. THE MINIMUM USEFUL SPOT IS A FEW PIXELS ACROSS. The sample scale is
%      1.1250 µm/px along the grating grooves and 1.4162 µm/px along the
%      dispersion axis (chip clocked 45°, so those are the chip DIAGONALS; see
%      tfp.util.opticalModel). The default 7 µm sample diameter is therefore
%      an area-matched circle of radius 2.77 DMD px — 21 mirrors. Asking for
%      much less means single-digit mirror counts, where the spot's position
%      quantizes to a whole pixel and its shape is pure lattice artefact.
%
%   2. IT CANNOT BE MADE ROUND AT THE SAMPLE. A spot that small has no room to
%      express the 1.2588 aspect correction. Sweeping the groove semi-axis and
%      mapping the ON pixels back to the sample plane:
%
%        groove semi-axis (px) | ON px | sample aspect | same pixels as circle?
%        ----------------------+-------+---------------+-----------------------
%         1.00                 |   1   |    (n/a)      | yes
%         1.25                 |   5   |   1.2588      | yes
%         2.00                 |   9   |   1.2588      | yes
%         2.80                 |  21   |   1.2588      | yes
%         3.11 (7 µm default)  |  23   |   0.944       | no
%         4.00                 |  41   |   1.007       | no
%         5.64 (12.7 µm soma)  |  81   |   1.079       | no
%        11.30                 | 319   |   1.007       | no
%
%      Below ~3 px semi-axis the "anisotropic" ellipse rasterizes to exactly
%      the same pixel set as an area-matched circle and the sample aspect stays
%      at the fully-UNCORRECTED 1.2588 — the correction buys literally nothing.
%      Between ~3 and ~6 px it does move a handful of mirrors, but the residual
%      aspect swings erratically between ~0.84 and ~1.08 as the lattice
%      happens to fall; it is not reliably closer to round. Only well above
%      ~10 px semi-axis does it settle within a few percent.
%
%   3. SO WE DO NOT PRETEND. When the requested spot is inside the floor this
%      routine draws the honest, deterministic, exactly area-matched ISOTROPIC
%      circle (tfp.patterns.somaSpotGeometry's .radiusPx route) rather than an
%      ellipse that would imply a roundness it cannot deliver. The delivered
%      spot is then elongated by exactly model.anisotropy = 1.2588 along the
%      dispersion axis — 6.24 × 7.85 µm for the 7 µm default. **Every PSF this
%      routine reports is convolved with that elongated spot.** sigmaX/sigmaY
%      are camera-frame widths and the elongation lies along a chip DIAGONAL,
%      so it does not map cleanly onto either; do not quote fwhmX/fwhmY as the
%      optical PSF without deconvolving, or at minimum without stating the
%      probe size. calib.spotExtentUm and calib.spotAspectRatio carry the
%      numbers so a figure caption can state them.
%      Above the floor the routine switches to the anisotropic ellipse, where
%      the correction does earn its keep.
%
%   This is physics, not a defect: you cannot make a round 7 µm spot out of ~20
%   mirrors. See the "~80 DMD pixels per soma" corollary in TASKS.md TASK-BU.
%   ======================================================================
%
%   Algorithm:
%     1. Project a single small spot (options.spotDiameterUm at the sample)
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
%     .spotDiameterUm — test-spot DIAMETER at the SAMPLE plane, in µm
%                       (default 7 — deliberately near-minimal; see above)
%     .spotRadiusPx   — DEPRECATED. Test-spot radius on the DMD in pixels.
%                       When given it overrides .spotDiameterUm and draws the
%                       historical isotropic pixel circle, so old callers are
%                       byte-for-byte unchanged. Prefer .spotDiameterUm.
%     .opticalConfig  — config struct forwarded to tfp.util.opticalModel for
%                       the µm→DMD-px conversion (a full loaded config or a
%                       bare dmd sub-struct). Default: design constants.
%     .suppressFloorWarning — silence the :spotAtRasterFloor warning (default
%                       false). The default spot IS inside the floor on
%                       purpose, so scripted sweeps that already know this can
%                       set it true; the facts are still reported in calib.
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
%     .spotDiameterUm — requested sample-plane spot diameter (µm), or NaN when
%                       a deprecated .spotRadiusPx was supplied
%     .spotExtentUm   — [groove dispersion] sample-plane diameters the DMD
%                       actually delivered. THE PSF IS CONVOLVED WITH THIS.
%     .spotAspectRatio — dispersion/groove extent of the delivered spot. 1.2588
%                       (fully uncorrected) whenever the spot is at the floor.
%     .spotPixels     — number of ON mirrors in the projected spot
%     .spotIsotropic  — true when the deterministic area-matched circle was
%                       drawn (i.e. inside the rasterization floor)
%     .atRasterFloor  — true when the requested spot is inside the floor
%     .spotGeometry   — the tfp.patterns.somaSpotGeometry struct, or []
%     .timestamp      — datetime of measurement
%     .notes          — string, with the delivered spot size appended
%     .images         — cell array of raw frames; {} if options.saveImages false
%
%   Warnings:
%     tfp:calibration:measurePSF:spotAtRasterFloor — the requested spot is
%       inside the rasterization floor, so it is drawn as a circle and lands
%       elongated 1.2588× at the sample. Expected for the default; suppress
%       with options.suppressFloorWarning.
%
%   See also tfp.calibration.alignDMDtoCamera, tfp.calibration.powerMeterSweep,
%            tfp.patterns.somaSpotGeometry, tfp.util.opticalModel.

if nargin < 4
    options = struct();
end
if nargin < 3 || isempty(sampleSlab)
    sampleSlab = struct();
end

% --- options ---
% Spot sizing: ask in sample µm (see the header). A supplied .spotRadiusPx is
% the deprecated pixel-count form and still wins, so existing callers are
% byte-identical.
spotDiameterUm  = configField(options, 'spotDiameterUm',   7);   %ASSUMED near-minimal but still ~20 mirrors
legacyRadiusPx  = configField(options, 'spotRadiusPx',     []);
opticalConfig   = configField(options, 'opticalConfig',    struct());
suppressFloorWarning = logical(configField(options, 'suppressFloorWarning', false));
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

% --- resolve the test-spot geometry (the interesting part; see the header) ---
spot = resolveTestSpot(spotDiameterUm, legacyRadiusPx, opticalConfig, ...
                       suppressFloorWarning);

% --- project one centered spot ---
spotCenterDMD = [round(dmd.nCols/2), round(dmd.nRows/2)];   % [col, row]
pattern = tfp.patterns.singleSpot(dmd, spotCenterDMD, spot.radiusPx, spot.spotOptions);

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

% The probe the PSF is convolved with. Reported unconditionally so a figure
% caption or a downstream deconvolution never has to guess (see the header).
calib.spotDiameterUm  = spot.diameterUm;
calib.spotExtentUm    = spot.extentUm;
calib.spotAspectRatio = spot.aspectRatio;
calib.spotPixels      = nnz(pattern);
calib.spotIsotropic   = spot.isotropic;
calib.atRasterFloor   = spot.atRasterFloor;
calib.spotGeometry    = spot.geometry;

calib.timestamp     = datetime('now');
calib.notes         = sprintf('%s [probe spot %.2f x %.2f um at the sample, %d mirrors]', ...
    notes, spot.extentUm(1), spot.extentUm(2), calib.spotPixels);
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

function spot = resolveTestSpot(diameterUm, legacyRadiusPx, opticalConfig, suppressWarning)
%resolveTestSpot Choose the near-minimal PSF probe spot and describe it honestly.
%   Returns the radius/options to hand tfp.patterns.singleSpot plus the
%   sample-plane facts the caller must report. See the SPOT SIZING block in the
%   header of this file for why the isotropic branch exists.

% Semi-axis, in DMD pixels, below which the anisotropy correction stops being
% worth drawing. Measured, not guessed: below ~3 px the ellipse rasterizes to
% the same pixel set as the area-matched circle, and from there up to ~6 px the
% residual sample aspect swings either side of 1 without reliably improving.
% 4 px is the value TASKS.md TASK-BU records from the same sweep; keeping the
% threshold a shade above the exact-equality point means the routine only
% claims a correction where it demonstrably helps.
FLOOR_SEMI_AXIS_PX = 4;

% tfp.util.opticalModel is the single source of truth for the µm/px pair —
% never hardcode 1.1250 / 1.4162 here (TASK-BU T-BU-0).
model = tfp.util.opticalModel(opticalConfig);

if ~isempty(legacyRadiusPx)
    % --- deprecated pixel-radius path: historical isotropic pixel circle ---
    if ~isnumeric(legacyRadiusPx) || ~isscalar(legacyRadiusPx) ...
            || ~isfinite(legacyRadiusPx) || legacyRadiusPx <= 0
        error('tfp:calibration:measurePSF:badSpotRadius', ...
            'options.spotRadiusPx must be a positive finite scalar.');
    end
    spot.radiusPx      = double(legacyRadiusPx);
    spot.spotOptions   = struct();          % circle-only call: no .anisotropic
    spot.diameterUm    = NaN;
    spot.geometry      = [];
    spot.isotropic     = true;
    % A pixel circle of radius r spans 2r px on both chip diagonals, so its
    % sample extents differ by exactly the anisotropy.
    spot.extentUm      = 2 * spot.radiusPx * ...
                         [model.umPerPixelGroove, model.umPerPixelDispersion];
    spot.aspectRatio   = model.anisotropy;
    spot.atRasterFloor = spot.radiusPx < FLOOR_SEMI_AXIS_PX;
else
    geom = tfp.patterns.somaSpotGeometry(diameterUm, opticalConfig);
    spot.diameterUm    = geom.diameterUm;
    spot.geometry      = geom;
    spot.atRasterFloor = min(geom.semiAxisGroovePx, geom.semiAxisDispersionPx) ...
                         < FLOOR_SEMI_AXIS_PX;

    if spot.atRasterFloor
        % Inside the floor: draw the exactly area-matched isotropic circle.
        % .radiusPx is somaSpotGeometry's documented circle-only route and is
        % NOT interchangeable with .semiAxisGroovePx — handing .radiusPx to
        % anisotropic mode is the T-BU-1f bug (67 mirrors instead of 81). It is
        % correct here precisely because no anisotropic option is passed.
        spot.radiusPx    = geom.radiusPx;
        spot.spotOptions = struct();
        spot.isotropic   = true;
        spot.extentUm    = geom.isotropicExtentUm;
        spot.aspectRatio = model.anisotropy;   % i.e. entirely uncorrected
    else
        % Above the floor the ellipse earns its keep, so ask for roundness.
        % .spotOptions carries .semiAxisGroovePx, which overrides the
        % positional radius; passing the groove semi-axis positionally too
        % keeps the two consistent.
        spot.radiusPx    = geom.semiAxisGroovePx;
        spot.spotOptions = geom.spotOptions;
        spot.isotropic   = false;
        spot.extentUm    = [geom.diameterUm, geom.diameterUm];
        spot.aspectRatio = 1;
    end
end

if spot.atRasterFloor && ~suppressWarning
    warning('tfp:calibration:measurePSF:spotAtRasterFloor', ...
        ['PSF probe spot is inside the DMD rasterization floor (< %g px ' ...
         'semi-axis), so it is drawn as an isotropic pixel circle and lands ' ...
         'at the sample as %.2f x %.2f um — elongated %.4fx along the ' ...
         'DISPERSION axis (a chip diagonal). The anisotropy correction cannot ' ...
         'be expressed at this size and is deliberately not applied; see the ' ...
         'SPOT SIZING block in measurePSF.m. Every PSF reported here is ' ...
         'convolved with that elongated spot, so quote calib.spotExtentUm ' ...
         'alongside the FWHM. This is expected for the default spot — set ' ...
         'options.suppressFloorWarning to silence it.'], ...
        FLOOR_SEMI_AXIS_PX, spot.extentUm(1), spot.extentUm(2), spot.aspectRatio);
end
end

function plotPsfDiagnostic(frame, g, calib)
figure('Name', 'Lateral PSF', 'NumberTitle', 'off');
imagesc(frame);
axis image; colormap(gca, 'gray'); colorbar; hold on;
plot(g.x0, g.y0, 'r+', 'MarkerSize', 12, 'LineWidth', 1.5);
% The probe size goes on the figure: an FWHM quoted without it is not
% interpretable, and at the raster floor the probe is not even round.
title({sprintf('Lateral PSF — FWHM_x = %.2f µm, FWHM_y = %.2f µm', ...
        calib.fwhmXUm, calib.fwhmYUm), ...
       sprintf('convolved with a %.2f x %.2f µm probe spot (aspect %.3f, %d mirrors)', ...
        calib.spotExtentUm(1), calib.spotExtentUm(2), ...
        calib.spotAspectRatio, calib.spotPixels)});
xlabel('Camera X (px)'); ylabel('Camera Y (px)');
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
