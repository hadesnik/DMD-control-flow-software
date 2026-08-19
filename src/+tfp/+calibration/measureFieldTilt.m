function calib = measureFieldTilt(dmd, camera, zstage, config, options)
%measureFieldTilt Measure the tilt of the excitation plane across the field.
%
%   calib = tfp.calibration.measureFieldTilt(dmd, camera, zstage, config)
%   calib = tfp.calibration.measureFieldTilt(dmd, camera, zstage, config, options)
%
%   WHAT THIS MEASURES. Temporal focusing disperses the beam across the field,
%   so the plane of best excitation is TILTED rather than flat: the handoff
%   predicts 0.02929 um of focal shift per um of sample-plane travel along the
%   dispersion axis, which is 1.678 degrees and 35.1 um edge to edge across the
%   O5.0 mm patch — comparable to the 32.6 um axial FWHM. Targets at opposite
%   edges of the field are therefore genuinely not in the same plane, and the
%   control software should REPORT that rather than hide it.
%
%   HOW. At each of N field positions inside the patch: project a spot, run a
%   through-focus sweep with tfp.calibration.throughFocusSweep (reused
%   verbatim — it is the primitive), take its bestFocusZUm, then least-squares
%   fit
%       z = a * x_disp + b * y_groove + c        (sample um)
%   with x_disp / y_groove from tfp.optics.dmdToDispersionUm, which is the one
%   home of the 45-degree clocking. Do not re-derive that mapping here.
%
%   Expect a ~= depth_gradient_um_per_um and b ~= 0. A large |b| relative to
%   |a| is diagnostic rather than merely disappointing: it means the tilt is
%   not along the dispersion axis at all, which points at a wrong 45-degree
%   handedness or a mis-clocked chip.
%
%   Inputs:
%     dmd     - tfp.hardware.DMD, initialised.
%     camera  - tfp.hardware.SubstageCamera, initialised.
%     zstage  - tfp.hardware.ZStage, initialised. On the default objective
%               mount this is the RelayZStage talking to si_motor_helper on the
%               imaging PC (port 3047), so the ScanImage MATLAB must be up.
%     config  - full config struct.
%     options - struct, all optional:
%       .nRing            points per ring (default 8)
%       .nRadii           rings inside the patch (default 1)
%       .radiusFrac       outermost ring as a fraction of the usable radius
%                         (default 0.95)
%       .includeCentre    add the chip centre as a point (default true)
%       .dmdPts           Nx2 [col row] to use instead of the generated ring
%       .spotRadiusPx     spot radius in DMD pixels (default 8)
%       .powerMw          power for the measurement (default 5)
%       .laser            tfp.hardware.LaserPowerController; when supplied the
%                         power is commanded through it, so the pulse-energy
%                         interlock and the confirmation dialog apply
%       .zSearchHalfUm    half-range of each sweep (default 30)
%       .zStepUm          sweep step (default 5)
%       .zPredictClampUm  how far a predicted window may move from z0
%                         (default 2 * zSearchHalfUm)
%       .predictWindows   centre later sweeps on the partial plane fit
%                         (default true)
%       .sweepOptions     forwarded to throughFocusSweep
%       .gradientTolFrac  sanity band, fractional (default 0.5 — deliberately
%                         loose: the committed handoff is rev 4 and predates
%                         the ratified f7 = 300 build)
%       .exposureS        settle after advanceToPattern (default 0.05)
%       .stagePositionUm  1x3 stage position stamped into the result
%       .notes            char appended to calib.notes
%       .verbose          print per-point lines (default true)
%
%   Output calib struct, kind = 'field_tilt':
%     .dmdPts .xDispUm .yGrooveUm .bestFocusZUm .sweeps
%     .fit.{aUmPerUm,bUmPerUm,cUm,r2,rmseUm,nAccepted}
%     .tiltAngleDeg .tiltAzimuthDeg .walkUm .walkFullPatchUm .axialFwhmUm
%     .expected .sanity .depthGradientSign
%     .zRuler .stagePositionUm .cameraSettings .laserState .timestamp .notes
%
%   Sanity bands WARN, never fail (:gradientOutOfBand, :walkOutOfBand,
%   :grooveGradientLarge): the measurement is the truth, the handoff is a
%   design value from a superseded build.
%
%   .depthGradientSign is a PROPOSAL for config.threeD.depth_gradient_sign, not
%   authority. It is expressed in both the z ruler's "+z is deeper" contract
%   and dmdToDispersionUm's +dispersion direction, and the handoff explicitly
%   leaves both bench conventions unspecified. BRINGUP_GUIDE section 7.4's burn
%   row remains the independent check.
%
%   Throws tfp:calibration:measureFieldTilt:{badCamera,badZStage,badOptions,
%   tooFewPoints}, plus the containment throw from tfp.util.assertPatternInPatch.
%
%   See also tfp.calibration.throughFocusSweep, tfp.optics.dmdToDispersionUm,
%   tfp.calibration.measureFieldTilt_mock.

if nargin < 5 || isempty(options), options = struct(); end
if nargin < 4 || isempty(config),  config  = struct(); end

if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:measureFieldTilt:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~isa(zstage, 'tfp.hardware.ZStage')
    error('tfp:calibration:measureFieldTilt:badZStage', ...
        ['zstage must be a tfp.hardware.ZStage. The field tilt is measured ' ...
         'against the z ruler; there is no way to fit a depth plane without ' ...
         'one.']);
end

nRing          = tfp.util.configField(options, 'nRing',           8);
nRadii         = tfp.util.configField(options, 'nRadii',          1);
radiusFrac     = tfp.util.configField(options, 'radiusFrac',      0.95);
includeCentre  = logical(tfp.util.configField(options, 'includeCentre', true));
spotRadiusPx   = tfp.util.configField(options, 'spotRadiusPx',    8);
powerMw        = tfp.util.configField(options, 'powerMw',         5);
laser          = tfp.util.configField(options, 'laser',           []);
zSearchHalfUm  = tfp.util.configField(options, 'zSearchHalfUm',   30);
zStepUm        = tfp.util.configField(options, 'zStepUm',         5);
predictWindows = logical(tfp.util.configField(options, 'predictWindows', true));
zPredictClamp  = tfp.util.configField(options, 'zPredictClampUm', 2 * zSearchHalfUm);
sweepOptions   = tfp.util.configField(options, 'sweepOptions',    struct());
gradTolFrac    = tfp.util.configField(options, 'gradientTolFrac', 0.5);
exposureS      = tfp.util.configField(options, 'exposureS',       0.05);
stagePosUm     = tfp.util.configField(options, 'stagePositionUm', []);
notes          = char(tfp.util.configField(options, 'notes',      ''));
verbose        = logical(tfp.util.configField(options, 'verbose',  true));

consts  = tfp.util.readHandoffConstants();
dmdSize = [dmd.nRows, dmd.nCols];

% --- field points ------------------------------------------------------
dmdPts = tfp.util.configField(options, 'dmdPts', []);
if isempty(dmdPts)
    dmdPts = ringPoints(dmdSize, consts, nRing, nRadii, radiusFrac, ...
        spotRadiusPx, includeCentre);
end
if ~isnumeric(dmdPts) || size(dmdPts, 2) ~= 2 || size(dmdPts, 1) < 4
    error('tfp:calibration:measureFieldTilt:badOptions', ...
        'need at least 4 field points as an Nx2 [col row]; got %s.', ...
        mat2str(size(dmdPts)));
end
nPts = size(dmdPts, 1);

% --- patterns, checked for containment BEFORE any light -----------------
% A bad radiusFrac should fail in milliseconds, not 40 through-focus sweeps in.
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:, :, k) = tfp.patterns.singleSpot(dmd, dmdPts(k, :), spotRadiusPx);
end
tfp.util.assertPatternInPatch(patterns, struct('mode', 'error', ...
    'label', 'measureFieldTilt'));
tfp.util.assertSlmPowerSafe(patterns, powerMw, config);

% --- arm ----------------------------------------------------------------
seqOpts = struct('exposureUs', round(max(exposureS, 0) * 1e6), 'darkTimeUs', 0);
dmd.loadPatternSequence(patterns, seqOpts);
dmd.armSequence();

z0 = zstage.getPositionUm();
restoreZ = onCleanup(@() safeMoveTo(zstage, z0));

if ~isempty(laser)
    laser.beginStep('field_tilt');
    laser.notePattern(patterns);
    laser.setPowerMw(powerMw, struct('step', 'field_tilt'));
end

% --- sweep each field point --------------------------------------------
[xDispUm, yGrooveUm] = tfp.optics.dmdToDispersionUm(dmdPts, dmdSize, consts);
xDispUm   = xDispUm(:)';
yGrooveUm = yGrooveUm(:)';

bestZ    = nan(1, nPts);
sweeps   = cell(1, nPts);
atEdge   = false(1, nPts);
windows  = nan(nPts, 2);

for k = 1:nPts
    zCentre = z0;
    if predictWindows
        zCentre = predictCentre(xDispUm, yGrooveUm, bestZ, k, z0, zPredictClamp);
    end
    zPositions = zCentre + (-zSearchHalfUm:zStepUm:zSearchHalfUm);

    dmd.advanceToPattern(k);
    if exposureS > 0, pause(exposureS); end

    windows(k, :) = [min(zPositions), max(zPositions)];
    try
        sweeps{k} = tfp.calibration.throughFocusSweep(camera, zstage, ...
            zPositions, sweepOptions);
        bestZ(k)  = sweeps{k}.bestFocusZUm;
        % A best focus sitting at the edge of the swept window almost always
        % means the true focus is OUTSIDE it, so the value is a clamp, not a
        % measurement. Including such a point silently biases the gradient
        % toward zero — which is the whole quantity being measured.
        atEdge(k) = isfinite(bestZ(k)) && ...
            (bestZ(k) <= windows(k,1) + zStepUm || bestZ(k) >= windows(k,2) - zStepUm);
    catch ME
        warning('tfp:calibration:measureFieldTilt:sweepFailed', ...
            'field point %d of %d (DMD %d,%d) failed: %s', ...
            k, nPts, round(dmdPts(k,1)), round(dmdPts(k,2)), ME.message);
    end
    if verbose
        fprintf('[measureFieldTilt] point %2d/%2d  DMD(%4d,%4d)  x_disp %+8.1f um  best focus %+8.2f um\n', ...
            k, nPts, round(dmdPts(k,1)), round(dmdPts(k,2)), xDispUm(k), bestZ(k));
    end
end

if ~isempty(laser)
    laser.zero();
end

% --- plane fit ----------------------------------------------------------
good = isfinite(bestZ);
if any(atEdge & good)
    edgeIdx = find(atEdge & good);
    if nnz(good & ~atEdge) >= 4
        good(edgeIdx) = false;
        excluded = true;
    else
        excluded = false;
    end
    warning('tfp:calibration:measureFieldTilt:focusAtWindowEdge', ...
        ['best focus landed at the edge of the swept window at %d of %d field ' ...
         'points (%s), so the true focus is probably outside it. %s Increase ' ...
         'options.zSearchHalfUm to at least the expected edge-to-edge walk ' ...
         '(handoff design value %.1f um) and re-run.'], ...
        numel(edgeIdx), nPts, mat2str(edgeIdx), ...
        ternary(excluded, 'Those points were EXCLUDED from the plane fit.', ...
                          'They were KEPT because too few points would remain.'), ...
        consts.walk_um);
end
if nnz(good) < 4
    error('tfp:calibration:measureFieldTilt:tooFewPoints', ...
        ['only %d of %d field points produced a best focus; need at least 4 ' ...
         'to fit a plane. Check the spot is visible on the camera at every ' ...
         'field position and that the sweep range brackets focus.'], ...
        nnz(good), nPts);
end

A     = [xDispUm(good)', yGrooveUm(good)', ones(nnz(good), 1)];
zObs  = bestZ(good)';
coef  = A \ zObs;
zHat  = A * coef;
resid = zObs - zHat;
ssTot = sum((zObs - mean(zObs)).^2);

a = coef(1);   % um per um along dispersion
b = coef(2);   % um per um along groove
c = coef(3);

fit = struct( ...
    'aUmPerUm',  a, ...
    'bUmPerUm',  b, ...
    'cUm',       c, ...
    'r2',        ternary(ssTot > 0, 1 - sum(resid.^2) / max(ssTot, eps), NaN), ...
    'rmseUm',    sqrt(mean(resid.^2)), ...
    'nAccepted', nnz(good));

% --- derived ------------------------------------------------------------
% Walk across the full patch. The patch is a CIRCLE in DMD pixels, so it maps
% to an ELLIPSE in (x_disp, y_groove) with semi-axes R*um_per_px_disp and
% R*um_per_px_groove. The extremum of a*x + b*y over that ellipse is
% sqrt((a*Rx)^2 + (b*Ry)^2), so edge to edge is twice that. With the handoff's
% own numbers this reproduces walk_um = 35.1 exactly.
Rpx = consts.patch_diameter_px / 2;
Rx  = Rpx * consts.um_per_px_disp;
Ry  = Rpx * consts.um_per_px_groove;
walkFullPatchUm = 2 * sqrt((a * Rx)^2 + (b * Ry)^2);

fwhms = cellfun(@(s) sweepField(s, 'fwhmZUm'), sweeps);

calib = struct();
calib.kind             = 'field_tilt';
calib.dmdPts           = dmdPts;
calib.xDispUm          = xDispUm;
calib.yGrooveUm        = yGrooveUm;
calib.bestFocusZUm     = bestZ;
calib.focusAtWindowEdge = atEdge;
calib.searchWindowsUm   = windows;
calib.sweeps           = {sweeps};
calib.fit              = fit;
calib.tiltAngleDeg     = atand(hypot(a, b));
calib.tiltAzimuthDeg   = atan2d(b, a);
calib.walkUm           = max(zHat) - min(zHat);
calib.walkFullPatchUm  = walkFullPatchUm;
calib.axialFwhmUm      = median(fwhms(isfinite(fwhms)));
calib.depthGradientSign = sign(a);
calib.expected = struct( ...
    'depthGradientUmPerUm', consts.depth_gradient_um_per_um, ...
    'walkUm',               consts.walk_um, ...
    'axialFwhmUm',          consts.axial_fwhm_um, ...
    'handoffRev',           consts.handoff_rev);
calib.zRuler = struct( ...
    'class',         class(zstage), ...
    'mount',         char(tfp.util.configField( ...
                        tfp.util.configField(config, 'zstage', struct()), ...
                        'mount', 'objective')), ...
    'directionSign', tfp.util.configField( ...
                        tfp.util.configField(config, 'zstage', struct()), ...
                        'direction_sign', 1), ...
    'startZUm',      z0);
calib.stagePositionUm = stagePosUm;
calib.cameraSettings  = cameraSettings(camera);
calib.laserState      = laserStateOf(laser);
calib.timestamp       = datetime('now');
calib.notes           = buildNotes(nPts, powerMw, notes);

% --- sanity bands: warn, never fail ------------------------------------
expectedA = consts.depth_gradient_um_per_um;
gradInBand = abs(abs(a) - expectedA) <= gradTolFrac * expectedA;
walkInBand = abs(calib.walkFullPatchUm - consts.walk_um) <= gradTolFrac * consts.walk_um;
calib.sanity = struct('gradientInBand', gradInBand, ...
    'walkInBand', walkInBand, 'band', gradTolFrac);

if ~gradInBand
    warning('tfp:calibration:measureFieldTilt:gradientOutOfBand', ...
        ['fitted dispersion gradient %.5f um/um is outside +/-%.0f%% of the ' ...
         'handoff rev %g design value %.5f. The measurement is the truth — ' ...
         'the handoff predates the ratified f7 = 300 build.'], ...
        abs(a), 100 * gradTolFrac, consts.handoff_rev, expectedA);
end
if ~walkInBand
    warning('tfp:calibration:measureFieldTilt:walkOutOfBand', ...
        ['extrapolated edge-to-edge walk %.1f um is outside +/-%.0f%% of the ' ...
         'handoff design value %.1f um.'], ...
        calib.walkFullPatchUm, 100 * gradTolFrac, consts.walk_um);
end
if abs(b) > abs(a)
    warning('tfp:calibration:measureFieldTilt:grooveGradientLarge', ...
        ['the groove-axis gradient (%.5f um/um) exceeds the dispersion-axis ' ...
         'gradient (%.5f um/um). The tilt is not along the dispersion axis, ' ...
         'which points at a wrong 45-degree handedness or a mis-clocked chip ' ...
         'rather than at a bad fit.'], abs(b), abs(a));
end
end

% ===========================================================================
function pts = ringPoints(dmdSize, consts, nRing, nRadii, radiusFrac, spotRadiusPx, includeCentre)
%ringPoints Field positions on concentric rings inside the usable patch.
Rusable = consts.patch_diameter_px / 2 - spotRadiusPx - 5;
if Rusable <= 0
    error('tfp:calibration:measureFieldTilt:badOptions', ...
        'spotRadiusPx %g leaves no room inside the %g px patch.', ...
        spotRadiusPx, consts.patch_diameter_px);
end
cCol = (dmdSize(2) + 1) / 2;
cRow = (dmdSize(1) + 1) / 2;

pts = zeros(0, 2);
if includeCentre
    pts(end+1, :) = [cCol, cRow];
end
for r = 1:nRadii
    frac = radiusFrac * r / nRadii;
    R    = frac * Rusable;
    % Offset alternate rings so points do not stack radially.
    phi0 = (r - 1) * pi / max(nRing, 1);
    for k = 1:nRing
        th = phi0 + 2 * pi * (k - 1) / nRing;
        pts(end+1, :) = [cCol + R * cos(th), cRow + R * sin(th)]; %#ok<AGROW>
    end
end
pts = round(pts);
end

% ---------------------------------------------------------------------------
function zCentre = predictCentre(xDisp, yGroove, bestZ, k, z0, clampUm)
%predictCentre Centre the next sweep on the partial plane fit.
%   Across 9-17 points this roughly halves the total sweep time, and each
%   point is a full through-focus stack. Falls back to z0 until there are
%   three accepted, non-degenerate points.
zCentre = z0;
good = isfinite(bestZ(1:k-1));
if nnz(good) < 3
    return
end
A = [xDisp(good)', yGroove(good)', ones(nnz(good), 1)];
if rank(A) < 3
    return   % collinear so far; no plane to predict from
end
coef = A \ bestZ(good)';
pred = [xDisp(k), yGroove(k), 1] * coef;
if ~isfinite(pred)
    return
end
zCentre = min(max(pred, z0 - clampUm), z0 + clampUm);
end

% ---------------------------------------------------------------------------
function safeMoveTo(zstage, zUm)
try
    zstage.moveToUm(zUm);
catch ME
    warning('tfp:calibration:measureFieldTilt:zRestoreFailed', ...
        'could not return the z ruler to %.2f um: %s', zUm, ME.message);
end
end

% ---------------------------------------------------------------------------
function v = sweepField(s, name)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = NaN;
end
end

% ---------------------------------------------------------------------------
function s = cameraSettings(camera)
%cameraSettings Snapshot whatever the backend will tell us. Provenance only.
s = struct('class', class(camera), 'nRows', camera.nRows, 'nCols', camera.nCols);
caps = camera.getCapabilities();
if caps.exposure,    s.exposureMs  = tryGet(@() camera.getExposureMs());  end
if caps.gain,        s.gain        = tryGet(@() camera.getGain());        end
if caps.binning,     s.binning     = tryGet(@() camera.getBinning());     end
if caps.roi,         s.roi         = tryGet(@() camera.getRoi());         end
if caps.pixelFormat, s.pixelFormat = tryGet(@() camera.getPixelFormat()); end
if caps.bitDepth,    s.bitDepth    = tryGet(@() camera.getBitDepth());    end
end

function v = tryGet(fcn)
try, v = fcn(); catch, v = []; end
end

% ---------------------------------------------------------------------------
function ls = laserStateOf(laser)
if isempty(laser)
    ls = [];
else
    ls = laser.getLaserState();
end
end

% ---------------------------------------------------------------------------
function s = buildNotes(nPts, powerMw, extra)
s = sprintf('field tilt from %d through-focus sweeps at %.3g mW', nPts, powerMw);
if ~isempty(extra)
    s = sprintf('%s. %s', s, extra);
end
end

% ---------------------------------------------------------------------------
function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end
