function liveFigures(seqState)
%liveFigures Real-time experiment monitor updated after each trial.
%
%   liveFigures(seqState) is called by Sequencer after every trial.
%   All rendering is wrapped in try/catch: a figure error can never
%   crash the experiment loop.
%
%   seqState fields:
%     .trialIdx             current trial number (1-based)
%     .nTrials              total trials in sequence
%     .lastTrial            most recently completed Trial object (or [])
%     .allTrials            Trial objects completed so far (handle array)
%     .sessionDir           path to session directory
%     .sessionStartTime     datetime when run() started
%     .lastTrialDuration_s  measured wall-clock seconds for last trial
%
%   Figure layout — 2 rows × 3 columns:
%     Row 1: DMD pattern preview | Power timeline   | Acquisition status
%     Row 2: ΔF/F traces        | PPSF curve       | Response map

try
    liveFiguresInner(seqState);
catch ME
    warning('tfp:analysis:liveFigures:renderError', ...
        'liveFigures trial %d: %s', seqState.trialIdx, ME.message);
    try
        tfp.io.sessionLog(seqState.sessionDir, 'liveFigures-error', ...
            struct('trialIdx', seqState.trialIdx, 'message', ME.message));
    catch, end
end
end

% =========================================================================

function liveFiguresInner(seqState)
persistent hFig hAxes

BASELINE    = 1000;   % SyntheticImaging encoding: F = BASELINE + dFF*BASELINE
RESP_THRESH = 3;      % σ above baseline to classify as responder

% --- Create or restore figure --------------------------------------------
if isempty(hFig) || ~ishghandle(hFig) || isempty(hAxes) || ~all(ishghandle(hAxes))
    hFig = figure( ...
        'Name',        'Live Session Monitor', ...
        'NumberTitle', 'off', ...
        'Tag',         'tfp_live_monitor', ...
        'Position',    [50 50 1400 700]);
    hAxes = gobjects(1, 6);
    for idx = 1:6
        hAxes(idx) = subplot(2, 3, idx);
    end
end
set(0, 'CurrentFigure', hFig);

% Row 1 — hardware status
renderDmdPattern(hAxes(1), seqState);
renderPowerTimeline(hAxes(2), seqState);
renderAcquisitionStatus(hAxes(3), seqState);

% Row 2 — neural data
renderDffTraces(hAxes(4), seqState, BASELINE, RESP_THRESH);
renderPpsfCurve(hAxes(5), seqState, BASELINE);
renderResponseMap(hAxes(6), seqState, BASELINE);

drawnow();
end

% =========================================================================
% Panel renderers — one function per subplot
% =========================================================================

function renderDmdPattern(ax, seqState)
%renderDmdPattern Panel 1: center-cropped DMD pattern for the last trial.
cla(ax);
trial = seqState.lastTrial;
if isempty(trial) || ~isstruct(trial.targetSpec) || ...
        ~isfield(trial.targetSpec, 'patternRef') || ...
        isempty(trial.targetSpec.patternRef)
    showPlaceholder(ax, 'No pattern', 'DMD pattern');
    return;
end

pat = trial.targetSpec.patternRef;
if ndims(pat) > 2
    pat = pat(:,:,1);
end
[H, W] = size(pat);

% Center the 200×200 crop on the stim target when coordinates are known.
if isstruct(trial.targetSpec) && isfield(trial.targetSpec, 'dmdCoords') && ...
        ~isempty(trial.targetSpec.dmdCoords)
    xy = trial.targetSpec.dmdCoords;
    cC = max(1, min(W, round(xy(1))));
    rC = max(1, min(H, round(xy(2))));
else
    cC = round(W/2);
    rC = round(H/2);
end
half = 100;
r1 = max(1, rC - half);     r2 = min(H, rC + half - 1);
c1 = max(1, cC - half);     c2 = min(W, cC + half - 1);
crop = logical(pat(r1:r2, c1:c2));

imagesc(ax, crop);
colormap(ax, gray);
axis(ax, 'image');
set(ax, 'XTick', [], 'YTick', []);

coords = '';
if isstruct(trial.targetSpec) && isfield(trial.targetSpec, 'dmdCoords') && ...
        ~isempty(trial.targetSpec.dmdCoords)
    xy = trial.targetSpec.dmdCoords;
    coords = sprintf(', [%d,%d]', round(xy(1)), round(xy(2)));
end
dist = '';
if isstruct(trial.metadata) && isfield(trial.metadata, 'distanceUm')
    dist = sprintf(', %.1f um', trial.metadata.distanceUm);
end
title(ax, sprintf('DMD — trial %d/%d%s%s', ...
    seqState.trialIdx, seqState.nTrials, coords, dist), ...
    'Interpreter', 'none');
end

% -------------------------------------------------------------------------

function renderPowerTimeline(ax, seqState)
%renderPowerTimeline Panel 2: power per trial with reference line.
cla(ax);
trials  = seqState.allTrials;
idxList = [];
pwrList = [];
for k = 1:numel(trials)
    tr = trials(k);
    if ismember(tr.status, {'complete','failed'}) && ~isempty(tr.powerMw)
        idxList(end+1) = tr.trialIdx; %#ok<AGROW>
        pwrList(end+1) = tr.powerMw;  %#ok<AGROW>
    end
end

if isempty(idxList)
    title(ax, 'Commanded power (mW)');
    return;
end

plot(ax, idxList, pwrList, 'o-', ...
    'Color', [0.2 0.45 0.8], 'LineWidth', 1.5, ...
    'MarkerSize', 5, 'MarkerFaceColor', [0.2 0.45 0.8]);
hold(ax, 'on');
refPwr = pwrList(end);
yline(ax, refPwr, 'r--', sprintf('%.1f mW', refPwr), 'LineWidth', 1.2);
hold(ax, 'off');
xlim(ax, [0.5, max(seqState.nTrials, 1) + 0.5]);
xlabel(ax, 'Trial');
ylabel(ax, 'Power (mW)');
title(ax, 'Commanded power (mW)');
end

% -------------------------------------------------------------------------

function renderAcquisitionStatus(ax, seqState)
%renderAcquisitionStatus Panel 3: text dashboard with timing and SI status.
cla(ax);
axis(ax, 'off');

if isfield(seqState, 'sessionStartTime') && ...
        isdatetime(seqState.sessionStartTime) && ...
        ~isnat(seqState.sessionStartTime)
    elapsedSec = seconds(datetime('now') - seqState.sessionStartTime);
else
    elapsedSec = NaN;
end

if isfinite(elapsedSec) && elapsedSec > 0 && seqState.trialIdx > 0
    secsPerTrial = elapsedSec / seqState.trialIdx;
    remainSec    = secsPerTrial * (seqState.nTrials - seqState.trialIdx);
else
    remainSec = NaN;
end

lastStatus = 'n/a';
lastDur    = '';
if ~isempty(seqState.lastTrial)
    lastStatus = seqState.lastTrial.status;
end
if isfield(seqState, 'lastTrialDuration_s') && ...
        isnumeric(seqState.lastTrialDuration_s) && ...
        isfinite(seqState.lastTrialDuration_s)
    lastDur = sprintf(' in %.1fs', seqState.lastTrialDuration_s);
end

siStatus = 'not configured';
if ~isempty(seqState.lastTrial) && strcmp(seqState.lastTrial.status, 'complete') && ...
        isstruct(seqState.lastTrial.data)
    d = seqState.lastTrial.data;
    if (isfield(d, 'imaging') && ~isempty(d.imaging)) || ...
       (isfield(d, 'imagingTiffPath') && ~isempty(d.imagingTiffPath))
        siStatus = 'active';
    end
end

rows = { ...
    sprintf('Trial %d / %d complete', seqState.trialIdx, seqState.nTrials), ...
    sprintf('Session elapsed:     %s', mmss(elapsedSec)), ...
    sprintf('Estimated remaining: %s', mmss(remainSec)), ...
    sprintf('Last trial: %s%s', lastStatus, lastDur), ...
    sprintf('ScanImage: %s', siStatus), ...
};

yTop = 0.88;
dy   = 0.17;
for i = 1:numel(rows)
    text(0.04, yTop - (i-1)*dy, rows{i}, ...
        'Units', 'normalized', 'Parent', ax, ...
        'FontSize', 10, 'FontName', 'Courier', ...
        'VerticalAlignment', 'top', 'Interpreter', 'none');
end
title(ax, 'Session status');
end

% -------------------------------------------------------------------------

function renderDffTraces(ax, seqState, BASELINE, RESP_THRESH)
%renderDffTraces Panel 4: waterfall dF/F traces from the last trial.
cla(ax);
if isempty(seqState.lastTrial)
    showPlaceholder(ax, 'No trial yet', 'Last trial — cell responses');
    return;
end
imaging = extractImaging(seqState.lastTrial);
if isempty(imaging)
    showPlaceholder(ax, 'No imaging data', 'Last trial — no imaging');
    return;
end

F   = double(imaging.F);
dff = (F - BASELINE) / BASELINE;
[nCells, T] = size(dff);

fs = 30;
if isfield(imaging, 'ops') && isfield(imaging.ops, 'fs')
    fs = imaging.ops.fs;
end
tVec  = (0:T-1) / fs;
nBase = max(1, floor(T / 3));

maxVal  = max(abs(dff(:)));
yOffset = max(maxVal * 1.5, 0.1);

hold(ax, 'on');
for i = 1:nCells
    tr     = dff(i,:);
    bSeg   = tr(1:nBase);
    isResp = max(tr) > mean(bSeg) + RESP_THRESH * max(std(bSeg), eps);
    if isResp
        lc = [0.15 0.75 0.15];  lw = 2;
    else
        lc = [0.65 0.65 0.65];  lw = 1;
    end
    plot(ax, tVec, tr + (i-1)*yOffset, 'Color', lc, 'LineWidth', lw);
end
if ~isempty(seqState.lastTrial.preStim_s)
    xline(ax, seqState.lastTrial.preStim_s, 'r-', 'LineWidth', 1.5);
end
hold(ax, 'off');

xlabel(ax, 'Time (s)');
ylabel(ax, '\DeltaF/F (offset)');
title(ax, sprintf('Last trial — %d cell(s)', nCells));
end

% -------------------------------------------------------------------------

function renderPpsfCurve(ax, seqState, BASELINE)
%renderPpsfCurve Panel 5: mean peak dF/F vs distance with SEM and optional Gaussian fit.
cla(ax);
if isempty(seqState.allTrials) || numel(seqState.allTrials) < 2
    title(ax, 'PPSF curve (building...)');
    return;
end

[distUm, meanResp, semResp] = ppsfSummaryWithSem(seqState.allTrials, BASELINE);
if isempty(distUm)
    showPlaceholder(ax, 'No imaging data yet', 'PPSF curve (building...)');
    return;
end

hold(ax, 'on');
errorbar(ax, distUm, meanResp, semResp, 'o-', ...
    'LineWidth', 1.5, 'MarkerSize', 6, ...
    'Color', [0.2 0.45 0.8], 'MarkerFaceColor', [0.2 0.45 0.8], ...
    'CapSize', 8);

if numel(distUm) >= 5
    try
        gFit  = fit(distUm(:), meanResp(:), 'gauss1');
        xFine = linspace(min(distUm), max(distUm), 200);
        plot(ax, xFine, gFit(xFine), 'r-', 'LineWidth', 1.5);
        legend(ax, 'Mean ± SEM', 'Gaussian fit', 'Location', 'best');
    catch
        % Curve Fitting Toolbox unavailable or fit failed — skip overlay.
    end
end
hold(ax, 'off');

xlabel(ax, 'Distance (\mum)');
ylabel(ax, 'Mean peak \DeltaF/F');
nDone = sum(strcmp({seqState.allTrials.status}, 'complete'));
title(ax, sprintf('PPSF curve — %d trials', nDone));
end

% -------------------------------------------------------------------------

function renderResponseMap(ax, seqState, BASELINE)
%renderResponseMap Panel 6: 2D heatmap (if offsetX/Y available) or 1D bar chart.
cla(ax);
trials = seqState.allTrials;
if isempty(trials)
    title(ax, 'Response map');
    return;
end

has2D = false;
for k = 1:numel(trials)
    tr = trials(k);
    if strcmp(tr.status, 'complete') && isstruct(tr.metadata) && ...
            isfield(tr.metadata, 'offsetX_um') && isfield(tr.metadata, 'offsetY_um')
        has2D = true;
        break;
    end
end

if has2D
    renderMap2D(ax, trials, BASELINE);
else
    renderMap1D(ax, trials, BASELINE);
end
end

% =========================================================================
% Sub-renderers for response map
% =========================================================================

function renderMap2D(ax, trials, BASELINE)
xAll = []; yAll = []; rAll = [];
for k = 1:numel(trials)
    tr = trials(k);
    if ~strcmp(tr.status, 'complete') || ~isstruct(tr.metadata), continue; end
    if ~isfield(tr.metadata, 'offsetX_um') || ~isfield(tr.metadata, 'offsetY_um'), continue; end
    img = extractImaging(tr);
    if isempty(img), continue; end
    dff  = (double(img.F) - BASELINE) / BASELINE;
    xAll(end+1) = tr.metadata.offsetX_um; %#ok<AGROW>
    yAll(end+1) = tr.metadata.offsetY_um; %#ok<AGROW>
    rAll(end+1) = max(dff(:));            %#ok<AGROW>
end
if isempty(xAll)
    showPlaceholder(ax, 'No 2D data yet', 'Response map');
    return;
end

uX = unique(xAll);  uY = unique(yAll);
gridData = nan(numel(uY), numel(uX));
for i = 1:numel(xAll)
    xi = find(uX == xAll(i));
    yi = find(uY == yAll(i));
    if isnan(gridData(yi, xi))
        gridData(yi, xi) = rAll(i);
    else
        gridData(yi, xi) = mean([gridData(yi, xi), rAll(i)]);
    end
end

imagesc(ax, uX, uY, gridData);
colorbar(ax);
xlabel(ax, 'X offset (\mum)');
ylabel(ax, 'Y offset (\mum)');
title(ax, 'Response map (2D)');
axis(ax, 'image');
end

function renderMap1D(ax, trials, BASELINE)
distAll = []; respAll = [];
for k = 1:numel(trials)
    tr = trials(k);
    if ~strcmp(tr.status, 'complete') || ~isstruct(tr.metadata), continue; end
    if ~isfield(tr.metadata, 'distanceUm'), continue; end
    img = extractImaging(tr);
    if isempty(img), continue; end
    dff  = (double(img.F) - BASELINE) / BASELINE;
    distAll(end+1) = tr.metadata.distanceUm; %#ok<AGROW>
    respAll(end+1) = max(dff(:));             %#ok<AGROW>
end
if isempty(distAll)
    showPlaceholder(ax, 'No imaging data yet', 'Response map');
    return;
end

uDist = unique(distAll);
meanR = arrayfun(@(d) mean(respAll(distAll == d)), uDist);
bar(ax, uDist, meanR, 0.6, 'FaceColor', [0.2 0.6 0.8], 'EdgeColor', 'none');
xlabel(ax, 'Distance (\mum)');
ylabel(ax, 'Mean peak \DeltaF/F');
title(ax, 'Response map (1D)');
end

% =========================================================================
% Shared local helpers
% =========================================================================

function showPlaceholder(ax, msg, ttl)
text(0.5, 0.5, msg, ...
    'HorizontalAlignment', 'center', 'Units', 'normalized', ...
    'Parent', ax, 'Color', [0.5 0.5 0.5], 'FontSize', 10);
title(ax, ttl);
end

function imaging = extractImaging(trial)
imaging = [];
if isempty(trial), return; end
if ~strcmp(trial.status, 'complete'), return; end
if ~isstruct(trial.data), return; end
if ~isfield(trial.data, 'imaging'), return; end
if isempty(trial.data.imaging), return; end
if ~isfield(trial.data.imaging, 'F'), return; end
imaging = trial.data.imaging;
end

function [distUm, meanResp, semResp] = ppsfSummaryWithSem(trials, baseline)
distAll = []; respAll = [];
for k = 1:numel(trials)
    tr = trials(k);
    if ~strcmp(tr.status, 'complete'), continue; end
    if ~isstruct(tr.data), continue; end
    if ~isstruct(tr.metadata) || ~isfield(tr.metadata, 'distanceUm'), continue; end
    img = extractImaging(tr);
    if isempty(img), continue; end
    dff  = (double(img.F) - baseline) / baseline;
    distAll(end+1) = tr.metadata.distanceUm; %#ok<AGROW>
    respAll(end+1) = max(dff(:));            %#ok<AGROW>
end
if isempty(distAll)
    distUm = []; meanResp = []; semResp = [];
    return;
end
uDist    = unique(distAll);
nBins    = numel(uDist);
meanResp = zeros(1, nBins);
semResp  = zeros(1, nBins);
for i = 1:nBins
    vals        = respAll(distAll == uDist(i));
    n           = numel(vals);
    meanResp(i) = mean(vals);
    semResp(i)  = std(vals) / max(sqrt(n), 1);
end
distUm = uDist;
end

function s = mmss(totalSec)
if ~isnumeric(totalSec) || ~isfinite(totalSec)
    s = '--:--';
    return;
end
totalSec = max(0, round(totalSec));
s = sprintf('%02d:%02d', floor(totalSec/60), mod(totalSec, 60));
end
