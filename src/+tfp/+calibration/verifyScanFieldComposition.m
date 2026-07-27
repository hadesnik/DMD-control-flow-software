function calib = verifyScanFieldComposition(dmd, calib, options)
%verifyScanFieldComposition Interactive axis-sign verification for DMD→scan-field mapping.
%   After crossRegisterScanImage the scan_fast_axis_sign and scan_slow_axis_sign
%   are NaN because a single passive camera image cannot reveal which end of
%   each scan axis corresponds to scan-field pixel index 1. This function
%   disambiguates the signs through an operator-guided spot-check.
%
%   PROCEDURE (operator):
%     1. Ensure the fluorescent film is in place and ScanImage is in Focus mode.
%     2. Call this function. It will project a DMD spot and print a table of
%        predicted ScanImage mROI positions for all four sign combinations.
%     3. For each combination (in order), position a small ScanImage mROI at
%        the printed µm coordinate and confirm [y/n] whether the DMD spot
%        appears centred in the live image.
%     4. On the first 'y' answer the signs are confirmed, dmdToScan_affine is
%        updated, and the function returns. Typically resolved in ≤ 2 attempts.
%     5. Write the confirmed signs into your rig config YAML:
%          scan_fast_axis_sign: +1   # or -1
%          scan_slow_axis_sign: +1   # or -1
%
%   AXIS SIGN CONVENTION:
%     scan_fast_axis_sign = +1 means scan-field fast pixel 1 maps to the
%     LEFT edge of the camera bounding box. sign = -1 means it maps to the
%     RIGHT edge (fast axis is physically reversed).
%     Likewise for slow_axis_sign and the TOP vs BOTTOM of the bbox.
%
%   calib = verifyScanFieldComposition(dmd, calib)
%   calib = verifyScanFieldComposition(dmd, calib, options)
%
%   Inputs:
%     dmd     — tfp.hardware.DMD (real or mock), initialised.
%               Must support loadPatternSequence / armSequence / advanceToPattern.
%     calib   — struct from crossRegisterScanImage (or composeCalibration).
%               Required fields: .dmdToScan_affine (3×3), .scanPixels ([nFast nSlow]).
%     options — struct (all fields optional):
%       .testDmdCoord   [col, row] DMD pixel to project   default [nCols/2, nRows/2]
%       .spotDiameterUm test-spot DIAMETER at the SAMPLE plane, µm  default 25
%                       (see "spot sizing" below)
%       .spotRadiusPx   DEPRECATED. DMD spot radius in pixels. When given it
%                       overrides .spotDiameterUm and draws the historical
%                       isotropic pixel circle, so old callers are unchanged.
%                       Must still be an integer in [1,50]. Prefer
%                       .spotDiameterUm.
%       .opticalConfig  config struct forwarded to tfp.util.opticalModel for
%                       the µm→DMD-px conversion. Default: design constants.
%       .fovSizeUm      scan FOV width in µm               default 800
%       .mockResponse   [fastSign, slowSign] to bypass input() — for automated tests
%       .showFigure     print summary table (default true unless mockResponse set)
%
%   SPOT SIZING — this spot only has to be FOUND, not to resolve anything.
%     The old default was a bare `spotRadiusPx = 5` DMD pixels, picked against
%     the retired pre-optics guess of 0.270 µm/px. At the real bring-up scale
%     (1.1250 µm/px along the grooves, 1.4162 µm/px along dispersion, chip
%     clocked 45°) that pixel circle is an 11.2 × 14.2 µm ellipse at the
%     sample — accidentally about one soma, and small enough that an operator
%     hunting for it in a live ScanImage mROI could easily miss it and answer
%     [n] to the CORRECT sign combination.
%
%     The job here is an unambiguous yes/no from a human looking at a live 2p
%     image, so the spot is deliberately made LARGER than a target: 25 µm
%     diameter, comfortably above soma scale, still ~3% of the 625 × 787 µm
%     addressable field and ~0.13% fill inside the illuminated patch (so the
%     pupil pulse-energy interlock is nowhere near being exercised). It is
%     drawn anisotropically, so what the operator looks for is a ROUND spot —
%     a visibly elliptical one now means something is wrong with the optics,
%     not with the pattern generator. Size is stated in sample µm and converted
%     by tfp.patterns.somaSpotGeometry, so a future optics change rescales it
%     automatically instead of silently changing the test.
%
%   Output: calib with updated fields:
%     .scan_fast_axis_sign    ±1 (confirmed from operator input or mockResponse)
%     .scan_slow_axis_sign    ±1 (confirmed)
%     .dmdToScan_affine       sign-corrected affine (DMD → scan-field)
%     .scanVerified           true
%     .scanVerifyTimestamp    datetime
%     .verifySpotDiameterUm   sample-plane diameter of the test spot (µm), or
%                             NaN when a deprecated .spotRadiusPx was supplied
%
%   If no sign combination is confirmed the function issues a warning and
%   returns the unchanged calib (scanVerified remains false/absent).
%
%   See also tfp.calibration.crossRegisterScanImage,
%            tfp.calibration.composeCalibration,
%            tfp.patterns.somaSpotGeometry.

% ---------------------------------------------------------------------------
% Validate inputs
% ---------------------------------------------------------------------------
if nargin < 3 || isempty(options)
    options = struct();
end

if ~isfield(calib, 'dmdToScan_affine') || isempty(calib.dmdToScan_affine)
    error('tfp:calibration:verifyScanFieldComposition:missingAffine', ...
        ['calib.dmdToScan_affine is missing or empty. ' ...
         'Run crossRegisterScanImage (or composeCalibration) first.']);
end
if ~isfield(calib, 'scanPixels') || numel(calib.scanPixels) ~= 2
    error('tfp:calibration:verifyScanFieldComposition:missingPixels', ...
        'calib.scanPixels is missing or invalid. Run crossRegisterScanImage first.');
end

nFast      = calib.scanPixels(1);
nSlow      = calib.scanPixels(2);
fovSizeUm  = configField(options, 'fovSizeUm',    800);
mockResp   = configField(options, 'mockResponse',  []);
showFig    = logical(configField(options, 'showFigure', isempty(mockResp)));

% Spot sizing: ask in sample µm (see the header). A supplied .spotRadiusPx is
% the deprecated pixel-count form and still wins, so existing callers and rig
% scripts are byte-identical.
spotDiameterUm = configField(options, 'spotDiameterUm', 25);   %ASSUMED comfortably visible in a live 2p mROI
legacyRadiusPx = configField(options, 'spotRadiusPx',   []);
opticalConfig  = configField(options, 'opticalConfig',  struct());

testCoord  = configField(options, 'testDmdCoord', [dmd.nCols/2, dmd.nRows/2]);
testCol    = round(testCoord(1));
testRow    = round(testCoord(2));

% ---------------------------------------------------------------------------
% Test-spot geometry
% ---------------------------------------------------------------------------
% Preferred path: a stated sample-plane diameter -> anisotropic DMD ellipse, so
% the operator is looking for a ROUND spot. Per T-BU-1f the positional radius
% singleSpot takes in anisotropic mode is the GROOVE-axis (long) semi-axis;
% geom.spotOptions carries it explicitly. geom.radiusPx is the area-matched
% ISOTROPIC fallback for circle-only call sites and must NOT be passed here —
% doing so paints ~17% fewer mirrors with no error anywhere.
if isempty(legacyRadiusPx)
    spotGeom       = tfp.patterns.somaSpotGeometry(spotDiameterUm, opticalConfig);
    spotDiameterUm = spotGeom.diameterUm;
    spotR          = spotGeom.semiAxisGroovePx;
    spotOpts       = spotGeom.spotOptions;
else
    spotR = legacyRadiusPx;
    if ~isnumeric(spotR) || ~isscalar(spotR) || spotR < 1 || spotR > 50 ...
            || spotR ~= round(spotR)
        error('tfp:calibration:verifyScanFieldComposition:badSpotRadius', ...
            'spotRadiusPx must be an integer in [1,50]; got %s.', ...
            num2str(legacyRadiusPx));
    end
    spotR          = double(spotR);
    spotGeom       = [];
    spotOpts       = struct();      % historical isotropic pixel circle
    spotDiameterUm = NaN;
end

% Optical constants, for reporting the deprecated path's true sample size.
% tfp.util.opticalModel is the single source of truth — never hardcode the
% µm/px numbers here (TASK-BU T-BU-0).
optModel = tfp.util.opticalModel(opticalConfig);

% ---------------------------------------------------------------------------
% Project a single DMD spot at the test coordinate
% ---------------------------------------------------------------------------
% singleSpot's default (isotropic) branch is the same inclusive pixel circle
% this function used to build inline, so the deprecated path is unchanged.
pattern = tfp.patterns.singleSpot(dmd, [testCol, testRow], spotR, spotOpts);

seqOpts.exposureUs = 100000;   % 100 ms on-time
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(pattern, seqOpts);
dmd.armSequence();
dmd.advanceToPattern(1);

% ---------------------------------------------------------------------------
% Compute base scan-field prediction (no sign correction applied yet)
% ---------------------------------------------------------------------------
basePred = calib.dmdToScan_affine * [testCol; testRow; 1];

% ---------------------------------------------------------------------------
% Build all four sign combinations and predicted mROI positions
% ---------------------------------------------------------------------------
% Sign correction (1-indexed scan pixels):
%   fast_sign = -1: fast_corrected = nFast + 1 - fast_predicted
%   slow_sign = -1: slow_corrected = nSlow + 1 - slow_predicted
signCombinations = [1  1; -1  1;  1 -1; -1 -1];
signLabels       = {'(+1, +1)', '(-1, +1)', '(+1, -1)', '(-1, -1)'};
nCombos          = 4;

preds = zeros(nCombos, 2);   % [fast_px, slow_px]
for k = 1:nCombos
    p = applySignCorrection(basePred, signCombinations(k,1), signCombinations(k,2), nFast, nSlow);
    preds(k,:) = [p(1), p(2)];
end

% Physical µm coordinates (origin at scan-field centre)
% Physical pixel pitch = fovSizeUm / nFast along both axes (square FOV)
umPerPx = fovSizeUm / nFast;
predUm  = [(preds(:,1) - (nFast+1)/2), (preds(:,2) - (nSlow+1)/2)] * umPerPx;

% ---------------------------------------------------------------------------
% Print summary table
% ---------------------------------------------------------------------------
if showFig
    fprintf('\n[verifyScanFieldComposition] === Axis sign verification ===\n');
    if isfinite(spotDiameterUm)
        fprintf(['DMD test spot: col=%d, row=%d  (%.3g µm round at the sample ' ...
                 '= %.1f x %.1f DMD px, %d mirrors)\n\n'], ...
            testCol, testRow, spotDiameterUm, spotGeom.semiAxisGroovePx, ...
            spotGeom.semiAxisDispersionPx, nnz(pattern));
    else
        fprintf(['DMD test spot: col=%d, row=%d  (deprecated spotRadiusPx=%g, ' ...
                 'a %.1f x %.1f µm ELLIPSE at the sample)\n\n'], ...
            testCol, testRow, spotR, ...
            2 * spotR * optModel.umPerPixelGroove, ...
            2 * spotR * optModel.umPerPixelDispersion);
    end
    fprintf('  Sign combination (fast,slow)   fast_px  slow_px    x_um    y_um\n');
    fprintf('  %s\n', repmat('-', 1, 62));
    for k = 1:nCombos
        fprintf('  %-30s  %7.1f  %7.1f  %7.1f  %7.1f\n', ...
            signLabels{k}, preds(k,1), preds(k,2), predUm(k,1), predUm(k,2));
    end
    fprintf('\n');
    fprintf('For each combination in order:\n');
    fprintf('  Set a small ScanImage mROI at the printed (x_um, y_um) coordinate.\n');
    fprintf('  Answer [y] if the DMD spot is centred in the mROI, [n] to try next.\n\n');
end

% ---------------------------------------------------------------------------
% Iterate through combinations and request operator confirmation
% ---------------------------------------------------------------------------
confirmedK = [];
for k = 1:nCombos
    fs = signCombinations(k,1);
    ss = signCombinations(k,2);

    if showFig
        fprintf('  [%d/4] Signs %s  →  mROI center: x=%.1f µm, y=%.1f µm\n', ...
            k, signLabels{k}, predUm(k,1), predUm(k,2));
        fprintf('        (scan-field pixel: fast=%.1f, slow=%.1f)\n', preds(k,1), preds(k,2));
    end

    if ~isempty(mockResp)
        % Automated-test path: confirm when this combination matches mockResponse
        if mockResp(1) == fs && mockResp(2) == ss
            response = 'y';
            if showFig
                fprintf('        [mock] auto-confirmed for signs (%+d, %+d).\n', fs, ss);
            end
        else
            response = 'n';
        end
    else
        response = strtrim(lower(input( ...
            '        Is the DMD spot centred in this mROI? [y/n]: ', 's')));
    end

    if strcmp(response, 'y') || strcmp(response, 'yes')
        confirmedK = k;
        break;
    end
end

% ---------------------------------------------------------------------------
% Handle no-confirmation case
% ---------------------------------------------------------------------------
if isempty(confirmedK)
    warning('tfp:calibration:verifyScanFieldComposition:noConfirmation', ...
        ['No sign combination was confirmed. Check that the DMD spot is visible.\n' ...
         'calib.scan_fast_axis_sign and .scan_slow_axis_sign remain unchanged.\n' ...
         'Re-run verifyScanFieldComposition with the spot visible.']);
    return;
end

% ---------------------------------------------------------------------------
% Apply confirmed sign correction to dmdToScan_affine and update calib
% ---------------------------------------------------------------------------
confirmedFastSign = signCombinations(confirmedK, 1);
confirmedSlowSign = signCombinations(confirmedK, 2);

corrFast = eye(3);
if confirmedFastSign < 0
    corrFast = [-1  0  (nFast+1); 0  1  0; 0  0  1];
end
corrSlow = eye(3);
if confirmedSlowSign < 0
    corrSlow = [1  0  0; 0  -1  (nSlow+1); 0  0  1];
end

calib.dmdToScan_affine    = corrFast * corrSlow * calib.dmdToScan_affine;
calib.scan_fast_axis_sign = confirmedFastSign;
calib.scan_slow_axis_sign = confirmedSlowSign;
calib.scanVerified        = true;
calib.scanVerifyTimestamp = datetime('now');
% Record what the operator was actually looking at — a sign confirmed against a
% 5 px dot and one confirmed against a 25 µm disc are not equally trustworthy.
calib.verifySpotDiameterUm = spotDiameterUm;

if showFig
    fprintf('\n[verifyScanFieldComposition] Confirmed: fast_sign=%+d, slow_sign=%+d\n', ...
        confirmedFastSign, confirmedSlowSign);
    fprintf('[verifyScanFieldComposition] calib.dmdToScan_affine updated with sign correction.\n');
    fprintf('[verifyScanFieldComposition] Write these into your rig config YAML:\n');
    fprintf('    scan_fast_axis_sign: %+d\n', confirmedFastSign);
    fprintf('    scan_slow_axis_sign: %+d\n', confirmedSlowSign);
    fprintf('[verifyScanFieldComposition] ================================\n\n');
end

end

% =========================================================================
% Local helpers
% =========================================================================

function corrPred = applySignCorrection(basePred, fastSign, slowSign, nFast, nSlow)
%applySignCorrection  Apply axis-sign correction to a base scan-field prediction.
corrFast = eye(3);
if fastSign < 0
    corrFast = [-1  0  (nFast+1); 0  1  0; 0  0  1];
end
corrSlow = eye(3);
if slowSign < 0
    corrSlow = [1  0  0; 0  -1  (nSlow+1); 0  0  1];
end
corrPred = corrFast * corrSlow * basePred;
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
