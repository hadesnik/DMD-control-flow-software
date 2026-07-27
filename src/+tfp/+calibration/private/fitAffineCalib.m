function calib = fitAffineCalib(dmdPts, measuredPts, rejected, options)
%fitAffineCalib Fit a 2D affine from DMD pixel coords to camera pixel coords.
%   Shared private helper used by alignDMDtoCamera, calibrationGUI and
%   crossRegisterScanImage.
%
%   calib = fitAffineCalib(dmdPts, measuredPts)
%   calib = fitAffineCalib(dmdPts, measuredPts, rejected)
%   calib = fitAffineCalib(dmdPts, measuredPts, rejected, options)
%
%   dmdPts:      nPts×2 [col row] DMD pixel coordinates
%   measuredPts: nPts×2 [x y]    camera pixel coordinates
%   rejected:    nPts×1 logical; true = exclude from fit (optional)
%   options:     optional struct, see "Scale check" below. Omitting it leaves
%                every pre-existing behaviour unchanged.
%
%   Output struct fields:
%     .dmdToSample_affine  3×3: [x;y;1] = A * [u;v;1]  (column-vector form)
%     .residualErrorPx     RMS residual over accepted points (px)
%     .nAccepted           number of accepted non-NaN points used
%     .residualsPerPt      nAcc×1 per-point Euclidean residuals (px)
%     .dmdPtsAccepted      nAcc×2 DMD coords of points used in fit
%     .imgPtsAccepted      nAcc×2 measured camera coords of those points
%     .imgPtsPredicted     nAcc×2 affine-predicted camera coords
%     .scaleCheck          struct, the diagnostic described below (always
%                          present; additive, existing fields are untouched)
%
%   Throws tfp:calibration:fitAffineCalib:tooFewPoints if fewer than 4
%   accepted, finite-measured points are available.
%
%   ---------------------------------------------------------------------
%   SCALE CHECK (T-BU-3a). §9 of docs/dmd_control_handoff.md asks the control
%   code to fit its OWN affine from a measured grid and to use the design
%   constants of §5 only as an expected starting point and a sanity check. The
%   fit above is already 6-DOF, so it absorbs the chip's 45° clocking and the
%   1.2588 anisotropy for free. This is the missing check.
%
%   An SVD of the fitted linear part gives the two principal scales (the
%   singular values) and the principal DIRECTIONS. Three independent things
%   are compared against tfp.util.opticalModel:
%
%     1. ANISOTROPY — the RATIO of the two singular values. This is the robust
%        discriminator: it is invariant to every pure magnification in the
%        chain (periscope, tube lens, objective, camera pixel size all cancel),
%        so a wrong ratio cannot be blamed on any of them. It follows from the
%        grating's installed incidence angle (§9), so a wrong ratio points at
%        the grating mounting, and a RIGHT ratio with a WRONG absolute scale
%        points at magnification instead.
%     2. ABSOLUTE SCALE — the geometric mean of the singular values. Several
%        distinct errors predict a scale error and they are NOT separable from
%        one scalar; the diagnostic enumerates them rather than picking one
%        (see "Honest ambiguity" below).
%     3. CLOCKING — the direction, IN THE DMD FRAME, of the axis that is
%        stretched most. §5 says the optical axes are the chip DIAGONALS, so it
%        should sit at 45° or 135° from the DMD column axis. Taken from the
%        right singular vectors deliberately: those live in the DMD frame, so
%        the check is immune to however the substage camera happens to be
%        mounted. The overall camera-frame rotation is REPORTED
%        (.rotationDeg) but never checked, because the camera's mounting angle
%        is arbitrary and no document pins it.
%
%   UNITS. This function fits DMD px -> substage CAMERA px, not µm (the output
%   field name `dmdToSample_affine` is a known misnomer; TASKS.md T-BU-M0).
%   The design constants are µm per DMD px, so they are divided by the camera
%   pixel size before comparison: the expected singular values are
%   ~1.1250/1.56 = 0.72 and ~1.4162/1.56 = 0.91 camera px per DMD px. Getting
%   that division wrong would make the check itself the bug.
%
%   HONEST AMBIGUITY. T-BU-2e established, for tfp.patterns.sampleToDmdOffset,
%   that the camera-pixel factor (1.56) and the periscope-reversal factor
%   (1.778, handoff §9) are only ~14% apart, so an absolute scale alone CANNOT
%   tell "wrong units" from "periscope installed the other way round" — and the
%   two errors partially cancel, so their combination is only 1.14× off and
%   will not be flagged at all. The same limit applies here. The scale warning
%   therefore lists every candidate factor, marks each one that fits, and says
%   plainly when more than one does. It never asserts a single cause.
%
%   options fields (all optional, read with the repo's configField convention):
%     .scaleCheck        'auto' (default) | 'dmd' | 'off'.
%                        'dmd'  — the caller declares this is a DMD -> camera
%                                 fit; check unconditionally and warn on any
%                                 disagreement.
%                        'off'  — compute nothing, warn nothing.
%                        'auto' — compute the diagnostic, but warn ONLY if the
%                                 fit is recognisable as this optical path in
%                                 at least one of the two independent
%                                 quantities (scale, anisotropy) while being
%                                 wrong in the other. Rationale: this helper is
%                                 shared with crossRegisterScanImage, which
%                                 fits ScanImage scan-field px -> camera px and
%                                 has no business being measured against a DMD
%                                 model. When BOTH quantities are off, auto
%                                 cannot tell a badly wrong DMD fit from a
%                                 perfectly good non-DMD fit, so it stays quiet
%                                 and records .skipReason. Pass 'dmd' from a
%                                 DMD call site to remove that blind spot.
%     .config            anything tfp.util.opticalModel accepts (a full loaded
%                        config, or a bare dmd sub-struct) — the expectation to
%                        compare against. Default: the documented design
%                        constants.
%     .cameraUmPerPixel  µm per substage-camera pixel (default: config
%                        camera.umPerPixel, else 1.56).
%     .scaleTolerance        ratio band for the absolute scale, >1
%                            (default sqrt(min(cameraUm, reversal)) ≈ 1.25 —
%                            the geometric midpoint to the nearest competing
%                            hypothesis, the same construction
%                            tfp.patterns.sampleToDmdOffset uses).
%     .anisotropyTolerance   relative band for the ratio (default 0.10).
%     .clockingToleranceDeg  band for the principal-axis angle (default 5).
%     .context           char tag naming the caller, e.g. '[alignDMDtoCamera]',
%                        prefixed to every warning (same convention as
%                        tfp.util.assertPatternInPatch).
%
%   .scaleCheck output fields:
%     .performed .mode .skipReason .context .residualErrorPx
%     .singularValuesCamPxPerDmdPx  [major minor] observed
%     .singularValuesUmPerDmdPx     the same × cameraUmPerPixel
%     .expectedCamPxPerDmdPx        [dispersion groove] / cameraUmPerPixel
%     .expectedUmPerDmdPx           [dispersion groove] from opticalModel
%     .cameraUmPerPixel
%     .anisotropy .anisotropyExpected .anisotropyError (relative)
%     .scaleObservedCamPxPerDmdPx .scaleExpectedCamPxPerDmdPx .scaleRatio
%     .principalAxisDmdDeg .clockingExpectedDeg .clockingDeviationDeg
%     .rotationDeg .isReflected     (camera-frame, informational only)
%     .hypotheses                   struct array .factor .fits .label
%     .nHypothesesFitting
%     .scaleOk .anisotropyOk .clockingOk
%     .warningsIssued               cellstr of the identifiers emitted
%     .summary                      the full human-readable report, present
%                                   even when nothing warned, so a caller that
%                                   suppressed the warnings can still print it
%
%   Warnings (stable identifiers; nothing here ever throws — a fitted affine is
%   entitled to disagree with design intent, and refusing to return the fit
%   would be worse than saying so loudly):
%     tfp:calibration:fitAffineCalib:suspiciousScale
%     tfp:calibration:fitAffineCalib:suspiciousAnisotropy
%     tfp:calibration:fitAffineCalib:suspiciousClocking
%   Errors:
%     tfp:calibration:fitAffineCalib:tooFewPoints
%     tfp:calibration:fitAffineCalib:unsupportedTform
%     tfp:calibration:fitAffineCalib:badOption
%
%   See also tfp.util.opticalModel, tfp.patterns.sampleToDmdOffset,
%            tfp.calibration.alignDMDtoCamera.

if nargin < 3 || isempty(rejected)
    rejected = false(size(dmdPts, 1), 1);
end
if nargin < 4 || isempty(options)
    options = struct();
end

accepted = ~logical(rejected(:));
dmdAcc   = dmdPts(accepted, :);
imgAcc   = measuredPts(accepted, :);

% Drop rows where the measured coordinate was never recorded (NaN).
valid  = all(isfinite(imgAcc), 2);
dmdAcc = dmdAcc(valid, :);
imgAcc = imgAcc(valid, :);
nAcc   = size(dmdAcc, 1);

if nAcc < 4
    error('tfp:calibration:fitAffineCalib:tooFewPoints', ...
        'Need at least 4 accepted, finite-measured points for affine fit; got %d.', nAcc);
end

tform              = fitgeotrans(dmdAcc, imgAcc, 'affine');
dmdToSample_affine = extractAffineMatrix(tform);

homDMD    = [dmdAcc, ones(nAcc, 1)]';
imgPred   = (dmdToSample_affine * homDMD)';
imgPred   = imgPred(:, 1:2);
residuals = sqrt(sum((imgAcc - imgPred).^2, 2));

calib.dmdToSample_affine = dmdToSample_affine;
calib.residualErrorPx    = sqrt(mean(residuals.^2));
calib.nAccepted          = nAcc;
calib.residualsPerPt     = residuals;
calib.dmdPtsAccepted     = dmdAcc;
calib.imgPtsAccepted     = imgAcc;
calib.imgPtsPredicted    = imgPred;

% Additive diagnostic; see the header. Emits warnings, never throws.
calib.scaleCheck = runScaleCheck(dmdToSample_affine, options, calib.residualErrorPx);
end

% =========================================================================

function A = extractAffineMatrix(tform)
% Row-vector convention → column-vector convention: A = T'
%   fitgeotrans/affine2d/affinetform2d use  [xo yo 1] = [xi yi 1] * T
%   Our convention:                          [xo;yo;1] = A * [xi;yi;1]
if isa(tform, 'affinetform2d')
    A = tform.A';
elseif isa(tform, 'affine2d')
    A = tform.T';
else
    error('tfp:calibration:fitAffineCalib:unsupportedTform', ...
        'Unrecognized fitgeotrans output type: %s.', class(tform));
end
end

% =========================================================================
% Scale check
% =========================================================================

function chk = runScaleCheck(A, options, residualErrorPx)
%runScaleCheck SVD sanity check of a fitted DMD->camera affine (T-BU-3a).
%   Pure except for the warnings it raises. Returns the full diagnostic so a
%   caller that suppressed the warnings can still read or log it.
%   residualErrorPx is carried through only so the messages can say how much
%   the fit itself can be trusted before a tolerance is tightened.

opts = parseCheckOptions(options);

chk                 = struct();
chk.performed       = false;
chk.mode            = opts.mode;
chk.context         = opts.context;
chk.residualErrorPx = residualErrorPx;
chk.skipReason      = '';
chk.warningsIssued = {};
chk.summary    = '';

if strcmp(opts.mode, 'off')
    chk.skipReason = 'scaleCheck was set to ''off''.';
    return
end

M = A(1:2, 1:2);
if ~all(isfinite(M(:))) || rcond(M) < 1e-12
    chk.skipReason = sprintf(['the fitted linear part is singular or ' ...
        'non-finite (rcond = %g); its principal scales are not defined.'], rcond(M));
    return
end

% --- expectation -------------------------------------------------------
model = expectedModel(opts.config);
c     = cameraUmPerPixel(opts.config, opts, model);
f     = configField(model, 'periscopeReversalFactor', (200/150)^2);

expUm  = sort([model.umPerPixelDispersion, model.umPerPixelGroove], 'descend');
expCam = expUm / c;                       % µm/DMDpx over µm/campx = campx/DMDpx

% --- observation -------------------------------------------------------
% Singular values are the two principal scales in camera px per DMD px; they
% are invariant to the chip clocking and to whatever camera rotation the fit
% absorbed, which is what makes them comparable with the two design scales.
[U, S, V] = svd(M);
sObs      = [S(1,1), S(2,2)];             % svd returns them descending

chk.performed                   = true;
chk.cameraUmPerPixel            = c;
chk.singularValuesCamPxPerDmdPx = sObs;
chk.singularValuesUmPerDmdPx    = sObs * c;
chk.expectedCamPxPerDmdPx       = expCam;
chk.expectedUmPerDmdPx          = expUm;

chk.anisotropy         = sObs(1) / sObs(2);
chk.anisotropyExpected = expUm(1) / expUm(2);
chk.anisotropyError    = chk.anisotropy / chk.anisotropyExpected - 1;

chk.scaleObservedCamPxPerDmdPx = sqrt(sObs(1) * sObs(2));
chk.scaleExpectedCamPxPerDmdPx = sqrt(expCam(1) * expCam(2));
chk.scaleRatio = chk.scaleObservedCamPxPerDmdPx / chk.scaleExpectedCamPxPerDmdPx;

% Principal axis IN THE DMD FRAME: V(:,1) is the source-frame direction that
% gets stretched most, i.e. the dispersion diagonal by design. Angles are
% mod 180 because a singular vector and its negation describe the same axis.
chk.clockingExpectedDeg = configField(model, 'clockingDeg', 45);
chk.principalAxisDmdDeg = mod(atan2d(V(2,1), V(1,1)), 180);
if chk.anisotropy >= 1.05
    % Distance to the nearest chip diagonal (45° + k*90°).
    d = mod(chk.principalAxisDmdDeg - chk.clockingExpectedDeg, 90);
    chk.clockingDeviationDeg = min(d, 90 - d);
else
    % Near-isotropic: the principal directions are ill-conditioned and the
    % angle is meaningless. Do not pretend to measure it.
    chk.clockingDeviationDeg = NaN;
end

% Camera-frame rotation, informational only (see header): the substage
% camera's mounting angle is arbitrary, so there is nothing to compare it with.
R = U * V';
chk.isReflected = det(M) < 0;
if det(R) < 0
    R = U * diag([1, -1]) * V';           % strip the reflection to get an angle
end
chk.rotationDeg = atan2d(R(2,1), R(1,1));

% --- verdicts ----------------------------------------------------------
chk.scaleTolerance       = opts.scaleTolerance;
chk.anisotropyTolerance  = opts.anisotropyTolerance;
chk.clockingToleranceDeg = opts.clockingToleranceDeg;

chk.scaleOk      = ratioWithin(chk.scaleRatio, 1, opts.scaleTolerance);
chk.anisotropyOk = abs(chk.anisotropyError) <= opts.anisotropyTolerance;
chk.clockingOk   = isnan(chk.clockingDeviationDeg) || ...
                   chk.clockingDeviationDeg <= opts.clockingToleranceDeg;

[chk.hypotheses, chk.nHypothesesFitting] = scaleHypotheses(chk.scaleRatio, ...
    c, f, opts.scaleTolerance);

% --- report and warn ---------------------------------------------------
chk.summary = buildSummary(chk, c, f);

if strcmp(opts.mode, 'auto') && ~chk.scaleOk && ~chk.anisotropyOk
    % Nothing about this fit says "DMD through the bring-up path". It could be
    % the scan-field fit crossRegisterScanImage makes with the same helper, or
    % a mock affine in a test. Staying quiet is the honest answer; a DMD call
    % site that wants the check regardless passes scaleCheck = 'dmd'.
    chk.skipReason = ['neither the absolute scale nor the anisotropy matches ' ...
        'the DMD bring-up model, so in ''auto'' mode this fit is not assumed ' ...
        'to be a DMD -> camera fit at all (this helper is shared with ' ...
        'crossRegisterScanImage). Pass options.scaleCheck = ''dmd'' to check ' ...
        'unconditionally.'];
    return
end

if ~chk.anisotropyOk
    chk.warningsIssued{end+1} = emitAnisotropyWarning(chk);
end
if ~chk.scaleOk
    chk.warningsIssued{end+1} = emitScaleWarning(chk, c, f);
end
if ~chk.clockingOk
    chk.warningsIssued{end+1} = emitClockingWarning(chk);
end
end

% -------------------------------------------------------------------------

function [hyp, nFits] = scaleHypotheses(r, c, f, tol)
%scaleHypotheses Candidate explanations for an off-nominal absolute scale.
%   Each entry predicts a factor by which the FITTED camera-valued scale would
%   exceed the design expectation. The list is not exhaustive and, critically,
%   its entries are not separable from one scalar — see buildSummary.
labels = { ...
    1,   'the optics installed exactly as docs/dmd_control_handoff.md describes'; ...
    f,   sprintf(['the 200/150 periscope installed the other way round, i.e. ' ...
                  'every µm-per-pixel figure x%.4g (handoff sec 9; TASKS.md ' ...
                  'T-BU-M1)'], f); ...
    1/f, sprintf(['the handoff constants themselves already assuming the ' ...
                  'reversed periscope while the rig has it as drawn (x1/%.4g)'], f); ...
    c,   sprintf(['measured points supplied in SAMPLE MICROMETRES rather than ' ...
                  'substage-camera pixels, or camera.umPerPixel = %.4g µm ' ...
                  'being wrong (a µm-valued fit is %.4gx the camera-valued one)'], c, c); ...
    0.5, ['the camera frame being 2x2 binned or otherwise decimated, halving ' ...
          'every camera-pixel scale']};

nFits = 0;
hyp   = struct('factor', {}, 'fits', {}, 'label', {});
for k = 1:size(labels, 1)
    predicted = labels{k, 1};
    fits      = ratioWithin(r, predicted, tol);
    nFits     = nFits + double(fits);
    hyp(end+1) = struct('factor', predicted, 'fits', fits, ...
        'label', labels{k, 2}); %#ok<AGROW>
end
end

function tf = ratioWithin(observed, predicted, tol)
%ratioWithin True when observed/predicted is inside [1/tol, tol].
q  = observed / predicted;
tf = max(q, 1/q) <= tol;
end

% -------------------------------------------------------------------------

function s = buildSummary(chk, c, f)
%buildSummary The human-readable diagnostic, shared by warnings and .summary.
s = sprintf([ ...
    '  observed principal scales: %.4g and %.4g camera px per DMD px ' ...
    '(= %.4g and %.4g µm per DMD px at %.4g µm/camera px)\n' ...
    '  expected principal scales: %.4g and %.4g camera px per DMD px ' ...
    '(= %.4g and %.4g µm per DMD px)\n' ...
    '  anisotropy (major/minor): observed %.4g vs expected %.4g (%+.1f%%)\n' ...
    '  overall scale: %.4gx the expectation\n' ...
    '  principal (max-stretch) axis in the DMD frame: %.1f deg from the ' ...
    'column axis; the chip diagonals are %.1f and %.1f deg\n' ...
    '  camera-frame rotation %.1f deg%s — REPORTED ONLY, never checked: the ' ...
    'substage camera''s mounting angle is arbitrary.\n'], ...
    chk.singularValuesCamPxPerDmdPx(1), chk.singularValuesCamPxPerDmdPx(2), ...
    chk.singularValuesUmPerDmdPx(1),    chk.singularValuesUmPerDmdPx(2), c, ...
    chk.expectedCamPxPerDmdPx(1),       chk.expectedCamPxPerDmdPx(2), ...
    chk.expectedUmPerDmdPx(1),          chk.expectedUmPerDmdPx(2), ...
    chk.anisotropy, chk.anisotropyExpected, 100 * chk.anisotropyError, ...
    chk.scaleRatio, ...
    chk.principalAxisDmdDeg, chk.clockingExpectedDeg, chk.clockingExpectedDeg + 90, ...
    chk.rotationDeg, ternaryStr(chk.isReflected, ' (with a reflection)', ''));
s = [s sprintf(['  candidate factors for the overall scale ' ...
    '(camera pixel %.4g vs periscope reversal %.4g differ by only %.0f%%):\n'], ...
    c, f, 100 * (max(c, f) / min(c, f) - 1))];
for k = 1:numel(chk.hypotheses)
    s = [s sprintf('    predicts %.4g : %s%s\n', chk.hypotheses(k).factor, ...
        chk.hypotheses(k).label, ternaryStr(chk.hypotheses(k).fits, ...
        '  <== FITS', ''))]; %#ok<AGROW>
end
end

function id = emitScaleWarning(chk, c, f)
%emitScaleWarning Absolute scale is off. Enumerate, never diagnose alone.
id = 'tfp:calibration:fitAffineCalib:suspiciousScale';

if chk.nHypothesesFitting >= 2
    verdict = sprintf([ ...
        'MORE THAN ONE explanation fits, and overall scale alone CANNOT tell ' ...
        'them apart — the camera pixel (%.4g) and the periscope reversal ' ...
        '(%.4g) differ by only %.0f%%. This diagnostic therefore does NOT ' ...
        'claim the periscope is reversed. Settle it at the rig: read the ' ...
        'periscope lens labels (TASKS.md T-BU-M1 — faster than any fit), and ' ...
        'confirm the camera pixel size with a known-distance measurement. ' ...
        'Separating them by fit alone would need options.scaleTolerance below ' ...
        '%.3g, which is only defensible if the residuals support it (they are ' ...
        '%.3g px RMS here).'], ...
        c, f, 100 * (max(c, f) / min(c, f) - 1), sqrt(max(c, f) / min(c, f)), ...
        chk.residualErrorPx);
elseif chk.nHypothesesFitting == 1
    which = find([chk.hypotheses.fits], 1);
    if ismember(chk.hypotheses(which).factor, [f, 1/f])
        lead = ['On this evidence the periscope APPEARS TO BE INSTALLED ' ...
                'REVERSED relative to docs/dmd_control_handoff.md (TASKS.md ' ...
                'T-BU-M1) — it is the only listed factor that fits. '];
    else
        lead = sprintf('Only one listed factor fits — %.4g, "%s". ', ...
            chk.hypotheses(which).factor, chk.hypotheses(which).label);
    end
    verdict = [lead sprintf([ ...
        'Read it as the LEADING HYPOTHESIS TO CHECK, not as a measurement: ' ...
        'this is one scalar, the listed factors are not exhaustive (a ' ...
        'mis-stated tube-lens focal length, TASKS.md T-BU-M2, is not on the ' ...
        'list), and the neighbouring factors are close enough (%.4g vs %.4g, ' ...
        '%.0f%% apart) that a slightly different tolerance would admit them ' ...
        'too. Note also the blind spot T-BU-2e recorded: a µm-valued grid on ' ...
        'a reversed periscope lands only %.3gx from nominal and would not ' ...
        'have been flagged at all.'], ...
        c, f, 100 * (max(c, f) / min(c, f) - 1), f / c)];
else
    verdict = ['NONE of the listed factors fits. The measured grid may be in ' ...
        'units this check does not know about, the spot detection may have ' ...
        'mis-assigned points, or the fit is simply bad. Do not project ' ...
        'targets through this affine until it is understood.'];
end

if chk.anisotropyOk
    interp = sprintf([ ...
        'The anisotropy IS right (%.4g vs %.4g expected) while the absolute ' ...
        'scale is not. That pattern points at MAGNIFICATION, not at the ' ...
        'grating: the ratio of the two principal scales cancels every pure ' ...
        'magnification in the chain (periscope, tube lens, objective, camera ' ...
        'pixel size), so a correct ratio with a wrong scale is exactly what a ' ...
        'magnification error looks like. '], ...
        chk.anisotropy, chk.anisotropyExpected);
else
    interp = sprintf([ ...
        'The anisotropy is ALSO off (%.4g vs %.4g expected), so this is not a ' ...
        'clean magnification error — a pure magnification change cancels in ' ...
        'the ratio and would have left it correct. Suspect the grating ' ...
        'mounting angle, or the fit itself, before the factors below. '], ...
        chk.anisotropy, chk.anisotropyExpected);
end

warnf(id, ['%sthe fitted DMD -> camera affine is %.4gx the overall scale ' ...
    'tfp.util.opticalModel expects, outside the [%.3g, %.3g] band this check ' ...
    'treats as the documented optics.\n%s%s%s\n' ...
    '  To silence once the scale is understood: warning(''off'', ''%s'').'], ...
    contextPrefix(chk), chk.scaleRatio, 1 / chk.scaleTolerance, ...
    chk.scaleTolerance, chk.summary, interp, verdict, id);
end

function id = emitAnisotropyWarning(chk)
%emitAnisotropyWarning The ratio is the robust discriminator; say why.
id = 'tfp:calibration:fitAffineCalib:suspiciousAnisotropy';
warnf(id, ['%sthe fitted anisotropy (ratio of the two principal scales) is ' ...
    '%.4g, but tfp.util.opticalModel expects %.4g — %+.1f%%, outside the ' ...
    '%.0f%% band.\n%s' ...
    '  The RATIO is the robust discriminator here, and it has just failed. It ' ...
    'is invariant to every pure magnification in the chain (periscope, tube ' ...
    'lens, objective, camera pixel size all cancel), so NONE of those can ' ...
    'explain it and the units of the measured grid cannot either. What does ' ...
    'move it is the grating: handoff sec 9 — "the anamorphic factor follows ' ...
    'from the grating''s installed incidence angle; a degree of mounting ' ...
    'error moves it". Check the grating mounting first, then the grid/centroid ' ...
    'detection. A wrong ratio and a right absolute scale is a grating story; ' ...
    'a right ratio and a wrong scale is a magnification story (see ' ...
    'tfp:calibration:fitAffineCalib:suspiciousScale).\n' ...
    '  To silence: warning(''off'', ''%s'').'], ...
    contextPrefix(chk), chk.anisotropy, chk.anisotropyExpected, ...
    100 * chk.anisotropyError, 100 * chk.anisotropyTolerance, chk.summary, id);
end

function id = emitClockingWarning(chk)
%emitClockingWarning Principal axes are not on the chip diagonals.
id = 'tfp:calibration:fitAffineCalib:suspiciousClocking';
warnf(id, ['%sthe most-stretched axis of the fitted affine lies %.1f deg from ' ...
    'the DMD column axis, %.1f deg away from the nearest chip diagonal ' ...
    '(%.1f / %.1f deg) and outside the %.1f deg band.\n%s' ...
    '  Handoff sec 5 says the optical axes ARE the chip diagonals, because the ' ...
    'chip is clocked %.1f deg. This angle is measured in the DMD frame (from ' ...
    'the right singular vectors), so it does NOT depend on how the substage ' ...
    'camera is mounted — a rotated camera cannot cause it. A real deviation ' ...
    'means the chip clocking or the grating orientation differs from the ' ...
    'document, and every anisotropic spot shape (tfp.patterns.singleSpot in ' ...
    'anisotropic mode) is being pre-compensated along the wrong diagonal.\n' ...
    '  To silence: warning(''off'', ''%s'').'], ...
    contextPrefix(chk), chk.principalAxisDmdDeg, chk.clockingDeviationDeg, ...
    chk.clockingExpectedDeg, chk.clockingExpectedDeg + 90, ...
    chk.clockingToleranceDeg, chk.summary, chk.clockingExpectedDeg, id);
end

function warnf(id, fmt, varargin)
%warnf Format first, then emit with a literal '%s'.
%   The report text carries user-supplied numbers and must never be
%   re-interpreted as a format string.
warning(id, '%s', sprintf(fmt, varargin{:}));
end

function p = contextPrefix(chk)
if isempty(chk.context)
    p = 'fitAffineCalib: ';
else
    p = sprintf('%s fitAffineCalib: ', chk.context);
end
end

function s = ternaryStr(tf, a, b)
if tf
    s = a;
else
    s = b;
end
end

% -------------------------------------------------------------------------

function opts = parseCheckOptions(options)
%parseCheckOptions Validate the optional scale-check options.
if ~isstruct(options)
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options must be a struct; got %s.', class(options));
end

opts.config  = configField(options, 'config', struct());
opts.context = configField(options, 'context', '');
if isstring(opts.context) && isscalar(opts.context)
    opts.context = char(opts.context);
end
if ~ischar(opts.context)
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options.context must be char/string; got %s.', class(opts.context));
end
if ~isstruct(opts.config)
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options.config must be a struct tfp.util.opticalModel accepts; got %s.', ...
        class(opts.config));
end

mode = configField(options, 'scaleCheck', 'auto');
if isstring(mode) && isscalar(mode)
    mode = char(mode);
end
if ~ischar(mode)
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options.scaleCheck must be char/string; got %s.', class(mode));
end
switch lower(strtrim(mode))
    case {'auto', 'unknown'}
        opts.mode = 'auto';
    case {'dmd', 'on', 'dmd_px', 'true'}
        opts.mode = 'dmd';
    case {'off', 'none', 'false'}
        opts.mode = 'off';
    otherwise
        error('tfp:calibration:fitAffineCalib:badOption', ...
            ['options.scaleCheck must be ''auto'', ''dmd'' or ''off''; got ' ...
             '''%s''.'], strtrim(mode));
end

opts.cameraUmPerPixel = checkOptionalPositive(options, 'cameraUmPerPixel');

% Default scale band: the geometric midpoint between "as documented" (1) and
% the nearest competing hypothesis. Same construction as the sibling guard in
% tfp.patterns.sampleToDmdOffset, so the two agree about what "off" means.
% Deliberately loose (~25%) against the "a few percent" handoff sec 9 calls
% normal, so an honest fit stays quiet.
model      = expectedModel(opts.config);
nearestHyp = min(cameraUmPerPixel(opts.config, ...
                     struct('cameraUmPerPixel', opts.cameraUmPerPixel), model), ...
                 configField(model, 'periscopeReversalFactor', (200/150)^2));
opts.scaleTolerance = configField(options, 'scaleTolerance', sqrt(nearestHyp));
if opts.scaleTolerance <= 1
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options.scaleTolerance is a ratio band and must exceed 1; got %g.', ...
        opts.scaleTolerance);
end

opts.anisotropyTolerance  = configField(options, 'anisotropyTolerance',  0.10);
opts.clockingToleranceDeg = configField(options, 'clockingToleranceDeg', 5);
checkPositiveScalar(opts.scaleTolerance,       'scaleTolerance');
checkPositiveScalar(opts.anisotropyTolerance,  'anisotropyTolerance');
checkPositiveScalar(opts.clockingToleranceDeg, 'clockingToleranceDeg');
end

function v = checkOptionalPositive(options, name)
v = configField(options, name, []);
if ~isempty(v)
    checkPositiveScalar(v, name);
    v = double(v);
end
end

function checkPositiveScalar(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~isreal(v) || ~isfinite(v) || v <= 0
    error('tfp:calibration:fitAffineCalib:badOption', ...
        'options.%s must be a positive finite real scalar.', name);
end
end

function model = expectedModel(cfg)
%expectedModel Design constants to compare the fit against.
%   Uses the caller's own config when supplied (a rig that knows its scales
%   differ from the document should not be nagged), and never lets a malformed
%   config turn this warning path into an error.
try
    model = tfp.util.opticalModel(cfg);
catch
    model = tfp.util.opticalModel();
end
end

function c = cameraUmPerPixel(cfg, opts, model)
%cameraUmPerPixel µm per substage-camera pixel — the units bridge.
%   This function fits DMD px -> CAMERA px, so the µm-valued design scales must
%   be divided by this before they can be compared. Order of preference:
%   explicit option > the caller's config (camera.umPerPixel) >
%   tfp.util.opticalModel if the field ever moves there (T-BU-M0) > default.
if isfield(opts, 'cameraUmPerPixel') && ~isempty(opts.cameraUmPerPixel)
    c = double(opts.cameraUmPerPixel);
    return
end
%ASSUMED 1.56 µm per camera pixel — configs/real.yaml camera.umPerPixel, the
% same default tfp.calibration.alignDMDtoCamera and
% tfp.patterns.sampleToDmdOffset use. It is not in tfp.util.opticalModel today;
% the configField chain picks it up automatically on the day it lands there.
c = configField(configField(cfg, 'camera', struct()), 'umPerPixel', ...
        configField(model, 'cameraUmPerPixel', 1.56));
if ~isnumeric(c) || ~isscalar(c) || ~isreal(c) || ~isfinite(c) || c <= 0
    c = 1.56;
end
c = double(c);
end

function value = configField(s, name, default)
%configField Repo-standard config read with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
