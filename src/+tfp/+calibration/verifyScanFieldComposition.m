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
%       .spotRadiusPx   DMD spot radius in pixels          default 5
%       .fovSizeUm      scan FOV width in µm               default 800
%       .mockResponse   [fastSign, slowSign] to bypass input() — for automated tests
%       .showFigure     print summary table (default true unless mockResponse set)
%
%   Output: calib with updated fields:
%     .scan_fast_axis_sign    ±1 (confirmed from operator input or mockResponse)
%     .scan_slow_axis_sign    ±1 (confirmed)
%     .dmdToScan_affine       sign-corrected affine (DMD → scan-field)
%     .scanVerified           true
%     .scanVerifyTimestamp    datetime
%
%   If no sign combination is confirmed the function issues a warning and
%   returns the unchanged calib (scanVerified remains false/absent).
%
%   See also tfp.calibration.crossRegisterScanImage,
%            tfp.calibration.composeCalibration.

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
spotR      = configField(options, 'spotRadiusPx',   5);
mockResp   = configField(options, 'mockResponse',  []);
showFig    = logical(configField(options, 'showFigure', isempty(mockResp)));

testCoord  = configField(options, 'testDmdCoord', [dmd.nCols/2, dmd.nRows/2]);
testCol    = round(testCoord(1));
testRow    = round(testCoord(2));

if spotR < 1 || spotR > 50 || spotR ~= round(spotR)
    error('tfp:calibration:verifyScanFieldComposition:badSpotRadius', ...
        'spotRadiusPx must be an integer in [1,50]; got %g.', spotR);
end

% ---------------------------------------------------------------------------
% Project a single DMD spot at the test coordinate
% ---------------------------------------------------------------------------
[cc, rr] = meshgrid(1:dmd.nCols, 1:dmd.nRows);
pattern  = logical((cc - testCol).^2 + (rr - testRow).^2 <= spotR^2);

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
    fprintf('DMD test spot: col=%d, row=%d  (spot radius=%d DMD px)\n\n', ...
        testCol, testRow, spotR);
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
