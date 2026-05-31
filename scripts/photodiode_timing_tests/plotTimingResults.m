function figs = plotTimingResults(result, sessionDir)
%plotTimingResults Render the DMD switching-timing sweep summary figure.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure and
%   how this figure summarises a sweep produced by runDMDTimingSweep.
%
%   Builds a single 2x2 INVISIBLE summary figure from a sweep `result` and
%   writes it to <sessionDir>/timing_summary.png.  The figure is created
%   off-screen (figure('Visible','off')) so it can be generated on a headless
%   machine or inside a test, and it is intentionally robust to NaN / empty
%   metrics: any panel that lacks data is skipped (or annotated) rather than
%   erroring, so the mock end-to-end run always yields a PNG.
%
%   Panels
%   ------
%   (A) Example APD trace + trigger overlay for one representative rate
%       (the tracked rate closest to the median of tracking rates; fallback:
%       the first rate with a non-empty raw capture).  X-axis in ms, zoomed
%       to the first ~12 commanded periods so individual edges are visible.
%   (B) Optical settle time vs commanded rate: rise & fall means (µs) with
%       per-rate std error bars, semilogx.
%   (C) Trigger->light latency mean (µs) vs commanded rate with std error
%       bars, semilogx.
%   (D) Achieved rate vs commanded rate, loglog scatter with a y = x
%       reference line, markers coloured by trackingOK, and a vertical line
%       at the maximum reliable rate.
%
%   figs = plotTimingResults(result)
%   figs = plotTimingResults(result, sessionDir)
%
%   Inputs
%   ------
%   result : struct
%       Sweep result as returned by runDMDTimingSweep.  Required fields used
%       here: .ratesHz, .metrics (struct array), .raw (cell array),
%       .maxReliableRateHz, .cfg (for the device tag), .sessionDir.
%
%   sessionDir : char | string  (optional)
%       Output directory for the PNG.  Defaults to result.sessionDir.
%
%   Output
%   ------
%   figs : matlab.ui.Figure | []
%       Handle to the created figure (empty if the result had no metrics, in
%       which case a warning is issued and nothing is drawn).  The figure is
%       NOT closed here -- that is left to the caller.  It is invisible, so
%       leaving it open is harmless.
%
%   Errors (identifier format: tfp:timing:plotTimingResults:<reason>)
%   ------
%   tfp:timing:plotTimingResults:badResult
%       result is not a scalar struct, or is missing the .metrics field.
%
%   Example
%   -------
%   result = runDMDTimingSweep();          % full mock run
%   figs   = plotTimingResults(result);    % writes timing_summary.png
%
%   See also runDMDTimingSweep, analyzeTimingTrace, scripts/photodiode_timing_tests/README.md

% -------------------------------------------------------------------------
% 1.  Validate / default inputs.
% -------------------------------------------------------------------------
if ~isstruct(result) || ~isscalar(result) || ~isfield(result, 'metrics')
    error('tfp:timing:plotTimingResults:badResult', ...
        'result must be a scalar struct with a .metrics field.');
end

if nargin < 2 || isempty(sessionDir)
    if isfield(result, 'sessionDir') && ~isempty(result.sessionDir)
        sessionDir = result.sessionDir;
    else
        sessionDir = pwd;   % last-resort fallback so we can still save a file
    end
end
sessionDir = char(sessionDir);

% Degenerate input: nothing to plot.  Warn and return [] (never error here).
metrics = result.metrics;
if isempty(metrics)
    warning('tfp:timing:plotTimingResults:noMetrics', ...
        'result.metrics is empty; no figure produced.');
    figs = [];
    return;
end

% Pull the swept rates; fall back to the per-metric commandedRateHz if the
% top-level field is missing for some reason.
if isfield(result, 'ratesHz') && ~isempty(result.ratesHz)
    ratesHz = double(result.ratesHz(:).');
else
    ratesHz = arrayfun(@(m) getNum(m, 'commandedRateHz'), metrics);
    ratesHz = ratesHz(:).';
end
nRates = numel(metrics);

% Raw captures (may be a cell of [] entries, or absent entirely).
if isfield(result, 'raw') && iscell(result.raw)
    rawCell = result.raw;
else
    rawCell = cell(1, nRates);
end

% Device tag and max-reliable rate for titles.
deviceTag = '?';
if isfield(result, 'cfg') && isstruct(result.cfg) && isfield(result.cfg, 'device')
    deviceTag = safeStr(result.cfg.device);
end
maxRel = NaN;
if isfield(result, 'maxReliableRateHz')
    maxRel = result.maxReliableRateHz;
end

% Convenience per-rate vectors (NaN-filled where data is absent).
trackOK    = false(1, nRates);
achievedHz = nan(1, nRates);
for i = 1 : nRates
    trackOK(i)    = getBool(metrics(i), 'trackingOK');
    achievedHz(i) = getNum(metrics(i),  'achievedRateHz');
end

% -------------------------------------------------------------------------
% 2.  Create the invisible figure and a 2x2 layout.
% -------------------------------------------------------------------------
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1100 800], 'Name', 'DMD timing summary');

useTiled = exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5;
tl = [];
if useTiled
    tl = tiledlayout(fig, 2, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
end

% Helper to grab the axes for panel k (1..4) under either layout backend.
% The tiledlayout handle tl is threaded through so nexttile targets it
% explicitly (rather than relying on the "current" layout).
nextAxes = @(k) panelAxes(fig, tl, k);

% -------------------------------------------------------------------------
% 3.  Panel (A) -- example APD + trigger overlay.
% -------------------------------------------------------------------------
axA = nextAxes(1);
plotExampleTrace(axA, result, metrics, rawCell, ratesHz, trackOK);

% -------------------------------------------------------------------------
% 4.  Panel (B) -- rise & fall settle time (µs) vs commanded rate.
% -------------------------------------------------------------------------
axB = nextAxes(2);
plotSettleTimes(axB, metrics, ratesHz);

% -------------------------------------------------------------------------
% 5.  Panel (C) -- latency mean (µs) vs commanded rate.
% -------------------------------------------------------------------------
axC = nextAxes(3);
plotLatency(axC, metrics, ratesHz);

% -------------------------------------------------------------------------
% 6.  Panel (D) -- achieved rate vs commanded rate.
% -------------------------------------------------------------------------
axD = nextAxes(4);
plotAchievedVsCommanded(axD, ratesHz, achievedHz, trackOK, maxRel);

% -------------------------------------------------------------------------
% 7.  Overall title.
% -------------------------------------------------------------------------
if isfinite(maxRel)
    overall = sprintf('%s switching timing  |  max reliable rate = %.0f Hz', ...
        deviceTag, maxRel);
else
    overall = sprintf('%s switching timing  |  max reliable rate = NaN', deviceTag);
end
applyOverallTitle(fig, tl, overall);

% -------------------------------------------------------------------------
% 8.  Save the PNG (exportgraphics when available, else print).
% -------------------------------------------------------------------------
out = fullfile(sessionDir, 'timing_summary.png');
try
    if exist('exportgraphics', 'file')
        exportgraphics(fig, out, 'Resolution', 150);
    else
        print(fig, '-dpng', '-r150', out);
    end
catch ME
    warning('tfp:timing:plotTimingResults:saveFailed', ...
        'Could not write %s: %s', out, ME.message);
end

figs = fig;   % return the handle; do NOT close (caller's responsibility)

end % plotTimingResults


% =========================================================================
% Panel (A) -- example APD trace with trigger overlay
% =========================================================================
function plotExampleTrace(ax, result, metrics, rawCell, ratesHz, trackOK)
%plotExampleTrace Draw one representative raw capture (APD + trigger step).
%
%   Picks the tracked rate whose commanded value is closest to the median of
%   all tracked rates.  If no rate tracked (or none has raw data), falls back
%   to the first rate with a non-empty raw capture.  If there is no raw data
%   at all, leaves a text annotation instead of erroring.

idx = pickExampleIdx(rawCell, ratesHz, trackOK);

if isempty(idx)
    % No raw traces stored anywhere -> annotate and bail out of this panel.
    annotateEmpty(ax, 'no raw traces stored');
    title(ax, 'example trace (A)');
    return;
end

raw = rawCell{idx};
if ~isstruct(raw) || ~isfield(raw, 'apd') || ~isfield(raw, 'sampleRateHz')
    annotateEmpty(ax, 'raw capture missing apd/sampleRateHz');
    title(ax, 'example trace (A)');
    return;
end

apd = raw.apd(:);
N   = numel(apd);
if N == 0
    annotateEmpty(ax, 'empty raw trace');
    title(ax, 'example trace (A)');
    return;
end

% Time vector (ms): use raw.t if present and consistent, else reconstruct.
if isfield(raw, 't') && numel(raw.t) == N
    t_s = raw.t(:);
else
    t_s = (0:N-1).' / double(raw.sampleRateHz);
end
t_ms = t_s * 1e3;

% Estimate low/high levels for a nicely-scaled trigger overlay step.
m = metrics(idx);
lowV  = getNum(m, 'lowLevelV');
highV = getNum(m, 'highLevelV');
if ~isfinite(lowV),  lowV  = min(apd);            end
if ~isfinite(highV), highV = max(apd);            end
contrast = highV - lowV;
if ~isfinite(contrast) || contrast <= 0
    contrast = max(eps, max(apd) - min(apd));     % guard a flat trace
end

% Plot APD.
plot(ax, t_ms, apd, '-', 'Color', [0 0.45 0.74], 'LineWidth', 1.0);
hold(ax, 'on');

% Overlay the recorded trigger as a reference step scaled into the APD range:
% trig in {0,1} -> [low, low+contrast].  Skip if no trigger channel.
if isfield(raw, 'trig') && numel(raw.trig) == N
    trigStep = double(raw.trig(:) > 0.5) * contrast + lowV;
    % 3-element RGB only: plot()'s Color does not accept an RGBA alpha in R2023a.
    plot(ax, t_ms, trigStep, '-', 'Color', [0.85 0.33 0.10], 'LineWidth', 0.8);
    legend(ax, {'APD', 'trigger (scaled)'}, 'Location', 'best', 'Box', 'off');
end

hold(ax, 'off');

% Zoom the x-axis to the first ~12 commanded periods so edges are visible.
commandedRate = ratesHz(idx);
if isfinite(commandedRate) && commandedRate > 0
    spanMs = 12 * (1 / commandedRate) * 1e3;       % 12 periods, in ms
    xMax   = min(t_ms(end), t_ms(1) + spanMs);
    if xMax > t_ms(1)
        xlim(ax, [t_ms(1) xMax]);
    end
end

grid(ax, 'on');
xlabel(ax, 'time (ms)');
ylabel(ax, 'APD (V)');
title(ax, sprintf('example trace @ %.0f Hz (A)', commandedRate));

end % plotExampleTrace


% =========================================================================
% Panel (B) -- rise & fall settle time vs commanded rate
% =========================================================================
function plotSettleTimes(ax, metrics, ratesHz)
%plotSettleTimes Semilogx rise/fall means (µs) with std error bars.
%
%   Means and stds are computed from the per-edge riseTime_s / fallTime_s
%   vectors when available; empties are skipped (rendered as NaN, which
%   plotting simply omits).

n = numel(metrics);
riseMeanUs = nan(1, n);  riseStdUs = nan(1, n);
fallMeanUs = nan(1, n);  fallStdUs = nan(1, n);

for i = 1 : n
    rt = getVec(metrics(i), 'riseTime_s');
    ft = getVec(metrics(i), 'fallTime_s');
    if ~isempty(rt)
        riseMeanUs(i) = mean(rt) * 1e6;
        riseStdUs(i)  = stdSafe(rt) * 1e6;
    end
    if ~isempty(ft)
        fallMeanUs(i) = mean(ft) * 1e6;
        fallStdUs(i)  = stdSafe(ft) * 1e6;
    end
end

ratesX = posRates(ratesHz);    % positive rates only (semilogx-safe)

anyData = any(isfinite(riseMeanUs)) || any(isfinite(fallMeanUs));
if ~anyData
    annotateEmpty(ax, 'no rise/fall data');
    title(ax, 'settle time (B)');
    return;
end

hold(ax, 'on');
% errorbar tolerates NaN entries (they are simply not drawn).
e1 = errorbar(ax, ratesX, riseMeanUs, riseStdUs, '-o', ...
    'Color', [0 0.45 0.74], 'MarkerFaceColor', [0 0.45 0.74], 'LineWidth', 1.0);
e2 = errorbar(ax, ratesX, fallMeanUs, fallStdUs, '-s', ...
    'Color', [0.85 0.33 0.10], 'MarkerFaceColor', [0.85 0.33 0.10], 'LineWidth', 1.0);
hold(ax, 'off');

set(ax, 'XScale', 'log');
grid(ax, 'on');
xlabel(ax, 'commanded rate (Hz)');
ylabel(ax, 'settle time (us)');
legend(ax, [e1 e2], {'rise (10-90%)', 'fall (90-10%)'}, ...
    'Location', 'best', 'Box', 'off');
title(ax, 'optical settle time (B)');

end % plotSettleTimes


% =========================================================================
% Panel (C) -- latency mean vs commanded rate
% =========================================================================
function plotLatency(ax, metrics, ratesHz)
%plotLatency Semilogx trigger->light latency mean (µs) with std error bars.

n = numel(metrics);
latMeanUs = nan(1, n);
latStdUs  = nan(1, n);
for i = 1 : n
    latMeanUs(i) = getNum(metrics(i), 'latencyMean_s') * 1e6;
    latStdUs(i)  = getNum(metrics(i), 'latencyStd_s')  * 1e6;
end

ratesX = posRates(ratesHz);

if ~any(isfinite(latMeanUs))
    annotateEmpty(ax, 'no latency data');
    title(ax, 'trigger->light latency (C)');
    return;
end

% errorbar ignores NaN std entries; replace NaN std with 0 so a single
% matched latency still plots its mean marker.
latStdUs(~isfinite(latStdUs)) = 0;

errorbar(ax, ratesX, latMeanUs, latStdUs, '-o', ...
    'Color', [0.47 0.18 0.58], 'MarkerFaceColor', [0.47 0.18 0.58], 'LineWidth', 1.0);

set(ax, 'XScale', 'log');
grid(ax, 'on');
xlabel(ax, 'commanded rate (Hz)');
ylabel(ax, 'latency (us)');
title(ax, 'trigger->light latency (C)');

end % plotLatency


% =========================================================================
% Panel (D) -- achieved rate vs commanded rate
% =========================================================================
function plotAchievedVsCommanded(ax, ratesHz, achievedHz, trackOK, maxRel)
%plotAchievedVsCommanded Loglog scatter of achieved vs commanded rate.
%
%   Markers: filled green where trackingOK, open red otherwise.  A dashed
%   y = x reference line and (if finite) a vertical line at the maximum
%   reliable rate are overlaid.

% Keep only points that are plottable on log axes (both > 0 and finite).
valid = isfinite(ratesHz) & ratesHz > 0 & isfinite(achievedHz) & achievedHz > 0;

if ~any(valid)
    annotateEmpty(ax, 'no achieved-rate data');
    title(ax, 'achieved vs commanded (D)');
    return;
end

cmd  = ratesHz(valid);
ach  = achievedHz(valid);
okV  = trackOK(valid);

hold(ax, 'on');

% y = x reference (dashed) spanning the data range.
lo = min([cmd, ach]);
hi = max([cmd, ach]);
if lo <= 0 || ~isfinite(lo), lo = min(cmd); end
hRef = plot(ax, [lo hi], [lo hi], '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);

% Tracked points: filled green.  Untracked: open red.
hOK = []; hBad = [];
if any(okV)
    hOK = scatter(ax, cmd(okV), ach(okV), 48, ...
        'MarkerFaceColor', [0.20 0.65 0.20], 'MarkerEdgeColor', [0.10 0.40 0.10]);
end
if any(~okV)
    hBad = scatter(ax, cmd(~okV), ach(~okV), 48, ...
        'MarkerFaceColor', 'none', 'MarkerEdgeColor', [0.85 0.10 0.10], 'LineWidth', 1.2);
end

% Vertical line at the max reliable rate (if finite and on-axis).
hMax = [];
if isfinite(maxRel) && maxRel > 0
    yl = [min(ach) max(ach)];
    if yl(2) <= yl(1), yl = [lo hi]; end
    hMax = plot(ax, [maxRel maxRel], yl, ':', 'Color', [0 0 0], 'LineWidth', 1.2);
    text(ax, maxRel, yl(2), sprintf('  max reliable\n  %.0f Hz', maxRel), ...
        'VerticalAlignment', 'top', 'FontSize', 8, 'Color', [0 0 0]);
end

hold(ax, 'off');

set(ax, 'XScale', 'log', 'YScale', 'log');
grid(ax, 'on');
xlabel(ax, 'commanded rate (Hz)');
ylabel(ax, 'achieved rate (Hz)');
title(ax, 'achieved vs commanded (D)');

% Build a legend from whichever handles exist.
legH = []; legL = {};
if ~isempty(hOK),  legH(end+1) = hOK;  legL{end+1} = 'tracking OK';   end %#ok<AGROW>
if ~isempty(hBad), legH(end+1) = hBad; legL{end+1} = 'not tracking';  end %#ok<AGROW>
if ~isempty(hRef), legH(end+1) = hRef; legL{end+1} = 'y = x';         end %#ok<AGROW>
if ~isempty(hMax), legH(end+1) = hMax; legL{end+1} = 'max reliable';  end %#ok<AGROW>
if ~isempty(legH)
    legend(ax, legH, legL, 'Location', 'best', 'Box', 'off');
end

end % plotAchievedVsCommanded


% =========================================================================
% Local helper -- choose the example-trace rate index
% =========================================================================
function idx = pickExampleIdx(rawCell, ratesHz, trackOK)
%pickExampleIdx Index of the representative rate for the example-trace panel.
%
%   Preference order:
%     1. Among rates that tracked AND have a non-empty raw capture, the one
%        whose commanded rate is closest to the MEDIAN of those rates.
%     2. Otherwise, the first rate with a non-empty raw capture.
%     3. Otherwise, [] (no raw data at all).

hasRaw = false(1, numel(rawCell));
for i = 1 : numel(rawCell)
    hasRaw(i) = ~isempty(rawCell{i}) && isstruct(rawCell{i});
end

cand = find(hasRaw & trackOK);
if ~isempty(cand)
    medRate = medianSafe(ratesHz(cand));
    [~, k]  = min(abs(ratesHz(cand) - medRate));
    idx     = cand(k);
    return;
end

firstRaw = find(hasRaw, 1, 'first');
if ~isempty(firstRaw)
    idx = firstRaw;
else
    idx = [];
end

end % pickExampleIdx


% =========================================================================
% Layout / annotation helpers
% =========================================================================
function ax = panelAxes(fig, tl, k)
%panelAxes Return axes for panel k under tiledlayout or subplot backend.
%   When tl is a tiledlayout handle, nexttile(tl, k) targets it explicitly;
%   otherwise fall back to a plain subplot grid on fig.
if ~isempty(tl) && isgraphics(tl)
    ax = nexttile(tl, k);
else
    ax = subplot(2, 2, k, 'Parent', fig);
end
end % panelAxes

function applyOverallTitle(fig, tl, txt)
%applyOverallTitle Set an overall figure title (tiled-layout title or sgtitle).
if ~isempty(tl) && isgraphics(tl)
    % title() on the tiledlayout handle sets the overall (top) title.
    title(tl, txt);
elseif exist('sgtitle', 'file')
    sgtitle(fig, txt);
end
end % applyOverallTitle

function annotateEmpty(ax, msg)
%annotateEmpty Place a centred "no data" message in an otherwise-blank axes.
cla(ax);
text(ax, 0.5, 0.5, msg, 'Units', 'normalized', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
    'FontAngle', 'italic', 'Color', [0.4 0.4 0.4]);
set(ax, 'XTick', [], 'YTick', []);
end % annotateEmpty


% =========================================================================
% Small numeric accessors (NaN/empty-safe; no toolbox dependence)
% =========================================================================
function v = getNum(s, f)
%getNum Scalar numeric field f of struct s, or NaN if missing/non-scalar.
if isstruct(s) && isfield(s, f) && isnumeric(s.(f)) && isscalar(s.(f))
    v = double(s.(f));
else
    v = NaN;
end
end % getNum

function v = getVec(s, f)
%getVec Numeric vector field f of struct s as a row, or [] if missing.
if isstruct(s) && isfield(s, f) && isnumeric(s.(f)) && ~isempty(s.(f))
    v = double(s.(f)(:)).';
    v = v(isfinite(v));   % drop NaNs so mean/std are well-defined
else
    v = [];
end
end % getVec

function b = getBool(s, f)
%getBool Logical field f of struct s as a scalar logical, else false.
if isstruct(s) && isfield(s, f) && isscalar(s.(f))
    b = logical(s.(f));
else
    b = false;
end
end % getBool

function r = posRates(ratesHz)
%posRates Copy of ratesHz with non-positive entries set to NaN (log-safe).
r = double(ratesHz(:)).';
r(~(r > 0)) = NaN;        % also catches NaN/Inf (NaN > 0 is false)
end % posRates

function s = stdSafe(x)
%stdSafe NaN-ignoring sample std; 0 for a single element, NaN for empty.
x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    s = NaN;
elseif n == 1
    s = 0;
else
    mu = sum(x) / n;
    s  = sqrt(sum((x - mu).^2) / (n - 1));
end
end % stdSafe

function md = medianSafe(x)
%medianSafe NaN-ignoring median via sort; NaN for empty input.
x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    md = NaN;
    return;
end
xs = sort(x);
if mod(n, 2) == 1
    md = xs((n + 1) / 2);
else
    md = 0.5 * (xs(n/2) + xs(n/2 + 1));
end
end % medianSafe

function s = safeStr(x)
%safeStr Coerce a possibly-string/char value to a printable char row.
if ischar(x)
    s = x;
elseif isstring(x) && isscalar(x)
    s = char(x);
else
    s = '?';
end
end % safeStr
