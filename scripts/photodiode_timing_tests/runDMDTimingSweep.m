function result = runDMDTimingSweep(cfgOverride, sessionName)
%runDMDTimingSweep Top-level driver for the DMD switching-timing sweep.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure and
%   how this driver ties the toolset together.
%
%   This is the orchestrator of the toolset.  It sweeps a list of commanded
%   DMD pattern-advance ("ping-pong") rates; at each rate it acquires a raw
%   APD + trigger capture (via acquireTimingRun) and analyses it (via
%   analyzeTimingTrace).  It aggregates the per-rate metrics into a struct
%   array, finds the maximum reliable switching rate, saves the full result
%   plus summary figures, prints a console summary table, and returns the
%   aggregated result.
%
%   Mock bring-up: with the default config (hardwareKind = 'mock',
%   useSynthSignal = true) the entire pipeline runs end-to-end on a dev Mac
%   with NO hardware attached.  MockDMD + MockDAQ are constructed and a
%   synthetic APD/trigger trace is overlaid by the acquisition shim, so a
%   complete result.mat and a timing_summary.png are always produced.
%
%   result = runDMDTimingSweep()
%   result = runDMDTimingSweep(cfgOverride)
%   result = runDMDTimingSweep(cfgOverride, sessionName)
%
%   Inputs
%   ------
%   cfgOverride : [] | struct  (optional)
%       Partial config struct deep-merged onto defaultTimingConfig().  Pass
%       [] (or omit) to use the defaults verbatim.  See defaultTimingConfig
%       for the full field list (hardwareKind, sweep.ratesHz, channels, ...).
%
%   sessionName : char | string  (optional)
%       Sub-folder name (under cfg.paths.dataDir) for this session's output.
%       Defaults to sprintf('dmd_timing_%s', datestr(now,'yyyymmdd_HHMMSS')).
%
%   Output
%   ------
%   result : struct with fields --
%       .sessionDir        char   -- absolute output directory for this run.
%       .cfg               struct -- the resolved (merged) timing config.
%       .ratesHz           1 x R  -- commanded rates that were swept (Hz).
%       .metrics           1 x R  -- struct array of per-rate metrics (one
%                                    entry per swept rate; identical fields /
%                                    order across all entries; see schema in
%                                    analyzeTimingTrace / the local
%                                    emptyMetrics helper).
%       .maxReliableRateHz scalar -- max commanded rate that tracked reliably
%                                    (trackingOK && droppedFraction < 0.05),
%                                    or NaN if none qualified.
%       .raw               1 x R  -- cell array of raw captures (rawCapture
%                                    structs, or [] for a failed rate).
%       .timestamp         datetime -- when the sweep completed.
%
%   Side effects
%   ------------
%   * Creates sessionDir (and parents) if missing.
%   * Saves <sessionDir>/timing_result.mat ('-v7.3') holding `result`.
%   * If cfg.makePlots, calls plotTimingResults to write
%     <sessionDir>/timing_summary.png (a plotting failure only warns; it
%     never aborts the sweep).
%   * Prints an aligned per-rate summary table and maxReliableRateHz to the
%     console.
%
%   Errors (identifier format: tfp:timing:runDMDTimingSweep:<reason>)
%   ------
%   tfp:timing:runDMDTimingSweep:badHardwareKind
%       cfg.hardwareKind is neither 'mock' nor 'real'.
%   tfp:timing:runDMDTimingSweep:cannotCreateSessionDir
%       The session output directory could not be created.
%
%   Example
%   -------
%   % Full mock bring-up on a dev Mac (no hardware):
%   result = runDMDTimingSweep();
%   fprintf('max reliable rate = %g Hz\n', result.maxReliableRateHz);
%
%   % Sweep a custom rate list, real hardware:
%   ov.hardwareKind  = 'real';
%   ov.sweep.ratesHz = [1000 2000 4000 8000];
%   result = runDMDTimingSweep(ov, 'rig_check_2026-06-15');
%
%   See also acquireTimingRun, analyzeTimingTrace, makeTimingPatterns, ...
%            defaultTimingConfig, plotTimingResults, scripts/photodiode_timing_tests/README.md

% -------------------------------------------------------------------------
% 0.  Put the toolset and the src/ package on the path (idempotent).
%     scripts/photodiode_timing_tests/runDMDTimingSweep.m -> scripts/photodiode_timing_tests -> scripts -> repo
% -------------------------------------------------------------------------
thisDir  = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(thisDir));
addpath(thisDir);
addpath(fullfile(repoRoot, 'src'));

% -------------------------------------------------------------------------
% 1.  Default arguments
% -------------------------------------------------------------------------
if nargin < 1
    cfgOverride = [];
end
if nargin < 2
    % datestr(now,...) wrapped in char() so the field is a plain char row
    % regardless of MATLAB's datestr return class.
    sessionName = sprintf('dmd_timing_%s', char(datestr(now, 'yyyymmdd_HHMMSS')));
end

% -------------------------------------------------------------------------
% 2.  Resolve the config (deep-merge the override when supplied).
% -------------------------------------------------------------------------
if ~isempty(cfgOverride)
    cfg = defaultTimingConfig(cfgOverride);
else
    cfg = defaultTimingConfig();
end

% -------------------------------------------------------------------------
% 3.  Create the session output directory.
% -------------------------------------------------------------------------
sessionDir = fullfile(cfg.paths.dataDir, char(sessionName));
if ~exist(sessionDir, 'dir')
    [ok, msg] = mkdir(sessionDir);   % mkdir creates parents as needed
    if ~ok
        error('tfp:timing:runDMDTimingSweep:cannotCreateSessionDir', ...
            'Could not create session directory ''%s'': %s', sessionDir, msg);
    end
end

% -------------------------------------------------------------------------
% 4.  Build hardware (mock or real) and guarantee teardown via onCleanup.
% -------------------------------------------------------------------------
[dmd, daq] = makeHardware(cfg);
% onCleanup fires on normal return AND on error/Ctrl-C, so the devices are
% always released even if a rate iteration throws something un-caught.
cleanupObj = onCleanup(@() teardown(dmd, daq)); %#ok<NASGU>

% -------------------------------------------------------------------------
% 5.  Build the 2-pattern ping-pong stack ONCE and cache it on the config.
%     acquireTimingRun reuses cfg.pattern.stack rather than rebuilding it
%     for every rate (the patterns do not depend on the commanded rate).
% -------------------------------------------------------------------------
[patterns, pinfo] = makeTimingPatterns(dmd, cfg); %#ok<ASGLU>
cfg.pattern.stack = patterns;

% -------------------------------------------------------------------------
% 6.  Sweep the commanded rates.
% -------------------------------------------------------------------------
ratesHz = cfg.sweep.ratesHz(:).';     % force a 1 x R row for clean indexing
nRates  = numel(ratesHz);

% Pre-build a canonical empty metrics record so every struct-array entry has
% identical fields in identical order (required to index into a struct array
% without a "dissimilar structures" error).
metricsArr = repmat(emptyMetrics(NaN), 1, nRates);
rawCell    = cell(1, nRates);

for i = 1 : nRates
    rate = ratesHz(i);
    fprintf('[runDMDTimingSweep] rate %d/%d: %g Hz ...\n', i, nRates, rate);
    try
        raw = acquireTimingRun(cfg, dmd, daq, rate);
        m   = analyzeTimingTrace(raw, cfg);
    catch ME
        % A failed acquire/analyse must not abort the whole sweep: record a
        % fully-populated empty metrics row annotated with the error, and
        % keep going so the remaining rates still get characterised.
        m       = emptyMetrics(rate);
        m.notes = {sprintf('acquire/analyze error: %s', ME.message)};
        raw     = [];
        warning('tfp:timing:runDMDTimingSweep:rateFailed', ...
            'Rate %g Hz failed: %s', rate, ME.message);
    end

    % normalizeMetrics fills any missing field from the canonical schema and
    % reorders fields so every entry slots into metricsArr cleanly.
    metricsArr(i) = normalizeMetrics(m);
    rawCell{i}    = raw;
end

% -------------------------------------------------------------------------
% 7.  Determine the maximum reliable switching rate.
%     Reliable := tracked (trackingOK) AND fewer than 5% dropped toggles.
% -------------------------------------------------------------------------
reliableMask = false(1, nRates);
for i = 1 : nRates
    df = metricsArr(i).droppedFraction;
    reliableMask(i) = metricsArr(i).trackingOK && isfinite(df) && df < 0.05;
end
if any(reliableMask)
    maxReliableRateHz = max(ratesHz(reliableMask));
else
    maxReliableRateHz = NaN;
end

% -------------------------------------------------------------------------
% 8.  Assemble the result struct.
% -------------------------------------------------------------------------
% NOTE: a struct array value (metricsArr) and a cell value (rawCell) must
% each be wrapped in {} inside struct() so they are stored as a single field
% value rather than expanding `result` into a struct array.
result = struct( ...
    'sessionDir',        sessionDir, ...
    'cfg',               cfg, ...
    'ratesHz',           ratesHz, ...
    'metrics',           {metricsArr}, ...  % {} -> store the struct array as one field
    'maxReliableRateHz', maxReliableRateHz, ...
    'raw',               {rawCell}, ...     % {} -> store the cell as one field
    'timestamp',         datetime('now'));

% -------------------------------------------------------------------------
% 9.  Save the result (v7.3 for >2 GB capability and partial-load support).
% -------------------------------------------------------------------------
matPath = fullfile(sessionDir, 'timing_result.mat');
save(matPath, 'result', '-v7.3');
fprintf('[runDMDTimingSweep] saved result -> %s\n', matPath);

% -------------------------------------------------------------------------
% 10. Generate summary figures (never let a plotting error fail the sweep).
% -------------------------------------------------------------------------
if isfield(cfg, 'makePlots') && cfg.makePlots
    try
        plotTimingResults(result, sessionDir);
    catch ME
        warning('tfp:timing:runDMDTimingSweep:plotFailed', ...
            'plotTimingResults failed (continuing): %s', ME.message);
    end
end

% -------------------------------------------------------------------------
% 11. Print the console summary table.
% -------------------------------------------------------------------------
printSummary(result);

end % runDMDTimingSweep


% =========================================================================
% Local helper -- construct the hardware backends from the config
% =========================================================================
function [dmd, daq] = makeHardware(cfg)
%makeHardware Instantiate and initialize DMD + DAQ per cfg.hardwareKind.
%
%   'mock' -> MockDMD + MockDAQ with a synthetic-friendly configuration.
%   'real' -> DLP650LNIR_DMD + NI6323_DAQ on the scope PC.
%
%   NOTE on the struct cell-field trap: passing 'digitalInChannels',{{ '...' }}
%   to struct() makes a 1x1 struct whose .digitalInChannels field is a 1x1
%   cell containing the line name (NOT a 1xN struct array).  Likewise
%   'digitalOutChannels',{{}} yields an empty-cell field on a scalar struct.

switch cfg.hardwareKind
    case 'mock'
        dmd = tfp.hardware.MockDMD();
        dmd.initialize(struct( ...
            'nRows',                   cfg.dmd.nRows, ...
            'nCols',                   cfg.dmd.nCols, ...
            'maxPatternRate',          cfg.dmd.maxPatternRate, ...
            'loadLatencyMsPerPattern', 0));      % 0 -> no fake load pause in tests

        daq = tfp.hardware.MockDAQ();
        daq.initialize(struct( ...
            'sampleRate',         cfg.sampleRateHz, ...
            'analogInChannels',   cfg.channels.apdAI, ...
            'analogOutChannels',  cfg.channels.trigAO, ...
            'digitalInChannels',  {{cfg.channels.trigDI}}, ...   % {{...}} -> 1x1 cell field
            'digitalOutChannels', {{}}));                        % {{}}   -> empty-cell field

    case 'real'
        % DLP650LNIR_DMD's constructor calls initialize() with the backend
        % struct, so no separate initialize() call is needed here.
        dmd = tfp.hardware.DLP650LNIR_DMD(cfg.dmd.backend);

        daq = tfp.hardware.NI6323_DAQ(struct( ...
            'deviceName',         'Dev1', ...
            'sampleRate',         cfg.sampleRateHz, ...
            'analogInChannels',   cfg.channels.apdAI, ...
            'analogOutChannels',  cfg.channels.trigAO, ...
            'digitalInChannels',  {{cfg.channels.trigDI}}));     % {{...}} -> 1x1 cell field

    otherwise
        error('tfp:timing:runDMDTimingSweep:badHardwareKind', ...
            'cfg.hardwareKind must be ''mock'' or ''real''; got ''%s''.', ...
            char(cfg.hardwareKind));
end

end % makeHardware


% =========================================================================
% Local helper -- best-effort device teardown (used by onCleanup)
% =========================================================================
function teardown(dmd, daq)
%teardown Release the DMD and DAQ, swallowing any cleanup errors.
%
%   Each cleanup() is wrapped independently so a failure releasing one
%   device does not prevent releasing the other.

try
    if ~isempty(dmd) && isvalid(dmd)
        dmd.cleanup();
    end
catch ME
    warning('tfp:timing:runDMDTimingSweep:dmdCleanupFailed', ...
        'DMD cleanup failed: %s', ME.message);
end

try
    if ~isempty(daq) && isvalid(daq)
        daq.cleanup();
    end
catch ME
    warning('tfp:timing:runDMDTimingSweep:daqCleanupFailed', ...
        'DAQ cleanup failed: %s', ME.message);
end

end % teardown


% =========================================================================
% Local helper -- canonical empty metrics record (FULL schema)
% =========================================================================
function m = emptyMetrics(rate)
%emptyMetrics Return a fully-populated empty metrics struct.
%
%   Defines the EXACT field set and order used by analyzeTimingTrace so that
%   failed-rate placeholders and normalised records can be concatenated into
%   a single struct array.  Scalar numerics are NaN, vectors are [], the
%   tracking flag is false, droppedFraction is NaN (unknown), edges holds
%   empty columns, and notes is an empty cellstr.

if nargin < 1 || isempty(rate)
    rate = NaN;
end

m = struct();
m.commandedRateHz     = rate;     % echoed even for an empty/failed row
m.nTriggerEdges       = NaN;
m.nOpticalTransitions = NaN;

m.highLevelV = NaN;
m.lowLevelV  = NaN;
m.contrastV  = NaN;

m.latency_s       = [];
m.latencyMean_s   = NaN;
m.latencyMedian_s = NaN;
m.latencyStd_s    = NaN;

m.riseTime_s = [];
m.fallTime_s = [];
m.riseMean_s = NaN;
m.fallMean_s = NaN;

m.achievedRateHz = NaN;
m.intervalStd_s  = NaN;
m.jitter_s       = NaN;
m.dutyCycle      = NaN;

m.trackingOK      = false;
m.droppedFraction = NaN;          % NaN == "unknown" for an empty/failed row

m.edges = struct( ...
    'trigEdgeIdx', zeros(0, 1), ...
    'optEdgeIdx',  zeros(0, 1), ...
    'optEdgeSign', zeros(0, 1));

m.notes = {};

end % emptyMetrics


% =========================================================================
% Local helper -- normalise a metrics struct to the canonical schema
% =========================================================================
function mOut = normalizeMetrics(m)
%normalizeMetrics Fill missing fields from emptyMetrics and fix field order.
%
%   Takes a metrics struct M (possibly missing fields, possibly with fields
%   in a different order) and returns a struct with EXACTLY the canonical
%   schema fields, in canonical order, copying across every field M provides.
%   This guarantees every entry assigned into the result struct array is
%   field-compatible.

% Start from the canonical template, preserving the commanded rate if M has
% one (so empty/failed rows keep their rate label).
if isfield(m, 'commandedRateHz') && ~isempty(m.commandedRateHz)
    template = emptyMetrics(m.commandedRateHz);
else
    template = emptyMetrics(NaN);
end

mOut       = template;
canonical  = fieldnames(template);

for k = 1 : numel(canonical)
    f = canonical{k};
    if isfield(m, f)
        mOut.(f) = m.(f);
    end
    % Fields absent from M keep their canonical empty/NaN/false default.
end

% orderfields is defensive: copying field-by-field already produces the
% template's order, but this makes the invariant explicit and robust to any
% future change in how mOut is built.
mOut = orderfields(mOut, canonical);

end % normalizeMetrics


% =========================================================================
% Local helper -- print an aligned per-rate summary table to the console
% =========================================================================
function printSummary(result)
%printSummary Pretty-print the sweep result as an aligned text table.
%
%   One row per commanded rate showing latency / rise / fall (in µs),
%   achieved rate, dropped fraction, and the tracking flag, followed by the
%   maximum reliable switching rate.  Non-finite values render as "NaN".

ratesHz = result.ratesHz;
metrics = result.metrics;
nRates  = numel(ratesHz);

fprintf('\n');
fprintf('==================== DMD timing sweep summary ====================\n');
fprintf('device: %s   |   hardware: %s   |   session: %s\n', ...
    safeStr(result.cfg.device), safeStr(result.cfg.hardwareKind), result.sessionDir);
fprintf('------------------------------------------------------------------\n');
% Column header (widths chosen so numbers below stay aligned).
fprintf('%10s %11s %9s %9s %12s %9s %8s\n', ...
    'cmd(Hz)', 'lat(us)', 'rise(us)', 'fall(us)', 'achvd(Hz)', 'drop', 'track');
fprintf('------------------------------------------------------------------\n');

for i = 1 : nRates
    m = metrics(i);
    fprintf('%10s %11s %9s %9s %12s %9s %8s\n', ...
        fmtNum(ratesHz(i),            '%.0f'), ...
        fmtNum(m.latencyMean_s * 1e6, '%.2f'), ...   % s -> us
        fmtNum(m.riseMean_s    * 1e6, '%.2f'), ...
        fmtNum(m.fallMean_s    * 1e6, '%.2f'), ...
        fmtNum(m.achievedRateHz,      '%.0f'), ...
        fmtNum(m.droppedFraction,     '%.3f'), ...
        boolStr(m.trackingOK));
end

fprintf('------------------------------------------------------------------\n');
if isfinite(result.maxReliableRateHz)
    fprintf('max reliable switching rate: %.0f Hz\n', result.maxReliableRateHz);
else
    fprintf('max reliable switching rate: NaN (no rate tracked reliably)\n');
end
fprintf('==================================================================\n\n');

end % printSummary


% =========================================================================
% Small formatting helpers
% =========================================================================
function s = fmtNum(x, fmt)
%fmtNum Format a scalar with FMT, rendering empty/non-finite as 'NaN'.
if isempty(x) || ~isnumeric(x) || ~isscalar(x) || ~isfinite(x)
    s = 'NaN';
else
    s = sprintf(fmt, x);
end
end % fmtNum

function s = boolStr(b)
%boolStr Render a logical flag as 'yes'/'no' (or 'NaN' if not logical-able).
if islogical(b) && isscalar(b)
    if b, s = 'yes'; else, s = 'no'; end
elseif isnumeric(b) && isscalar(b) && isfinite(b)
    if b ~= 0, s = 'yes'; else, s = 'no'; end
else
    s = 'NaN';
end
end % boolStr

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
