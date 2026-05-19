function liveFigures(seqState)
%liveFigures Update the live experiment figure during a running session.
%
%   liveFigures(seqState)
%
%   seqState is a struct with fields:
%     .trialIdx    current trial number (1-based)
%     .nTrials     total trials in sequence
%     .lastTrial   most recently completed Trial object (or [])
%     .allTrials   array of all Trial objects completed so far
%     .sessionDir  path to session directory
%
%   Creates or reuses a persistent figure with 3 subplots:
%     1. Progress bar: trialIdx / nTrials
%     2. Per-cell ΔF/F traces from lastTrial (if imaging data present)
%     3. PPSF curve: mean peak ΔF/F vs distance across allTrials
%
%   Falls back gracefully when imaging data is absent (Phase 1 mode).

persistent hFig

%ASSUMED baseline fluorescence encoding: F = BASELINE + dFF*BASELINE (SyntheticImaging)
BASELINE    = 1000;
RESP_THRESH = 3;    % σ above baseline mean to classify as responder

if isempty(hFig) || ~ishghandle(hFig)
    hFig = figure('Name', 'Live Session Monitor', 'NumberTitle', 'off');
end
set(0, 'CurrentFigure', hFig);   % make current without raising window

% --- Subplot 1: progress bar ---
ax1 = subplot(3, 1, 1);
cla(ax1);
frac = seqState.trialIdx / max(seqState.nTrials, 1);
patch(ax1, [0 frac frac 0 0], [0 0 1 1 0], [0.2 0.7 0.2], 'EdgeColor', 'none');
if frac < 1
    patch(ax1, [frac 1 1 frac frac], [0 0 1 1 0], [0.82 0.82 0.82], 'EdgeColor', 'none');
end
xlim(ax1, [0, 1]);
ylim(ax1, [0, 1]);
set(ax1, 'XTick', [], 'YTick', []);
title(ax1, sprintf('Progress: trial %d / %d', seqState.trialIdx, seqState.nTrials));

% --- Subplot 2: per-cell ΔF/F traces from last trial ---
ax2 = subplot(3, 1, 2);
cla(ax2);
imaging = extractImaging(seqState.lastTrial);

if ~isempty(imaging)
    F      = double(imaging.F);          % nCells × T
    dff    = (F - BASELINE) / BASELINE;
    nCells = size(dff, 1);
    T      = size(dff, 2);

    fs = 30;
    if isfield(imaging, 'ops') && isfield(imaging.ops, 'fs')
        fs = imaging.ops.fs;
    end
    tVec  = (0:T-1) / fs;
    nBase = max(1, floor(T / 3));

    hold(ax2, 'on');
    clr = lines(max(nCells, 1));
    for i = 1:nCells
        tr      = dff(i, :);
        bSeg    = tr(1:nBase);
        bMean   = mean(bSeg);
        bStd    = std(bSeg);
        if max(tr) > bMean + RESP_THRESH * max(bStd, eps)
            lc = [0.9 0.3 0.3];
            lw = 2;
        else
            lc = clr(i, :);
            lw = 1;
        end
        plot(ax2, tVec, tr, 'Color', lc, 'LineWidth', lw);
    end
    hold(ax2, 'off');
    xlabel(ax2, 'Time (s)');
    ylabel(ax2, '\DeltaF/F');
    title(ax2, sprintf('Last trial — %d cell(s)', nCells));
else
    text(0.5, 0.5, 'No imaging data', ...
        'HorizontalAlignment', 'center', 'Units', 'normalized', ...
        'Parent', ax2, 'Color', [0.5 0.5 0.5]);
    title(ax2, 'Last trial — no imaging');
end

% --- Subplot 3: cumulative PPSF curve ---
ax3 = subplot(3, 1, 3);
cla(ax3);
if ~isempty(seqState.allTrials) && numel(seqState.allTrials) > 1
    [distUm, meanResp] = ppsfSummary(seqState.allTrials, BASELINE);
    if ~isempty(distUm)
        plot(ax3, distUm, meanResp, 'o-', 'LineWidth', 1.5, 'MarkerSize', 6);
        xlabel(ax3, 'Distance (\mum)');
        ylabel(ax3, 'Mean peak \DeltaF/F');
    end
end
title(ax3, 'PPSF (cumulative)');

drawnow();
end

% --- Local helpers ---

function imaging = extractImaging(trial)
%extractImaging Return imaging struct from a complete trial, or [].
imaging = [];
if isempty(trial), return; end
if ~strcmp(trial.status, 'complete'), return; end
if ~isstruct(trial.data), return; end
if ~isfield(trial.data, 'imaging'), return; end
if isempty(trial.data.imaging), return; end
if ~isfield(trial.data.imaging, 'F'), return; end
imaging = trial.data.imaging;
end

function [distUm, meanResp] = ppsfSummary(trials, baseline)
%ppsfSummary Aggregate peak ΔF/F by distance across completed trials.
distAll = [];
respAll = [];
for k = 1:numel(trials)
    tr = trials(k);
    if ~strcmp(tr.status, 'complete'), continue; end
    if ~isstruct(tr.data), continue; end
    if ~isfield(tr.metadata, 'distanceUm'), continue; end
    img = extractImaging(tr);
    if isempty(img), continue; end
    F    = double(img.F);
    dff  = (F - baseline) / baseline;
    peak = max(dff(:));
    distAll(end+1) = tr.metadata.distanceUm; %#ok<AGROW>
    respAll(end+1) = peak;                   %#ok<AGROW>
end

if isempty(distAll)
    distUm   = [];
    meanResp = [];
    return;
end

uDist    = unique(distAll);
meanResp = arrayfun(@(d) mean(respAll(distAll == d)), uDist);
distUm   = uDist;
end
