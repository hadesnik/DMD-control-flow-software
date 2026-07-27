function calib = measureFocalPlaneTilt_mock(dmd, options)
%measureFocalPlaneTilt_mock Synthetic focal-plane tilt (no hardware).
%   Evaluates a known analytic tilt plane over the same grid the real routine
%   projects, then runs the identical plane-fit, axis-decomposition and
%   design-comparison math and returns the same struct shape. Because the plane
%   is exact by construction, this verifies the whole reduction headless (no
%   camera, no ZStage, no Image Processing Toolbox). Mirrors
%   tfp.calibration.measureIlluminationUniformity_mock.
%
%   calib = measureFocalPlaneTilt_mock(dmd)
%   calib = measureFocalPlaneTilt_mock(dmd, options)
%
%   THE ROUND TRIP THIS EXISTS FOR (T-BU-3b). The truth is specified in the
%   SAMPLE plane — µm of depth per µm along the dispersion and groove axes —
%   and converted to DMD-pixel plane coefficients through the same
%   tfp.patterns.dmdToSampleOffset map the real routine inverts. Synthesising
%   with the forward map and recovering with the inverse is the strongest
%   check available without hardware: it pins the 45° clocking, the
%   anisotropic 1.4162/1.1250 µm-per-pixel axis scales, and the sign
%   conventions all at once. A scalar µm/px would round-trip too, which is
%   exactly why the round trip must go through the anisotropic map.
%
%   Inputs:
%     dmd     - object/struct with .nRows and .nCols.
%     options - optional struct. Truth specification (pick ONE):
%       .truthDepthGradientUmPerUm — [dispersion groove] µm of depth per µm at
%                         the sample, or a scalar meaning dispersion-only.
%                         DEFAULT: the design tilt from tfp.util.opticalModel,
%                         i.e. depthGradientSign*depthGradientUmPerUm along
%                         dispersion and exactly ZERO along the grooves.
%       .truthZ0Um      — constant depth offset, µm (default 0)
%       .truthTiltPlane — LEGACY [a b z0]: best-focus Z (µm) = z0 + a*(col-cx)
%                         + b*(row-cy), with a,b in µm-Z per DMD-px. Kept for
%                         callers that think in raw pixel slopes; specifying
%                         both forms is an error.
%     Grid, optical model, expectation-check and legacy options are the same as
%     tfp.calibration.measureFocalPlaneTilt:
%       .nGridPoints, .gridSpacing, .roiHalfWidthPx
%       .config / .model, .dmdToSampleLinear, .mapUnits, .cameraUmPerPixel
%       .checkExpectation, .warnOnExpectation, .verbose (default FALSE here —
%         the mock is headless), .grooveWalkToleranceUm, .gradientToleranceFrac,
%         .walkFwhmFraction, .fieldCurvatureUm
%       .umPerPixel — legacy scalar for the isotropic .tiltAngleDeg fields only.
%                     Default is now tfp.util.opticalModel().umPerPixel, not the
%                     retired 0.270 guess.
%       .notes
%
%   Output: the same fields as tfp.calibration.measureFocalPlaneTilt (see its
%   help), plus
%     .truthDepthGradientUmPerUm — [dispersion groove] truth actually used
%     .truthTiltPlane            — [a b z0] DMD-pixel coefficients it synthesised
%                                  (feed straight to MockSubstageCamera's
%                                  truthTiltPlane to drive the real routine with
%                                  the same tilt)
%
%   Errors:   tfp:calibration:measureFocalPlaneTilt_mock:<reason>
%   Warnings: tfp:calibration:measureFocalPlaneTilt:<reason> — deliberately the
%             SAME identifiers the real routine raises, since the comparison
%             code is shared verbatim.
%
%   See also tfp.calibration.measureFocalPlaneTilt, tfp.util.opticalModel,
%            tfp.patterns.dmdToSampleOffset.

if nargin < 2
    options = struct();
end

% Optical constants + the DMD→sample map (single source of truth).
[model, mapSpec, mapArgs] = resolveTiltMap_(options);

nGridPoints = configField(options, 'nGridPoints', 9);
umPerPixel  = configField(options, 'umPerPixel', model.umPerPixel);
notes       = configField(options, 'notes', 'mock focal-plane tilt — synthetic plane');

checkExpectation  = logical(configField(options, 'checkExpectation',  true));
warnOnExpectation = logical(configField(options, 'warnOnExpectation', true));
verbose           = logical(configField(options, 'verbose', false));

%ASSUMED 0.56 µm — objective field-curvature contribution across the field
% (handoff §6). Same default as the real routine; see its help.
fieldCurvatureUm = configField(options, 'fieldCurvatureUm', 0.56);

tol.grooveWalkUm     = configField(options, 'grooveWalkToleranceUm', 3 * fieldCurvatureUm);
tol.gradientFraction = configField(options, 'gradientToleranceFrac', 0.25);
tol.walkFwhmFraction = configField(options, 'walkFwhmFraction',      0.5);

if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:measureFocalPlaneTilt_mock:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isnumeric(umPerPixel) || ~isscalar(umPerPixel) || ~isfinite(umPerPixel) || umPerPixel <= 0
    error('tfp:calibration:measureFocalPlaneTilt_mock:badUmPerPixel', ...
        'options.umPerPixel must be a positive finite scalar; got %s.', mat2str(umPerPixel));
end

% --- resolve the truth: sample-plane gradient <-> DMD-pixel plane ---------
hasPlaneTruth = isfield(options, 'truthTiltPlane') && ~isempty(options.truthTiltPlane);
hasGradTruth  = isfield(options, 'truthDepthGradientUmPerUm') ...
                && ~isempty(options.truthDepthGradientUmPerUm);
if hasPlaneTruth && hasGradTruth
    error('tfp:calibration:measureFocalPlaneTilt_mock:conflictingTruth', ...
        ['Specify the synthetic tilt EITHER as options.truthDepthGradientUmPerUm ' ...
         '(sample plane, preferred) OR as options.truthTiltPlane (raw DMD-pixel ' ...
         'slopes), not both — they would silently disagree.']);
end

Mt = dmdToSampleLinearT_(mapSpec, mapArgs);   % g_px = Mt * g_sample

if hasPlaneTruth
    truthTiltPlane = options.truthTiltPlane;
    if numel(truthTiltPlane) ~= 3
        error('tfp:calibration:measureFocalPlaneTilt_mock:badPlane', ...
            'options.truthTiltPlane must be [a b z0].');
    end
    truthTiltPlane = double(truthTiltPlane(:))';
    truthGradient  = (Mt \ truthTiltPlane(1:2)')';   % report it in sample terms too
else
    % Design tilt by default: entirely along dispersion, none along the grooves.
    truthGradient = configField(options, 'truthDepthGradientUmPerUm', ...
        [model.depthGradientSign * model.depthGradientUmPerUm, 0]);
    if ~isnumeric(truthGradient) || ~isreal(truthGradient) ...
            || ~any(numel(truthGradient) == [1 2]) || ~all(isfinite(truthGradient(:)))
        error('tfp:calibration:measureFocalPlaneTilt_mock:badGradient', ...
            ['options.truthDepthGradientUmPerUm must be a finite scalar ' ...
             '(dispersion only) or a finite 1x2 [dispersion groove].']);
    end
    truthGradient = double(truthGradient(:))';
    if isscalar(truthGradient)
        truthGradient = [truthGradient, 0];
    end
    z0 = configField(options, 'truthZ0Um', 0);
    if ~isnumeric(z0) || ~isscalar(z0) || ~isfinite(z0)
        error('tfp:calibration:measureFocalPlaneTilt_mock:badPlane', ...
            'options.truthZ0Um must be a finite scalar.');
    end
    % Forward map: a sample-plane gradient becomes DMD-pixel slopes.
    truthTiltPlane = [(Mt * truthGradient(:))', double(z0)];
end

nR = dmd.nRows; nC = dmd.nCols;
roiHalfWidth = configField(options, 'roiHalfWidthPx', floor(0.4 * min(nR, nC)));
if isfield(options, 'gridSpacing') && ~isempty(options.gridSpacing)
    gridSpacing = options.gridSpacing;
else
    gridSpacing = 2 * roiHalfWidth / (nGridPoints - 1);
end

half   = floor(nGridPoints / 2);
axis1d = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCols = nC/2 + colOff(:);
dmdRows = nR/2 + rowOff(:);
dmdPts  = [dmdCols, dmdRows];
nPts    = size(dmdPts, 1);

% --- analytic best-focus Z per spot (col/row relative to the DMD centre) ---
a = truthTiltPlane(1); b = truthTiltPlane(2); z0 = truthTiltPlane(3);
xr = colOff(:);   % = dmdCols - nC/2
yr = rowOff(:);   % = dmdRows - nR/2
zBest = z0 + a*xr + b*yr;

plane = fitPlane(xr, yr, zBest);                    % private helper
tilt  = planeTilt(plane, umPerPixel, xr, yr);       % private helper

% Inverse map — the round trip. Recovers truthGradient exactly (to fit
% precision) when the same map was used to synthesise.
sampleTilt = sampleTiltDecomposition_(plane, model, mapSpec, mapArgs);

% --- assemble the same struct shape as the real routine ---
calib.dmdGridPts      = dmdPts;
calib.cameraPts       = nan(nPts, 2);   % no camera in the mock
calib.zSweepUm        = [];
calib.brightness      = [];
calib.sigma           = [];
calib.zBestBrightUm   = zBest;
calib.zBestSharpUm    = zBest;
calib.valid           = true(nPts, 1);
calib.planeBright     = plane;
calib.planeSharp      = plane;
calib.tiltAngleDeg    = tilt.tiltAngleDeg;
calib.tiltAzimuthDeg  = tilt.tiltAzimuthDeg;
calib.tiltAnglesXYDeg = tilt.tiltAnglesXYDeg;
calib.peakToValleyUm  = tilt.peakToValleyUm;
calib.sampleTilt      = sampleTilt;
calib.sampleTiltSharp = sampleTilt;     % same plane in the mock
calib.model           = model;
calib.umPerPixel      = umPerPixel;
calib.nGridPoints     = nGridPoints;
calib.gridSpacingPx   = gridSpacing;
calib.roiHalfWidthPx  = roiHalfWidth;
calib.timestamp       = datetime('now');
calib.notes           = notes;

% Truth actually used, in both representations, so a test (or the real
% routine's MockSubstageCamera) can be driven from exactly this tilt.
calib.truthDepthGradientUmPerUm = truthGradient;
calib.truthTiltPlane            = truthTiltPlane;

% --- compare against design expectation and say what it means ---
if checkExpectation
    expected = tiltExpectation_(model, fieldCurvatureUm);
    chk      = evaluateTiltExpectation_(sampleTilt, expected, tol);
    calib.expected         = expected;
    calib.expectationCheck = chk;
    calib.report           = tiltReport_(sampleTilt, expected, chk);
    if warnOnExpectation
        warnTiltExpectation_(sampleTilt, expected, chk);
    end
    if verbose
        fprintf('%s\n', calib.report);
    end
end
end

% =========================================================================
% SHARED TILT-EXPECTATION BLOCK  (T-BU-3b)
% Everything from here to the closing banner is DUPLICATED VERBATIM in
% measureFocalPlaneTilt.m and measureFocalPlaneTilt_mock.m so each file
% stands alone. MATLAB cannot share local functions across files, and these
% two are not in +private/ (this task owns only the two sources); the repo
% already uses this convention for sampleToDmdOffset/dmdToSampleOffset and
% singleSpot/multiSpot. KEEP THE TWO COPIES BYTE-IDENTICAL — `diff` them
% after editing either one.
%
% The warning identifiers below are deliberately the SAME from both entry
% points, so a test can assert one identifier regardless of whether the real
% routine or the mock produced the plane.
% =========================================================================

function [model, mapSpec, mapArgs] = resolveTiltMap_(options)
%resolveTiltMap_ Optical constants + the DMD->sample map spec from options.
%   options.config / options.model  - a loaded config or an opticalModel struct.
%   options.dmdToSampleLinear       - 2x2/3x3 linear part of a FITTED, um-valued
%                                     DMD->sample affine; supersedes the design
%                                     constants (handoff sec 9).
%   options.mapUnits / .cameraUmPerPixel - forwarded to the units guard in
%                                     tfp.patterns.dmdToSampleOffset.
cfg = configField(options, 'config', configField(options, 'model', struct()));
if ~isstruct(cfg)
    error('tfp:calibration:measureFocalPlaneTilt:badConfig', ...
        ['options.config (or options.model) must be a struct that ' ...
         'tfp.util.opticalModel accepts; got %s.'], class(cfg));
end
model = tfp.util.opticalModel(cfg);

% Design intent unless the caller hands in a fitted map. Note that mapSpec is
% the raw config, not `model`: tfp.patterns.dmdToSampleOffset re-derives the
% constants through tfp.util.opticalModel itself, so both sides of this
% function read the SAME single source of truth.
fitted = configField(options, 'dmdToSampleLinear', []);
if ~isempty(fitted)
    mapSpec = fitted;
else
    mapSpec = cfg;
end

mapArgs = {};
if isfield(options, 'mapUnits') && ~isempty(options.mapUnits)
    mapArgs(end+1:end+2) = {'mapUnits', options.mapUnits};
end
if isfield(options, 'cameraUmPerPixel') && ~isempty(options.cameraUmPerPixel)
    mapArgs(end+1:end+2) = {'cameraUmPerPixel', options.cameraUmPerPixel};
end
end

function Mt = dmdToSampleLinearT_(mapSpec, mapArgs)
%dmdToSampleLinearT_ Transpose of the DMD-px -> sample-um linear map M.
%   Built by pushing the two unit DMD steps through
%   tfp.patterns.dmdToSampleOffset, which is the single implementation of the
%   chip's 45-degree clocking and of the anisotropic axis scales. NEVER build
%   this from a scalar um/px: the sample scale differs by 1.26x between the two
%   chip diagonals and the tilt lives on those diagonals, so a scalar silently
%   mis-states every component of the answer.
%
%   Row k of Mt is the sample offset [x_disp y_groove] (um) produced by a
%   one-pixel step along DMD axis k of [dCol dRow]; i.e. Mt = M'. With depth
%   z = g_s . s and s = M d, the DMD-pixel gradient is g_px = M' * g_s, so
%       forward   g_px = Mt * g_s
%       recover   g_s  = Mt \ g_px
Mt = tfp.patterns.dmdToSampleOffset(eye(2), mapSpec, mapArgs{:});
end

function s = sampleTiltDecomposition_(plane, model, mapSpec, mapArgs)
%sampleTiltDecomposition_ Split a fitted plane into dispersion/groove tilt.
%   THE DIAGNOSTIC THAT MATTERS. The design tilt comes from the temporal-
%   focusing grating, which disperses along ONE chip diagonal, so it is
%   entirely along the dispersion axis and has NO groove-axis component
%   (handoff sec 6). Reporting only a scalar tilt magnitude hides that: a
%   plane tilted the wrong way has the same magnitude as the right one.
s = struct( ...
    'valid',                     false, ...
    'gradientUmPerUm',           [NaN NaN], ...   % [dispersion groove]
    'gradientDispersionUmPerUm', NaN, ...
    'gradientGrooveUmPerUm',     NaN, ...
    'gradientUmPerDmdPx',        [NaN NaN], ...   % [col row], as fitted
    'dispersionDiagonalUmPerPx', NaN, ...
    'grooveDiagonalUmPerPx',     NaN, ...
    'tiltAngleDeg',              NaN, ...
    'tiltDispersionDeg',         NaN, ...
    'tiltGrooveDeg',             NaN, ...
    'azimuthFromDispersionDeg',  NaN, ...
    'grooveFraction',            NaN, ...
    'dispersionWalkUm',          NaN, ...
    'grooveWalkUm',              NaN, ...
    'depthWalkAcrossPatchUm',    NaN);

if ~isstruct(plane) || ~isfield(plane, 'valid') || ~plane.valid ...
        || ~isfield(plane, 'coeffs') || numel(plane.coeffs) < 3 ...
        || ~all(isfinite(plane.coeffs(2:3)))
    return
end

Mt  = dmdToSampleLinearT_(mapSpec, mapArgs);
gPx = double(plane.coeffs(2:3));      % um depth per DMD px, [d/dcol d/drow]
gS  = Mt \ gPx(:);                    % um depth per um sample, [disp groove]

s.valid                     = true;
s.gradientUmPerDmdPx        = gPx(:)';
s.gradientUmPerUm           = gS(:)';
s.gradientDispersionUmPerUm = gS(1);
s.gradientGrooveUmPerUm     = gS(2);

% Depth walk per DMD pixel stepped along each optical diagonal. A one-pixel
% step along (1,1) advances umPerPixelDispersion micrometres at the sample, so
% these are just the sample gradients times the corresponding axis scale.
s.dispersionDiagonalUmPerPx = gS(1) * model.umPerPixelDispersion;
s.grooveDiagonalUmPerPx     = gS(2) * model.umPerPixelGroove;

s.tiltDispersionDeg        = atand(gS(1));
s.tiltGrooveDeg            = atand(gS(2));
s.tiltAngleDeg             = atand(norm(gS));
s.azimuthFromDispersionDeg = atan2d(gS(2), gS(1));
if norm(gS) > 0
    s.grooveFraction = abs(gS(2)) / norm(gS);
else
    s.grooveFraction = 0;
end

% Depth walk over the addressable ellipse: semi-axes patchRadiusPx times each
% axis scale. Over an ellipse the plane's peak-to-valley is
% 2*sqrt((g_d*a_d)^2 + (g_g*a_g)^2), which reduces to the handoff's
% "0.02174 um/um x 787 um = 17.1 um" for the design (groove-free) case.
aDisp   = model.patchRadiusPx * model.umPerPixelDispersion;
aGroove = model.patchRadiusPx * model.umPerPixelGroove;
s.dispersionWalkUm       = 2 * abs(gS(1)) * aDisp;
s.grooveWalkUm           = 2 * abs(gS(2)) * aGroove;
s.depthWalkAcrossPatchUm = 2 * sqrt((gS(1)*aDisp)^2 + (gS(2)*aGroove)^2);
end

function e = tiltExpectation_(model, fieldCurvatureUm)
%tiltExpectation_ Design expectation for the tilt (handoff sec 6).
%   Every number is DERIVED from tfp.util.opticalModel — nothing here is a
%   literal, so a config edit propagates into the comparison automatically.
e.depthGradientUmPerUm     = model.depthGradientUmPerUm;         % 0.02174
e.depthGradientSign        = model.depthGradientSign;            % %VERIFY
e.grooveGradientUmPerUm    = 0;                                  % by design: NONE
e.tiltAngleDeg             = model.focalPlaneTiltDeg;            % 1.245 deg
e.tiltAngleFromGradientDeg = atand(model.depthGradientUmPerUm);
e.diagonalUmPerDmdPx       = model.depthGradientUmPerUm * model.umPerPixelDispersion;
e.dispersionExtentUm       = 2 * model.patchRadiusPx * model.umPerPixelDispersion;
e.grooveExtentUm           = 2 * model.patchRadiusPx * model.umPerPixelGroove;
e.depthWalkAcrossPatchUm   = model.depthGradientUmPerUm * e.dispersionExtentUm;
e.axialFwhmUm              = model.axialFwhmUm;                  % 17.7 um
e.walkInAxialFwhm          = e.depthWalkAcrossPatchUm / model.axialFwhmUm;
e.fieldCurvatureUm         = fieldCurvatureUm;

% The config carries the gradient and the angle separately; they are redundant
% (angle = atand(gradient)). Disagreement means one of them was edited and the
% other left stale, which would make this whole comparison meaningless.
if abs(e.tiltAngleDeg - e.tiltAngleFromGradientDeg) > 0.05
    warning('tfp:calibration:measureFocalPlaneTilt:inconsistentDesign', ...
        ['Design constants disagree: dmd.focalPlaneTiltDeg = %.4f deg but ' ...
         'atand(dmd.depthGradientUmPerUm = %.5g) = %.4f deg. These are ' ...
         'redundant descriptions of the same surface — fix whichever is ' ...
         'stale in the config before trusting the comparison below.'], ...
        e.tiltAngleDeg, e.depthGradientUmPerUm, e.tiltAngleFromGradientDeg);
end
end

function chk = evaluateTiltExpectation_(s, e, tol)
%evaluateTiltExpectation_ Measured-vs-design verdicts (no I/O, all assertable).
chk.valid                    = s.valid;
chk.grooveWalkUm             = s.grooveWalkUm;
chk.grooveWalkToleranceUm    = tol.grooveWalkUm;
chk.grooveComponentOK        = s.valid && abs(s.grooveWalkUm) <= tol.grooveWalkUm;
chk.gradientRatio            = abs(s.gradientDispersionUmPerUm) / e.depthGradientUmPerUm;
chk.gradientToleranceFrac    = tol.gradientFraction;
chk.tiltOK                   = s.valid && abs(chk.gradientRatio - 1) <= tol.gradientFraction;
chk.signMatchesDesign        = s.valid && ...
                               sign(s.gradientDispersionUmPerUm) == e.depthGradientSign;
chk.walkInAxialFwhm          = s.depthWalkAcrossPatchUm / e.axialFwhmUm;
chk.walkFwhmFraction         = tol.walkFwhmFraction;
chk.depthWalkExceedsFwhm     = s.valid && chk.walkInAxialFwhm >= tol.walkFwhmFraction;
chk.passed                   = chk.valid && chk.grooveComponentOK && chk.tiltOK;
end

function warnTiltExpectation_(s, e, chk)
%warnTiltExpectation_ Stable-identifier warnings for every failed verdict.
%   Identifiers (same from the real routine and the mock):
%     ...:noPlane               plane fit failed, nothing to compare
%     ...:grooveComponent       tilt has a groove-axis component (RED FLAG)
%     ...:tiltMismatch          dispersion tilt far from design magnitude
%     ...:tiltSign              tilt runs the other way (usually benign, %VERIFY)
%     ...:depthWalkExceedsFwhm  field is not one focal plane (expected here)
if ~chk.valid
    warning('tfp:calibration:measureFocalPlaneTilt:noPlane', ...
        ['The best-focus plane fit is not valid, so the focal-plane tilt could ' ...
         'not be compared against the design expectation. Check that enough ' ...
         'spots resolved a brightness peak inside the Z sweep.']);
    return
end

if ~chk.grooveComponentOK
    warning('tfp:calibration:measureFocalPlaneTilt:grooveComponent', ...
        ['GROOVE-AXIS TILT COMPONENT — check the mounting. Measured %.5g um ' ...
         'depth per um along the GROOVE axis (%.2f um of depth walk across the ' ...
         '%.0f um groove extent; tolerance %.2f um), which is %.0f%% of the ' ...
         'total gradient.\n' ...
         'The design tilt is ENTIRELY along the DISPERSION axis and has NO ' ...
         'groove-axis component: the temporal-focusing grating disperses along ' ...
         'one chip diagonal only, so it cannot produce a groove-axis tilt. ' ...
         'Objective field curvature contributes only ~%.2g um across the field ' ...
         'and does not explain it either.\n' ...
         'Suspect a mis-clocked DMD, a mis-mounted or mis-oriented grating, or ' ...
         'a tilted sample/film. Do not build depth targeting on this ' ...
         'measurement until it is understood.'], ...
        s.gradientGrooveUmPerUm, s.grooveWalkUm, e.grooveExtentUm, ...
        chk.grooveWalkToleranceUm, 100 * s.grooveFraction, e.fieldCurvatureUm);
end

if ~chk.tiltOK
    warning('tfp:calibration:measureFocalPlaneTilt:tiltMismatch', ...
        ['Measured DISPERSION-axis depth gradient is %.5g um/um (tilt %.3f deg), ' ...
         '%.2fx the design %.5g um/um (%.3f deg) — outside the +/-%.0f%% band. ' ...
         'The design numbers are intent, not calibration (handoff sec 9), so a ' ...
         'few percent is fine; a factor like this usually means the optics are ' ...
         'installed differently from the document (the periscope lens order is ' ...
         'the known unconfirmed item) or the Z sweep did not bracket best focus.'], ...
        s.gradientDispersionUmPerUm, s.tiltDispersionDeg, chk.gradientRatio, ...
        e.depthGradientUmPerUm, e.tiltAngleFromGradientDeg, ...
        100 * chk.gradientToleranceFrac);
end

if ~chk.signMatchesDesign && chk.tiltOK
    warning('tfp:calibration:measureFocalPlaneTilt:tiltSign', ...
        ['Depth increases along %+d on the dispersion axis, the design config ' ...
         'says %+d (dmd.depthGradientSign). That key is an unresolved bench ' ...
         'convention (%%VERIFY), so this is most likely just the sign being ' ...
         'settled by measurement — set dmd.depthGradientSign = %+d in the rig ' ...
         'config so downstream depth compensation runs the right way.'], ...
        sign(s.gradientDispersionUmPerUm), e.depthGradientSign, ...
        sign(s.gradientDispersionUmPerUm));
end

if chk.depthWalkExceedsFwhm
    warning('tfp:calibration:measureFocalPlaneTilt:depthWalkExceedsFwhm', ...
        ['THE FIELD IS NOT ONE FOCAL PLANE. Best focus walks %.1f um in depth ' ...
         'across the patch, which is %.2f of the %.1f um axial FWHM. Two ' ...
         'targets at opposite edges of the field are therefore NOT in the same ' ...
         'plane, and a single objective Z cannot put both in focus.\n' ...
         'On this build that is expected, not a fault: there is no PLM, so the ' ...
         'tilt cannot be corrected optically. Apply a per-target depth offset ' ...
         'z_um = x_disp * %.5g, or keep an ensemble inside one axial FWHM ' ...
         '(about %.0f um along the dispersion axis).'], ...
        s.depthWalkAcrossPatchUm, chk.walkInAxialFwhm, e.axialFwhmUm, ...
        s.gradientDispersionUmPerUm, ...
        e.axialFwhmUm / max(abs(s.gradientDispersionUmPerUm), eps));
end
end

function report = tiltReport_(s, e, chk)
%tiltReport_ Experimenter-facing text: the comparison, and what it MEANS.
%   Returned as a field (calib.report) rather than printed, so it is
%   assertable; the callers print it only when asked to.
L = {};
L{end+1} = 'Focal-plane tilt vs design expectation (docs/dmd_control_handoff.md sec 6)';
L{end+1} = '-----------------------------------------------------------------------';
if ~s.valid
    L{end+1} = '  Plane fit invalid — no comparison possible.';
    report = strjoin(L, newline);
    return
end
L{end+1} = sprintf('  %-34s %12s %12s', '', 'measured', 'design');
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um depth per um', ...
    'gradient, DISPERSION axis', s.gradientDispersionUmPerUm, ...
    e.depthGradientSign * e.depthGradientUmPerUm);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um depth per um', ...
    'gradient, GROOVE axis', s.gradientGrooveUmPerUm, e.grooveGradientUmPerUm);
L{end+1} = sprintf('  %-34s %12.3f %12.3f   deg', ...
    'surface tilt', s.tiltAngleDeg, e.tiltAngleDeg);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um per DMD px', ...
    'along the (1,1) dispersion diagonal', s.dispersionDiagonalUmPerPx, ...
    e.depthGradientSign * e.diagonalUmPerDmdPx);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um per DMD px', ...
    'along the (1,-1) groove diagonal', s.grooveDiagonalUmPerPx, 0);
L{end+1} = sprintf('  %-34s %12.1f %12.1f   um', ...
    'depth walk across the patch', s.depthWalkAcrossPatchUm, e.depthWalkAcrossPatchUm);
L{end+1} = sprintf('  %-34s %12.1f %12.1f   um', ...
    'axial FWHM', e.axialFwhmUm, e.axialFwhmUm);
L{end+1} = sprintf('  %-34s %12.2f %12.2f', ...
    'walk / axial FWHM', chk.walkInAxialFwhm, e.walkInAxialFwhm);
L{end+1} = '';

% --- in words -----------------------------------------------------------
L{end+1} = '  IN WORDS:';
if chk.depthWalkExceedsFwhm
    L{end+1} = sprintf(['    The field is NOT one focal plane. Best focus walks %.1f um ' ...
        'in depth across'], s.depthWalkAcrossPatchUm);
    L{end+1} = sprintf(['    the patch, comparable to the %.1f um axial FWHM (%.2f of ' ...
        'it). A target at one'], e.axialFwhmUm, chk.walkInAxialFwhm);
    L{end+1} =         '    edge of the field and a target at the other are genuinely NOT in the same';
    L{end+1} =         '    plane, and no single objective Z brings both into focus. There is no PLM';
    L{end+1} =         '    on this build, so this cannot be corrected optically — apply a per-target';
    L{end+1} = sprintf(['    depth offset z_um = x_disp * %.5g, or keep an ensemble within about ' ...
        '%.0f um'], s.gradientDispersionUmPerUm, ...
        e.axialFwhmUm / max(abs(s.gradientDispersionUmPerUm), eps));
    L{end+1} =         '    along the dispersion axis.';
else
    L{end+1} = sprintf(['    Depth walk across the patch is %.1f um, only %.2f of the %.1f um axial ' ...
        'FWHM,'], s.depthWalkAcrossPatchUm, chk.walkInAxialFwhm, e.axialFwhmUm);
    L{end+1} =         '    so the whole field can be treated as one focal plane.';
end
L{end+1} = '';
if chk.grooveComponentOK
    L{end+1} =         '    The tilt is along the dispersion axis, as designed: the groove-axis';
    L{end+1} = sprintf(['    walk is %.2f um (tolerance %.2f um), consistent with the ~%.2g um the ' ...
        'objective''s field'], s.grooveWalkUm, chk.grooveWalkToleranceUm, e.fieldCurvatureUm);
    L{end+1} =         '    curvature contributes.';
else
    L{end+1} =         '    RED FLAG — the tilt has a GROOVE-AXIS COMPONENT, which the design has none';
    L{end+1} = sprintf(['    of. It walks %.2f um along the groove axis (%.0f%% of the total ' ...
        'gradient),'], s.grooveWalkUm, 100 * s.grooveFraction);
    L{end+1} = sprintf(['    far beyond the ~%.2g um objective field curvature can explain. The ' ...
        'grating'], e.fieldCurvatureUm);
    L{end+1} =         '    disperses along ONE chip diagonal, so it cannot produce this: suspect a';
    L{end+1} =         '    mis-clocked DMD, a mis-mounted grating, or a tilted sample/film.';
end
if ~chk.tiltOK
    L{end+1} = '';
    L{end+1} = sprintf(['    The dispersion-axis gradient is %.2fx the design value — outside the ' ...
        '+/-%.0f%%'], chk.gradientRatio, 100 * chk.gradientToleranceFrac);
    L{end+1} =         '    band. The design numbers are intent, not calibration; check the optics';
    L{end+1} =         '    against the handoff (the periscope lens order is the known unknown).';
end
report = strjoin(L, newline);
end

function value = configField(s, name, default)
%configField Repo-standard config/options read with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
% =========================================================================
% END SHARED TILT-EXPECTATION BLOCK
% =========================================================================
