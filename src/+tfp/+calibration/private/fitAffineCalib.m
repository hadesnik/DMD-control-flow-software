function calib = fitAffineCalib(dmdPts, measuredPts, rejected)
%fitAffineCalib Fit a 2D affine from DMD pixel coords to camera pixel coords.
%   Shared private helper used by alignDMDtoCamera and calibrationGUI.
%
%   dmdPts:      nPts×2 [col row] DMD pixel coordinates
%   measuredPts: nPts×2 [x y]    camera pixel coordinates
%   rejected:    nPts×1 logical; true = exclude from fit (optional)
%
%   Output struct fields:
%     .dmdToSample_affine  3×3: [x;y;1] = A * [u;v;1]  (column-vector form)
%     .residualErrorPx     RMS residual over accepted points (px)
%     .nAccepted           number of accepted non-NaN points used
%     .residualsPerPt      nAcc×1 per-point Euclidean residuals (px)
%     .dmdPtsAccepted      nAcc×2 DMD coords of points used in fit
%     .imgPtsAccepted      nAcc×2 measured camera coords of those points
%     .imgPtsPredicted     nAcc×2 affine-predicted camera coords
%
%   Throws tfp:calibration:fitAffineCalib:tooFewPoints if fewer than 4
%   accepted, finite-measured points are available.

if nargin < 3 || isempty(rejected)
    rejected = false(size(dmdPts, 1), 1);
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
end

% -------------------------------------------------------------------------

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
