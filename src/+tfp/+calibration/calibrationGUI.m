function calib = calibrationGUI(dmd, camera, siBridge, options)
%calibrationGUI Interactive live-update GUI for DMD→substage-camera calibration.
%   Projects a grid of spots, snaps the substage camera after each, detects
%   centroids in real time, and fits a 2D affine transform with a live
%   4-panel figure. Wraps the same core logic as alignDMDtoCamera.
%
%   calib = calibrationGUI(dmd, camera)
%   calib = calibrationGUI(dmd, camera, siBridge)
%   calib = calibrationGUI(dmd, camera, siBridge, options)
%
%   dmd:      tfp.hardware.DMD-derived object, already initialised
%   camera:   tfp.hardware.SubstageCamera-derived object, already initialised
%   siBridge: tfp.hardware.ScanImageBridge object, or [] to skip SI panel
%   options:  struct — same fields as alignDMDtoCamera options
%
%   Figure layout (1400×800, 2×2 subplot grid):
%     [1,1] Substage camera image with red × at detected centroid
%     [1,2] ScanImage frame with red × at centroid (or placeholder)
%     [2,1] Affine residual scatter — green/yellow/red by error magnitude
%     [2,2] Progress dashboard (text + Pause / Reject / Save / Close buttons)
%
%   Figure errors never crash the calibration loop (wrapped in try/catch).
%   Hardware calls are not wrapped — failures propagate to the caller.
%
%   Requires Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 3, siBridge = [];     end
if nargin < 4, options  = struct(); end

% --- parse options (same defaults as alignDMDtoCamera) ---
nGridPoints = configField(options, 'nGridPoints', 5);
gridSpacing = configField(options, 'gridSpacing', 100);
spotRadius  = configField(options, 'spotRadius',  8);
exposureS   = configField(options, 'exposureS',   0.1);
umPerPixel  = configField(options, 'umPerPixel',  1.56);
notes       = configField(options, 'notes', 'DMD-to-camera calibration (GUI)');

% --- validate ---
if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:calibrationGUI:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:calibrationGUI:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~camera.isInitialized
    error('tfp:calibration:calibrationGUI:cameraNotInitialized', ...
        'camera must be initialized before calling calibrationGUI.');
end
if ~dmd.isInitialized
    error('tfp:calibration:calibrationGUI:dmdNotInitialized', ...
        'dmd must be initialized before calling calibrationGUI.');
end

nPts = nGridPoints^2;

% --- build grid of DMD coordinates (row-major, col varies fastest) ---
half      = floor(nGridPoints / 2);
axis1d    = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCoords = [dmd.nCols/2 + colOff(:),  dmd.nRows/2 + rowOff(:)];   % nPts×2

% --- build and load pattern sequence ---
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:,:,k) = tfp.patterns.singleSpot(dmd, dmdCoords(k,:), spotRadius);
end
seqOpts.exposureUs = round(max(exposureS, 0) * 1e6);
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(patterns, seqOpts);
dmd.armSequence();

% --- create figure ---
hFig = figure( ...
    'Name',            'DMD Calibration — Live Monitor', ...
    'NumberTitle',     'off', ...
    'Tag',             'tfp_calib_gui', ...
    'Position',        [50 50 1400 800], ...
    'CloseRequestFcn', @onClose);

hAxes = gobjects(1, 4);
for k = 1:4
    hAxes(k) = subplot(2, 2, k);
end

% Flush so subplot Position properties are populated before button layout.
drawnow();

% --- create buttons in the lower third of the panel [2,2] axes area ---
apos = hAxes(4).Position;   % [x y w h] in normalised figure units
bh   = max(0.035, apos(4) * 0.13);
bw   = apos(3)  * 0.44;
bx1  = apos(1);
bx2  = apos(1)  + apos(3) * 0.53;
by1  = apos(2)  + 0.005;
by2  = apos(2)  + bh + 0.012;

hBtnPause = uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
    'String', 'Pause', 'Units', 'normalized', ...
    'Position', [bx1 by2 bw bh], 'FontSize', 9);
set(hBtnPause, 'Callback', @(~,~) cbPauseResume(hFig, hBtnPause));

uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
    'String', 'Reject point', 'Units', 'normalized', ...
    'Position', [bx2 by2 bw bh], 'FontSize', 9, ...
    'Callback', @(~,~) setappdata(hFig, 'rejectCurrent', true));

hBtnSave = uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
    'String', 'Save calibration', 'Units', 'normalized', ...
    'Position', [bx1 by1 bw bh], 'FontSize', 9, ...
    'Enable', 'off', ...
    'Callback', @(~,~) cbSave(hFig));

uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
    'String', 'Close', 'Units', 'normalized', ...
    'Position', [bx2 by1 bw bh], 'FontSize', 9, ...
    'Callback', @(~,~) onClose(hFig, []));

% --- initialise shared state via figure appdata ---
setappdata(hFig, 'pauseFlag',     false);
setappdata(hFig, 'rejectCurrent', false);
setappdata(hFig, 'calib',         []);

% --- per-loop state ---
measuredPts = NaN(nPts, 2);
rejectedPts = false(nPts, 1);
rmsError    = NaN;
startTime   = tic;
calib       = struct();

% Initial placeholder renders
try
    updateSubstagePanel(hAxes(1), [], [], 0, nPts, [NaN NaN]);
    updateScanImagePanel(hAxes(2), [], [], 0, nPts);
    updateResidualPanel(hAxes(3), struct(), NaN);
    updateProgressPanel(hAxes(4), 0, nPts, 0, 0, NaN, startTime, 'Initialising...');
    drawnow();
catch
end

% =========================================================================
% Main calibration loop
% =========================================================================
for k = 1:nPts

    % Guard: figure may have been closed by the user
    if ~ishghandle(hFig)
        warning('tfp:calibration:calibrationGUI:figClosed', ...
            'Calibration figure closed at point %d — aborting.', k);
        calib = struct();
        return;
    end

    % Pause handling
    while ishghandle(hFig) && getappdata(hFig, 'pauseFlag')
        pause(0.1);
        drawnow();
    end
    if ~ishghandle(hFig), calib = struct(); return; end

    % Reset reject flag for this point
    setappdata(hFig, 'rejectCurrent', false);

    % Project spot
    try
        updateStatus(hAxes(4), k, nPts, 'Projecting...');
        drawnow();
    catch
    end
    dmd.advanceToPattern(k);
    if exposureS > 0
        pause(exposureS);
    end

    % Snap substage camera
    try, updateStatus(hAxes(4), k, nPts, 'Snapping substage camera...'); drawnow(); catch, end
    img      = camera.snap();
    centroid = [];
    try
        centroid = findSpotCentroid(img, k);
    catch ME
        warning('tfp:calibration:calibrationGUI:centroidFail', ...
            'Point %d: centroid detection failed — %s', k, ME.message);
    end
    try
        updateSubstagePanel(hAxes(1), img, centroid, k, nPts, dmdCoords(k,:));
        drawnow();
    catch
    end

    % ScanImage frame (optional)
    if ~isempty(siBridge) && ishghandle(hFig)
        try, updateStatus(hAxes(4), k, nPts, 'Getting ScanImage frame...'); drawnow(); catch, end
        siImg      = getScanImageFrame(siBridge);
        siCentroid = [];
        if ~isempty(siImg)
            try, siCentroid = findSpotCentroid(siImg, k); catch, end
        end
        try
            updateScanImagePanel(hAxes(2), siImg, siCentroid, k, nPts);
            drawnow();
        catch
        end
    end

    % Store point (unless rejected by button press or failed centroid)
    rejected       = ishghandle(hFig) && getappdata(hFig, 'rejectCurrent');
    rejectedPts(k) = rejected || isempty(centroid);
    if ~rejectedPts(k)
        measuredPts(k,:) = centroid;
    end

    nAccepted = sum(~rejectedPts(1:k));
    nRejected = sum(rejectedPts(1:k));

    % Running affine fit — update residual panel once ≥4 accepted points
    if nAccepted >= 4
        try
            partialCalib = fitAffineCalib(dmdCoords(1:k,:), measuredPts(1:k,:), rejectedPts(1:k));
            rmsError     = partialCalib.residualErrorPx;
            updateResidualPanel(hAxes(3), partialCalib, rmsError);
        catch
            % not enough finite measured pts yet — skip silently
        end
    end

    try
        updateProgressPanel(hAxes(4), k, nPts, nAccepted, nRejected, rmsError, startTime, 'Measuring...');
        drawnow();
    catch
    end
end

% =========================================================================
% Final fit
% =========================================================================
nAcceptedFinal = sum(~rejectedPts);
if nAcceptedFinal >= 4
    calib = fitAffineCalib(dmdCoords, measuredPts, rejectedPts);
    calib.umPerPixel         = umPerPixel;
    calib.pixelsPerUm        = 1 / umPerPixel;
    calib.powerCurve         = struct();
    calib.timestamp          = datetime('now');
    calib.notes              = notes;
    calib.nCalibrationPoints = nPts;

    if ishghandle(hFig)
        setappdata(hFig, 'calib', calib);
        set(hBtnSave, 'Enable', 'on');
        doneMsg = sprintf('Done. RMS=%.2f px. Click Save to save.', calib.residualErrorPx);
        try
            updateResidualPanel(hAxes(3), calib, calib.residualErrorPx);
            updateProgressPanel(hAxes(4), nPts, nPts, nAcceptedFinal, ...
                sum(rejectedPts), calib.residualErrorPx, startTime, doneMsg);
            drawnow();
        catch
        end
    end
else
    warning('tfp:calibration:calibrationGUI:tooFewAccepted', ...
        'Only %d accepted points (need >= 4) — cannot fit affine.', nAcceptedFinal);
    calib = struct();
end

end

% =========================================================================
% Panel updaters
% =========================================================================

function updateSubstagePanel(ax, img, centroid, k, nTotal, dmdCoord)
%updateSubstagePanel Render the substage camera image with centroid marker.
cla(ax);
if isempty(img)
    text(0.5, 0.5, 'Waiting for camera...', ...
        'HorizontalAlignment', 'center', 'Units', 'normalized', ...
        'Parent', ax, 'Color', [0.5 0.5 0.5], 'FontSize', 10);
    title(ax, 'Substage camera');
    return;
end
imagesc(ax, img);
colormap(ax, gray);
axis(ax, 'image');
set(ax, 'XTick', [], 'YTick', []);
hold(ax, 'on');
if ~isempty(centroid)
    plot(ax, centroid(1), centroid(2), 'rx', 'MarkerSize', 14, 'LineWidth', 2.5);
end
hold(ax, 'off');
if k == 0
    title(ax, 'Substage camera', 'Interpreter', 'none');
else
    title(ax, sprintf('Substage camera — point %d/%d [DMD %d,%d]', ...
        k, nTotal, round(dmdCoord(1)), round(dmdCoord(2))), 'Interpreter', 'none');
end
end

% -------------------------------------------------------------------------

function updateScanImagePanel(ax, img, centroid, k, nTotal)
%updateScanImagePanel Render the most recent ScanImage frame with centroid.
cla(ax);
if isempty(img)
    text(0.5, 0.5, 'ScanImage frame will appear here', ...
        'HorizontalAlignment', 'center', 'Units', 'normalized', ...
        'Parent', ax, 'Color', [0.5 0.5 0.5], 'FontSize', 10);
    title(ax, 'ScanImage', 'Interpreter', 'none');
    return;
end
imagesc(ax, img);
colormap(ax, gray);
axis(ax, 'image');
set(ax, 'XTick', [], 'YTick', []);
hold(ax, 'on');
if ~isempty(centroid)
    plot(ax, centroid(1), centroid(2), 'rx', 'MarkerSize', 14, 'LineWidth', 2.5);
end
hold(ax, 'off');
title(ax, sprintf('ScanImage — point %d/%d', k, nTotal), 'Interpreter', 'none');
end

% -------------------------------------------------------------------------

function updateResidualPanel(ax, calib, rmsError)
%updateResidualPanel Scatter of measured vs predicted coords, coloured by error.
%   Green < 1 px, yellow 1–2 px, red > 2 px.
cla(ax);
if ~isstruct(calib) || ~isfield(calib, 'residualsPerPt') || isempty(calib.residualsPerPt)
    text(0.5, 0.5, 'Collecting points...', ...
        'HorizontalAlignment', 'center', 'Units', 'normalized', ...
        'Parent', ax, 'Color', [0.5 0.5 0.5], 'FontSize', 10);
    title(ax, 'Affine residuals', 'Interpreter', 'none');
    return;
end

pred = calib.imgPtsPredicted;   % nAcc×2
meas = calib.imgPtsAccepted;    % nAcc×2
res  = calib.residualsPerPt;    % nAcc×1

% Stack x and y coords into one scatter (2n points, one colour per point pair)
xPred  = [pred(:,1); pred(:,2)];
yMeas  = [meas(:,1); meas(:,2)];
resAll = [res; res];

green  = resAll <  1;
yellow = resAll >= 1 & resAll < 2;
red    = resAll >= 2;

hold(ax, 'on');
if any(green),  scatter(ax, xPred(green),  yMeas(green),  25, [0.15 0.75 0.15], 'filled'); end
if any(yellow), scatter(ax, xPred(yellow), yMeas(yellow), 25, [0.95 0.80 0.10], 'filled'); end
if any(red),    scatter(ax, xPred(red),    yMeas(red),    25, [0.85 0.15 0.10], 'filled'); end

allCoords = [xPred; yMeas];
lims      = [min(allCoords), max(allCoords)];
if diff(lims) > 0
    plot(ax, lims, lims, 'k--', 'LineWidth', 1);
end
hold(ax, 'off');

xlabel(ax, 'Predicted (px)');
ylabel(ax, 'Measured (px)');
if isfinite(rmsError)
    title(ax, sprintf('Affine residuals — RMS = %.2f px', rmsError), 'Interpreter', 'none');
else
    title(ax, 'Affine residuals', 'Interpreter', 'none');
end
end

% -------------------------------------------------------------------------

function updateProgressPanel(ax, k, nTotal, nAccepted, nRejected, rmsError, t0, statusStr)
%updateProgressPanel Text dashboard in panel [2,2]; leaves button area clear.
cla(ax);
axis(ax, 'off');

elapsedSec = toc(t0);
if k > 0 && isfinite(elapsedSec) && elapsedSec > 0
    remainSec = (elapsedSec / k) * (nTotal - k);
else
    remainSec = NaN;
end

if isfinite(rmsError)
    rmsStr = sprintf('%.2f px', rmsError);
else
    rmsStr = '--';
end

rows = { ...
    sprintf('Point:           %d / %d',   k, nTotal),       ...
    sprintf('Accepted:        %d points', nAccepted),        ...
    sprintf('Rejected:        %d points', nRejected),        ...
    sprintf('RMS error:       %s',        rmsStr),           ...
    sprintf('Elapsed:         %s',        mmss(elapsedSec)), ...
    sprintf('Est. remaining:  %s',        mmss(remainSec)),  ...
    sprintf('Status:          %s',        statusStr),        ...
};

% Text rows occupy the top 55 % of the axes; buttons fill the lower 45 %.
yTop = 0.96;
dy   = 0.13;
for i = 1:numel(rows)
    text(0.04, yTop - (i-1)*dy, rows{i}, ...
        'Units', 'normalized', 'Parent', ax, ...
        'FontSize', 9, 'FontName', 'Courier', ...
        'VerticalAlignment', 'top', 'Interpreter', 'none');
end
end

% -------------------------------------------------------------------------

function updateStatus(ax, k, nTotal, statusStr)
%updateStatus Quick status update between full panel redraws — sets title only.
title(ax, sprintf('[%d/%d] %s', k, nTotal, statusStr), 'Interpreter', 'none');
end

% =========================================================================
% Private helpers
% =========================================================================

function img = getScanImageFrame(siBridge)
%getScanImageFrame Best-effort: get most recent TIFF frame from ScanImage.
%   Returns [] if siBridge is empty, if no TIFF is available, or on any error.
img = [];
if isempty(siBridge), return; end
try
    [framesPath, ~] = siBridge.getLastAcquisition();
    if isempty(framesPath) || ~ischar(framesPath), return; end
    if ~exist(framesPath, 'file'),                  return; end
    img = double(imread(framesPath, 1));
catch
    % frame not available — img stays []
end
end

% =========================================================================
% Button callbacks
% =========================================================================

function onClose(hFig, ~)
if ishghandle(hFig)
    setappdata(hFig, 'pauseFlag', false);   % release pause so loop exits cleanly
    delete(hFig);
end
end

function cbPauseResume(hFig, hBtn)
if ~ishghandle(hFig), return; end
if getappdata(hFig, 'pauseFlag')
    setappdata(hFig, 'pauseFlag', false);
    set(hBtn, 'String', 'Pause');
else
    setappdata(hFig, 'pauseFlag', true);
    set(hBtn, 'String', 'Resume');
end
end

function cbSave(hFig)
if ~ishghandle(hFig), return; end
calib = getappdata(hFig, 'calib');
if isempty(calib)
    warndlg('Calibration not yet complete.', 'Save calibration');
    return;
end
stamp    = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
defName  = sprintf('calib_dmd_%s.mat', stamp);
[fname, fpath] = uiputfile('*.mat', 'Save calibration', defName);
if isequal(fname, 0), return; end   % user cancelled
try
    save(fullfile(fpath, fname), 'calib', '-v7.3');
    msgbox(sprintf('Saved to:\n%s', fullfile(fpath, fname)), 'Saved');
catch ME
    errordlg(sprintf('Save failed: %s', ME.message), 'Save error');
end
end

% =========================================================================
% Shared local utilities
% =========================================================================

function s = mmss(totalSec)
if ~isnumeric(totalSec) || ~isfinite(totalSec)
    s = '--:--';
    return;
end
totalSec = max(0, round(totalSec));
s = sprintf('%02d:%02d', floor(totalSec/60), mod(totalSec, 60));
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
