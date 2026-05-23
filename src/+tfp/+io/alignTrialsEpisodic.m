function [perTrial, perFrame, report] = alignTrialsEpisodic(trials, tiffPaths, frameStartSamples, sampleRate)
%alignTrialsEpisodic Per-trial cross-check aligner for episodic ScanImage acquisition.
%
%   TEST-ONLY RESET HOOK
%   --------------------
%   Pass the sentinel char/string '__resetWarnings__' as the only argument
%   to clear the persistent one-shot warning flags
%   (tfp:io:alignTrialsEpisodic:lowConfidence and
%    tfp:io:alignTrialsEpisodic:overlap). Intended for test setup only.
%   Production callers should use
%   tfp.io.resetAlignTrialsEpisodicWarnings(), the thin public wrapper for
%   this sentinel.
%
%   [perTrial, perFrame, report] = tfp.io.alignTrialsEpisodic( ...
%       trials, tiffPaths, frameStartSamples, sampleRate)
%
%   The episodic aligner replaces tfp.io.alignTrialsToFrames in the
%   episodic-ScanImage architecture documented in docs/SYNC_EPISODIC.md
%   §7. The TIFF written for each trial is, by construction, that
%   trial's primary frame source; the frame-clock DI is retained as a
%   per-trial CROSS-CHECK rather than a global alignment anchor.
%
%   For every input trial the aligner reads the trial's TIFF metadata
%   (via tfp.io.readScanImageTiff — `.mat` mock sidecars are
%   transparently supported), counts the frame-clock rising edges that
%   fall inside the trial's full ACQUISITION window
%   [t_onset - preStim_s*sr, t_offset + postStim_s*sr] — i.e. the same
%   span over which ScanImage actually acquired frames into the per-trial
%   TIFF — and emits a confidence tier:
%
%     |discrepancy| <= 1            -> "high"
%     1 < |discrepancy| <= 5        -> "low"
%     |discrepancy| > 5, or         -> "quarantine"
%       missing TIFF, or
%       unreadable TIFF, or
%       trial not 'complete', or
%       no DAQ anchor on trial
%
%   where `discrepancy = numFramesTiff - numFramesDI`. Per-trial failures
%   never become session-fatal; session-fatal status is reserved for
%   conditions that invalidate the cross-check globally (see §11):
%
%     - numel(tiffPaths) ~= numel(trials)
%     - sample-rate mismatch (>1 ppm) against any trial's anchor
%     - non-monotonic frameStartSamples
%
%   Inputs
%   ------
%   trials             - 1xN array of tfp.trial.Trial (may be empty).
%   tiffPaths          - cellstr or string array, length numel(trials).
%                        Empty entries ('') signal missing TIFFs (one-trial
%                        quarantine, NOT session-fatal).
%   frameStartSamples  - uint64 vector of frame-clock DI rising-edge
%                        sample indices (from tfp.io.decodeFrameClock).
%   sampleRate         - positive scalar double, Hz. Must match each
%                        trial's daq_master_sample_rate_hz (>1 ppm
%                        tolerance).
%
%   Outputs
%   -------
%   perTrial - 1xN struct array (one row per input trial, including
%              skipped/quarantined ones). Fields:
%                .trialIdx                  scalar
%                .siTiffPath                char (echo of input)
%                .numFramesTiff             uint32
%                .numFramesDI               uint32 (count of DI rising
%                                            edges in the acquisition
%                                            window [baselineStart, acqEnd]
%                                            — this is what cross-checks
%                                            against numFramesTiff)
%                .frame_indices_during_stim 1xK uint64 (DI indices)
%                .frame_indices_baseline    1xK uint64 (DI indices)
%                .alignmentDiscrepancy      double (NaN when either path
%                                            was unavailable)
%                .alignmentConfidence       string ("high"|"low"|
%                                            "quarantine"|"none")
%                .reason                    string ("" on high)
%
%   perFrame - table with one row per frameStartSamples entry:
%                  frameIdx         uint64  1-based index into
%                                           frameStartSamples
%                  frameStartSample uint64  DAQ sample of rising edge
%                  trialIdx         double  NaN if frame in no window
%                  phase            string  "stim"|"baseline"|"none"
%              When two stim windows overlap, the earliest trial in
%              input order wins; a one-shot
%              tfp:io:alignTrialsEpisodic:overlap warning is issued.
%
%   report   - struct, session-level diagnostic summary:
%                .fatal                logical (true => no Trial was
%                                       updated; see below)
%                .fatalReason          string
%                .numTrialsInput       double
%                .numTrialsAligned     uint32 (high+low)
%                .numTrialsSkipped     uint32 (quarantine+none)
%                .skippedTrials        struct array {trialIdx, reason}
%                .confidenceCounts     struct(high,low,quarantine,none)
%                .sampleRate           double (echo)
%                .meanFrameRateInferred double (sampleRate /
%                                       median(diff(frameStartSamples));
%                                       NaN when <2 edges)
%                .totalFramesInDI      uint32
%
%   Caller workflow
%   ---------------
%   The aligner does NOT mutate Trial objects directly. For each row of
%   perTrial with alignmentConfidence in {"high","low"}, the caller
%   should invoke
%
%       trials(i).attachEpisodicAlignment( ...
%           perTrial(i).frame_indices_during_stim, ...
%           perTrial(i).frame_indices_baseline,    ...
%           perTrial(i).alignmentDiscrepancy,      ...
%           perTrial(i).alignmentConfidence);
%
%   Quarantined trials are left untouched on the Trial side so the
%   operator can still see the report's per-trial diagnostics.
%
%   Errors
%   ------
%   tfp:io:alignTrialsEpisodic:badTrials      trials not Trial[] or empty
%   tfp:io:alignTrialsEpisodic:badPaths       tiffPaths shape or type bad
%   tfp:io:alignTrialsEpisodic:badFrames      frameStartSamples invalid
%   tfp:io:alignTrialsEpisodic:badSampleRate  sampleRate non-positive
%
%   Warnings (one-shot per MATLAB session)
%   --------------------------------------
%   tfp:io:alignTrialsEpisodic:overlap        stim windows overlapped
%   tfp:io:alignTrialsEpisodic:lowConfidence  at least one trial in "low"
%
%   See also tfp.io.alignTrialsToFrames (DEPRECATED),
%   tfp.io.readScanImageTiff, tfp.io.decodeFrameClock,
%   tfp.trial.Trial.attachEpisodicAlignment.

% -------- Test-only reset hook (sentinel first argument).
% Callers should use tfp.io.resetAlignTrialsEpisodicWarnings() rather than
% poking this sentinel directly; documented here so the gate is one place.
if nargin == 1 && (ischar(trials) || (isstring(trials) && isscalar(trials))) ...
        && strcmp(string(trials), "__resetWarnings__")
    resetOneShotWarnings();
    if nargout > 0
        perTrial = makeEmptyPerTrial(0);
        perFrame = buildPerFrame(uint64.empty(0, 1), ...
            nan(0, 1), strings(0, 1));
        report = struct( ...
            'fatal', false, 'fatalReason', "", ...
            'numTrialsInput', 0, ...
            'numTrialsAligned', uint32(0), ...
            'numTrialsSkipped', uint32(0), ...
            'skippedTrials', emptySkipStruct(), ...
            'confidenceCounts', struct('high', 0, 'low', 0, 'quarantine', 0, 'none', 0), ...
            'sampleRate', NaN, ...
            'meanFrameRateInferred', NaN, ...
            'totalFramesInDI', uint32(0));
    end
    return
end

% -------- Input validation (throw-side; session-fatal cases handled below).

if ~isempty(trials) && ~isa(trials, 'tfp.trial.Trial')
    error('tfp:io:alignTrialsEpisodic:badTrials', ...
        'trials must be a tfp.trial.Trial array or empty; got %s.', ...
        class(trials));
end
trials = reshape(trials, 1, []);
nTrials = numel(trials);

if ~(iscell(tiffPaths) || isstring(tiffPaths))
    error('tfp:io:alignTrialsEpisodic:badPaths', ...
        'tiffPaths must be cellstr or string array; got %s.', class(tiffPaths));
end
tiffPaths = tiffPathsToCellstr(tiffPaths);

if ~isnumeric(frameStartSamples) && ~islogical(frameStartSamples)
    error('tfp:io:alignTrialsEpisodic:badFrames', ...
        'frameStartSamples must be a numeric vector; got %s.', class(frameStartSamples));
end
if ~isempty(frameStartSamples) && ~isvector(frameStartSamples)
    error('tfp:io:alignTrialsEpisodic:badFrames', ...
        'frameStartSamples must be a vector.');
end

if ~(isnumeric(sampleRate) && isscalar(sampleRate) && isfinite(sampleRate) ...
        && sampleRate > 0)
    error('tfp:io:alignTrialsEpisodic:badSampleRate', ...
        'sampleRate must be a positive finite scalar; got %s.', class(sampleRate));
end
sampleRate = double(sampleRate);

fss        = uint64(frameStartSamples(:));
fssDouble  = double(fss);
nFrames    = numel(fss);

% -------- Pre-allocate outputs (empty / shaped correctly even on fatal).
% IMPORTANT: per the §7.3 contract, session-fatal checks must run BEFORE
% any per-trial pre-population so that a precondition violation (e.g.
% tiffPaths length mismatch) returns a properly-shaped fatal report rather
% than tripping MATLAB:badsubscript.

perTrial = makeEmptyPerTrial(nTrials);

trialIdxCol = nan(nFrames, 1);
phaseCol    = strings(nFrames, 1);
phaseCol(:) = "none";

report = struct( ...
    'fatal',                false, ...
    'fatalReason',          "", ...
    'numTrialsInput',       nTrials, ...
    'numTrialsAligned',     uint32(0), ...
    'numTrialsSkipped',     uint32(0), ...
    'skippedTrials',        emptySkipStruct(), ...
    'confidenceCounts',     struct('high', 0, 'low', 0, 'quarantine', 0, 'none', 0), ...
    'sampleRate',           sampleRate, ...
    'meanFrameRateInferred', inferMeanFrameRate(fss, sampleRate), ...
    'totalFramesInDI',      uint32(nFrames));

% -------- Session-fatal checks (per SYNC_EPISODIC.md §7.3 / §11).
% These run BEFORE any per-trial loop so that on a fatal precondition the
% function returns the documented empty-but-shaped outputs instead of
% throwing.

if numel(tiffPaths) ~= nTrials
    report = markFatal(report, ...
        sprintf('numel(tiffPaths)=%d does not match numel(trials)=%d.', ...
        numel(tiffPaths), nTrials));
    perFrame = buildPerFrame(fss, trialIdxCol, phaseCol);
    return
end

if nFrames >= 2
    d = diff(fssDouble);
    if any(d <= 0)
        report = markFatal(report, ...
            'frameStartSamples is not strictly monotonically increasing.');
        perFrame = buildPerFrame(fss, trialIdxCol, phaseCol);
        return
    end
end

% Sample-rate match: compare against every trial that has a valid sr anchor.
for i = 1:nTrials
    tr = trials(i);
    if ~isnan(tr.daq_master_sample_rate_hz)
        rel = abs(tr.daq_master_sample_rate_hz - sampleRate) / sampleRate;
        if rel > 1e-6
            report = markFatal(report, sprintf( ...
                ['Trial %d daq_master_sample_rate_hz=%.6f Hz disagrees with ' ...
                 'sampleRate=%.6f Hz by %.3g (>1 ppm).'], ...
                double(tr.trialIdx), tr.daq_master_sample_rate_hz, sampleRate, rel));
            perFrame = buildPerFrame(fss, trialIdxCol, phaseCol);
            return
        end
    end
end

% -------- Per-trial pre-population (only reached after fatal checks pass).
for i = 1:nTrials
    perTrial(i).trialIdx   = trials(i).trialIdx;
    perTrial(i).siTiffPath = tiffPaths{i};
end

% -------- Per-trial alignment.

windows = repmat(struct( ...
    'onset',    NaN, ...
    'offset',   NaN, ...
    'baseline', NaN, ...
    'valid',    false), 1, nTrials);

for i = 1:nTrials
    tr        = trials(i);
    pt        = perTrial(i);
    diIndices = uint64.empty(1, 0);
    baseIndices = uint64.empty(1, 0);
    acqCount  = uint32(0);

    % 1) Non-complete trials.
    if ~strcmp(tr.status, 'complete')
        pt.alignmentConfidence = "none";
        pt.reason = "trial-not-complete";
        report = recordSkip(report, tr.trialIdx, pt.reason);
        perTrial(i) = pt;
        continue
    end

    % 2) No DAQ anchors.
    if isnan(tr.t_onset_daq_samples) || isnan(tr.t_offset_daq_samples)
        pt.alignmentConfidence = "none";
        pt.reason = "no-daq-anchor";
        report = recordSkip(report, tr.trialIdx, pt.reason);
        perTrial(i) = pt;
        continue
    end

    onset  = double(tr.t_onset_daq_samples);
    offset = double(tr.t_offset_daq_samples);
    preS   = tr.preStim_s;
    if isempty(preS) || ~isnumeric(preS) || isnan(preS)
        preS = 0;
    end
    postS  = tr.postStim_s;
    if isempty(postS) || ~isnumeric(postS) || isnan(postS)
        postS = 0;
    end
    baselineStart = onset  - double(preS)  * sampleRate;
    acqEnd        = offset + double(postS) * sampleRate;

    windows(i) = struct( ...
        'onset',    onset, ...
        'offset',   offset, ...
        'baseline', baselineStart, ...
        'valid',    true);

    % Compute DI-derived frame indices (path B). frame_indices_during_stim
    % and frame_indices_baseline are masks within the stim and baseline
    % windows respectively (used by downstream analysis to bin frames by
    % phase). numFramesDI is the count of frames in the full per-trial
    % ACQUISITION window [baselineStart, acqEnd] — that is the count the
    % per-trial TIFF should match, since ScanImage acquired one frame per
    % rising edge across the whole arm-to-completion window. Using the
    % stim window alone for the cross-check would produce a guaranteed
    % large discrepancy whenever preStim_s + postStim_s exceed the stim
    % duration.
    if nFrames > 0
        inStim = fssDouble >= onset & fssDouble <= offset;
        diIndices = uint64(reshape(find(inStim), 1, []));

        if preS > 0
            inBaseline = fssDouble >= baselineStart & fssDouble < onset;
            baseIndices = uint64(reshape(find(inBaseline), 1, []));
        end

        inAcq = fssDouble >= baselineStart & fssDouble <= acqEnd;
        acqCount = uint32(nnz(inAcq));
    end

    pt.numFramesDI               = acqCount;
    pt.frame_indices_during_stim = diIndices;
    pt.frame_indices_baseline    = baseIndices;

    % 3) Missing TIFF path.
    pathStr = tiffPaths{i};
    if isempty(pathStr)
        pt.alignmentConfidence = "quarantine";
        pt.reason              = "missing-tiff";
        pt.numFramesTiff       = uint32(0);
        pt.alignmentDiscrepancy = NaN;
        report = recordSkip(report, tr.trialIdx, pt.reason);
        perTrial(i) = pt;
        continue
    end

    % 4) Read TIFF metadata.
    tiffReadable = true;
    meta = [];
    try
        meta = tfp.io.readScanImageTiff(pathStr);
    catch
        tiffReadable = false;
    end

    if ~tiffReadable
        pt.alignmentConfidence  = "quarantine";
        pt.reason               = "tiff-unreadable";
        pt.numFramesTiff        = uint32(0);
        pt.alignmentDiscrepancy = NaN;
        report = recordSkip(report, tr.trialIdx, pt.reason);
        perTrial(i) = pt;
        continue
    end

    numFramesTiff       = uint32(meta.numFrames);
    pt.numFramesTiff    = numFramesTiff;

    % Discrepancy and confidence tier. Cross-check is against the full
    % per-trial acquisition window (numFramesDI == acqCount), NOT the
    % stim-only window — see comment above where acqEnd is computed.
    if numFramesTiff == 0 || acqCount == 0
        pt.alignmentDiscrepancy = NaN;
        pt.alignmentConfidence  = "quarantine";
        if numFramesTiff == 0
            pt.reason = "tiff-empty";
        else
            pt.reason = "no-di-edges-in-window";
        end
        report = recordSkip(report, tr.trialIdx, pt.reason);
        perTrial(i) = pt;
        continue
    end

    d = double(numFramesTiff) - double(acqCount);
    pt.alignmentDiscrepancy = d;
    absD = abs(d);
    if absD <= 1
        pt.alignmentConfidence = "high";
        pt.reason              = "";
    elseif absD <= 5
        pt.alignmentConfidence = "low";
        pt.reason              = string(sprintf('discrepancy=%d', int32(d)));
    else
        pt.alignmentConfidence = "quarantine";
        pt.reason              = string(sprintf('discrepancy=%d', int32(d)));
    end

    perTrial(i) = pt;
end

% Tally aligned/skipped counts and confidence buckets.
for i = 1:nTrials
    c = perTrial(i).alignmentConfidence;
    switch c
        case "high"
            report.confidenceCounts.high = report.confidenceCounts.high + 1;
            report.numTrialsAligned      = report.numTrialsAligned + uint32(1);
        case "low"
            report.confidenceCounts.low  = report.confidenceCounts.low + 1;
            report.numTrialsAligned      = report.numTrialsAligned + uint32(1);
        case "quarantine"
            report.confidenceCounts.quarantine = report.confidenceCounts.quarantine + 1;
            report.numTrialsSkipped            = report.numTrialsSkipped + uint32(1);
            % Quarantined trials that weren't already recorded as skipped
            % (they were if reason came via the per-trial paths above; we
            % only need to ensure the count is correct, which it is).
        otherwise % "none"
            report.confidenceCounts.none = report.confidenceCounts.none + 1;
            report.numTrialsSkipped      = report.numTrialsSkipped + uint32(1);
    end
end

% One-shot lowConfidence warning if any trial landed in "low" tier.
if report.confidenceCounts.low > 0
    oneShotLowConfidenceWarning();
end

% -------- perFrame assembly.

% First pass: baseline.
for i = 1:nTrials
    w = windows(i);
    if ~w.valid || nFrames == 0
        continue
    end
    if isnan(w.baseline) || w.baseline >= w.onset
        continue
    end
    inBaseline = fssDouble >= w.baseline & fssDouble < w.onset;
    sel = inBaseline & phaseCol == "none";
    trialIdxCol(sel) = double(trials(i).trialIdx);
    phaseCol(sel)    = "baseline";
end

% Second pass: stim assignment (overrides baseline; earliest in input order
% wins among overlapping stim windows, matching alignTrialsToFrames).
for i = 1:nTrials
    w = windows(i);
    if ~w.valid || nFrames == 0
        continue
    end
    inStim = fssDouble >= w.onset & fssDouble <= w.offset;
    if any(inStim & phaseCol == "stim")
        oneShotOverlapWarning();
    end
    sel = inStim & phaseCol ~= "stim";
    trialIdxCol(sel) = double(trials(i).trialIdx);
    phaseCol(sel)    = "stim";
end

perFrame = buildPerFrame(fss, trialIdxCol, phaseCol);

end

% =========================================================================
% Helpers
% =========================================================================

function pt = makeEmptyPerTrial(n)
%makeEmptyPerTrial Allocate an N-entry perTrial struct array with defaults.
template = struct( ...
    'trialIdx',                  NaN, ...
    'siTiffPath',                '', ...
    'numFramesTiff',             uint32(0), ...
    'numFramesDI',               uint32(0), ...
    'frame_indices_during_stim', uint64.empty(1, 0), ...
    'frame_indices_baseline',    uint64.empty(1, 0), ...
    'alignmentDiscrepancy',      NaN, ...
    'alignmentConfidence',       "none", ...
    'reason',                    "");
if n == 0
    pt = repmat(template, 1, 0);
else
    pt = repmat(template, 1, n);
end
end

function s = emptySkipStruct()
template = struct('trialIdx', NaN, 'reason', "");
s = repmat(template, 1, 0);
end

function report = recordSkip(report, trialIdx, reason)
entry = struct('trialIdx', trialIdx, 'reason', string(reason));
report.skippedTrials(end+1) = entry; %#ok<AGROW>
end

function report = markFatal(report, reasonStr)
report.fatal       = true;
report.fatalReason = string(reasonStr);
end

function rate = inferMeanFrameRate(fss, sampleRate)
if numel(fss) < 2
    rate = NaN;
    return
end
m = median(double(diff(double(fss))));
if ~isfinite(m) || m <= 0
    rate = NaN;
    return
end
rate = sampleRate / m;
end

function cellOut = tiffPathsToCellstr(p)
if iscell(p)
    cellOut = cell(1, numel(p));
    for k = 1:numel(p)
        if isempty(p{k})
            cellOut{k} = '';
        elseif ischar(p{k})
            cellOut{k} = p{k};
        elseif isstring(p{k}) && isscalar(p{k})
            cellOut{k} = char(p{k});
        else
            error('tfp:io:alignTrialsEpisodic:badPaths', ...
                'tiffPaths entries must be char or scalar string.');
        end
    end
else % isstring
    cellOut = cell(1, numel(p));
    for k = 1:numel(p)
        cellOut{k} = char(p(k));
    end
end
end

function perFrame = buildPerFrame(fss, trialIdxCol, phaseCol)
nFrames          = numel(fss);
frameIdx         = uint64((1:nFrames).');
frameStartSample = fss;
perFrame = table(frameIdx, frameStartSample, trialIdxCol, phaseCol, ...
    'VariableNames', {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});
end

function oneShotLowConfidenceWarning(reset)
persistent warnedLow
if nargin >= 1 && reset
    warnedLow = false;
    return
end
if isempty(warnedLow) || ~warnedLow
    warning('tfp:io:alignTrialsEpisodic:lowConfidence', ...
        ['At least one trial landed in the "low" confidence tier ' ...
         '(1 < |discrepancy| <= 5). Inspect report.perTrial for details.']);
    warnedLow = true;
end
end

function oneShotOverlapWarning(reset)
persistent warnedOverlap
if nargin >= 1 && reset
    warnedOverlap = false;
    return
end
if isempty(warnedOverlap) || ~warnedOverlap
    warning('tfp:io:alignTrialsEpisodic:overlap', ...
        ['Overlapping stim windows detected; earliest trial in input ' ...
         'order wins.']);
    warnedOverlap = true;
end
end

function resetOneShotWarnings()
%resetOneShotWarnings Clear both persistent one-shot warning flags.
%   Invoked via the '__resetWarnings__' sentinel; intended for test setup.
oneShotLowConfidenceWarning(true);
oneShotOverlapWarning(true);
end
