function result = SyntheticImaging(cells, patternMask, frameTimestamps, ...
                                    stimOnsetSec, stimDurationSec, calibration)
%SyntheticImaging Build a mock suite2p Fall.mat-like struct for one trial.
%
%   result = SyntheticImaging(cells, patternMask, frameTimestamps,
%                             stimOnsetSec, stimDurationSec)
%   result = SyntheticImaging(..., calibration)
%
%   cells:           array of tfp.sim.CellResponseModel objects
%   patternMask:     logical(nRows, nCols), active DMD pattern for this trial
%   frameTimestamps: 1×T double, imaging frame times (s)
%   stimOnsetSec:    scalar, stim onset time within trial (s)
%   stimDurationSec: scalar, stim on-duration (s)
%   calibration:     (optional) calibration struct; if absent, a linear
%                    DMD-to-imaging-pixel scale is used for stat.med coords
%
%   Returns result struct mirroring suite2p's Fall.mat:
%     result.F      nCells × T   raw fluorescence (arb. units; baseline 1000)
%     result.Fneu   nCells × T   neuropil estimate (constant per-cell baseline)
%     result.iscell nCells × 2   [1, 0.9] for all cells
%     result.stat   1 × nCells   struct with .med = [row col] in imaging pixels
%     result.ops    struct        .fs, .Ly, .Lx (frame rate and FOV size)

%ASSUMED imaging parameters (must match mock.yaml imaging section)
FS = 30;   % Hz
LY = 512;  % imaging rows
LX = 512;  % imaging cols

%ASSUMED DMD geometry for default coordinate scaling (no calibration provided)
DMD_NROWS = 800;
DMD_NCOLS = 1280;

%ASSUMED baseline fluorescence = 1000 arbitrary units; ΔF/F scaled by same value
BASELINE = 1000;

if nargin < 6
    calibration = [];
end

nCells          = numel(cells);
frameTimestamps = double(frameTimestamps(:)');
T               = numel(frameTimestamps);

% --- ops ---
result.ops.fs = FS;
result.ops.Ly = LY;
result.ops.Lx = LX;

% --- F: raw fluorescence ---
%   F(i,t) = BASELINE + dff(i,t) * BASELINE so F is always positive
F = zeros(nCells, T);
for i = 1:nCells
    dff       = cells(i).computeTrace(patternMask, frameTimestamps, ...
                                       stimOnsetSec, stimDurationSec);
    F(i, :)   = BASELINE + dff(:)' * BASELINE;
end
result.F = F;

% --- Fneu: neuropil estimate ---
%ASSUMED neuropil = 0.7 × per-cell mean F (constant across time),
%   approximating a uniform neuropil contribution as in suite2p default
Fneu = zeros(nCells, T);
for i = 1:nCells
    Fneu(i, :) = 0.7 * mean(F(i, :));
end
result.Fneu = Fneu;

% --- iscell ---
%ASSUMED all fake cells classified as real, high classifier probability
result.iscell = repmat([1, 0.9], nCells, 1);

% --- stat: cell positions in imaging pixel coordinates ---
stat(1, nCells) = struct('med', []);  % pre-allocate as 1×nCells struct array
for i = 1:nCells
    pos = cells(i).positionDmd;  % [col, row] in DMD pixels
    if ~isempty(calibration) && isfield(calibration, 'dmdToSample_affine')
        % Apply 3×3 affine: [u v 1] * M' → [x y 1] (sample µm)
        uvh    = [pos(1), pos(2), 1];
        xy     = uvh * calibration.dmdToSample_affine';
        %ASSUMED 800 µm FOV / 512 px = 1.5625 µm per imaging pixel
        umPerPx = 800 / 512;
        imgCol  = round(xy(1) / umPerPx) + LX / 2;
        imgRow  = round(xy(2) / umPerPx) + LY / 2;
    else
        %ASSUMED linear scale: DMD pixel grid → imaging pixel grid
        imgCol = round((pos(1) - 1) / (DMD_NCOLS - 1) * (LX - 1)) + 1;
        imgRow = round((pos(2) - 1) / (DMD_NROWS - 1) * (LY - 1)) + 1;
    end
    stat(i).med = [imgRow, imgCol];  % suite2p convention: [row, col]
end
result.stat = stat;
end
