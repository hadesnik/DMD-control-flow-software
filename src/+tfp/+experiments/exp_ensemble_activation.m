function result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib, options)
%exp_ensemble_activation Photostimulate a neuronal ensemble via three trial types.
%
%   Runs three stimulus conditions against a pre-defined set of ROIs whose
%   centroids are provided in ScanImage scan-field coordinates:
%
%     Sequential condition — each ROI stimulated alone in order.
%       Timing per ROI: 500 ms laser ON, 500 ms laser OFF.
%       The DMD pattern shows only the single target ROI during each pulse.
%
%     Ensemble condition — all ROIs stimulated simultaneously at full power.
%       Timing: 500 ms laser ON, 500 ms laser OFF (one pulse).
%       The DMD pattern is the logical OR of all individual ROI patterns.
%
%     Power-series condition — ensemble pattern repeated at 5 power levels.
%       Fractions of max power: [0.2, 0.4, 0.6, 0.8, 1.0].
%       AO voltages are looked up from options.powerCurve (output of
%       powerMeterSweep); if no curve is provided, voltages are scaled
%       linearly from options.powerV.
%       Timing per level: 500 ms laser ON, 500 ms laser OFF.
%
%   TASK-EP (T-EP-3a): the experiment drives ScanImage **episodically** —
%   one TIFF per trial via `siBridge.armForExternalTrigger` /
%   `waitForCompletion` / `getLastTiffPath`. The single continuous DAQ
%   session is preserved (clocked AO, AI/DI capture); the per-trial DO
%   pulse on `syncDOLine` is now the start-acq TTL that arms ScanImage's
%   external trigger, not a host-side alignment anchor. After the trial
%   loop the captured frame-clock DI is decoded and the trial set is
%   handed to `tfp.io.alignTrialsEpisodic` for per-trial cross-check.
%   See docs/SYNC_EPISODIC.md.
%
%   result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib)
%   result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib, options)
%
%   Inputs:
%     dmd                - tfp.hardware.DMD subclass (MockDMD or real).
%     daq                - tfp.hardware.DAQ subclass (MockDAQ or real).
%     roiCentroids_scan  - Nx2 double, [x y] centroids in ScanImage scan-field
%                          coordinates (same units used during calibration).
%     calib              - Calibration struct containing .dmdToScan_affine (3×3).
%                          Produced by tfp.calibration.composeCalibration.
%                          For mock/identity mapping pass eye(3) as the affine.
%     options            - Struct (all fields optional):
%       .siBridge        - tfp.hardware.ScanImageBridge (real) or
%                          tfp.hardware.MockScanImageBridge. Required for
%                          episodic acquisition; if empty, the experiment runs
%                          its stims without arming ScanImage and the
%                          per-trial TIFF path will be ''.
%       .siBridgeBeginSessionOpts
%                        - Struct passed to siBridge.beginSession(opts).
%                          Useful for tests to set
%                          .startAcqNumOverride / .logFileStemOverride etc.
%                          Default struct().
%       .spotRadiusPx    - DMD spot radius in pixels (default 14, i.e. ~28 px
%                          diameter ~ 10 µm cell at the sample).
%       .illuminatedRegion - [c0 c1 r0 r1] bounding box (DMD px) of the
%                          flat-top illuminated region. If set, a warning is
%                          emitted when any ROI disk (centroid +/- spotRadiusPx)
%                          extends outside this region. Default [] (no check).
%       .stimDurationS   - Stim pulse duration in seconds (default 0.5).
%       .interStimS      - Gap between sequential pulses in seconds (default 0.5).
%       .aoChannel       - AO channel for laser modulation (default 'ao1').
%                          Used only for the pre- and post-experiment safety
%                          calls to `outputSingleAnalog(0)`.
%       .aoChannelIdx    - Numeric AO channel index used for the clocked-AO
%                          waveform via `queueClockedAO` and declared as
%                          `cfg.aoChannels` to `startContinuousSession`
%                          (default 1).
%       .sampleRate      - DAQ master sample rate (Hz) for the continuous
%                          session (default 10000).
%       .powerV          - Voltage for laser ON at full power (default 5.0 V).
%       .powerCurve      - Struct from powerMeterSweep with fields .voltageV
%                          and .powerMw (merged curve). Used to convert power
%                          fractions to AO voltages. If empty, voltages are
%                          scaled linearly from powerV (default []).
%       .powerFractions        - 1xK vector of power fractions for the power-series
%                                condition (default [0.2 0.4 0.6 0.8 1.0]).
%       .powerSeriesInterStimS - ISI between power-series pulses in seconds
%                                (default 3.0 — allows GCaMP signal to return
%                                to baseline between levels).
%       .showLiveFigure  - Display live DMD pattern figure (default true).
%       .sessionDir      - Directory for log output and per-trial .mat files
%                          (default ''). If non-empty, each stim is saved via
%                          `tfp.io.saveTrial` under `<sessionDir>/trials/`.
%       .saveTrials      - Force-enable/disable per-trial saving. Defaults
%                          to true when `sessionDir` is non-empty.
%       .syncDOLine      - DO line that emits the per-trial start-acq TTL
%                          into ScanImage. Default 'port0/line10'. Set to ''
%                          to skip the pulse (useful for pure-mock smoke
%                          tests without a configured DO line).
%       .startAcqPulseS  - Width of the per-trial start-acq pulse (s),
%                          default 2e-4 (200 µs).
%       .sessionStartPulseS - Width of the long operator-visible pulse
%                          emitted on syncDOLine at session start (s),
%                          default 0.100. Set to 0 to skip.
%       .frameClockLine  - DI line carrying the ScanImage frame-clock TTL.
%                          When set, the line is added to the continuous
%                          session and the captured DI is decoded post-hoc
%                          for the per-trial cross-check. Default '' (mock
%                          path leaves this empty and the aligner runs with
%                          an empty `frameStartSamples` vector — every
%                          trial then quarantines on `no-di-edges-in-window`
%                          which is acceptable for the mock smoke test).
%       .bufferFrames    - Extra frames added to the per-trial framesPerTrial
%                          to absorb ScanImage external-trigger arm latency
%                          (default 2).
%       .waitTimeoutFactor - Multiplier on `trial.duration_s` used as the
%                          siBridge.waitForCompletion timeout (default 1.5,
%                          i.e. 50% headroom).
%
%   Output result struct:
%     .nROIs                       - Number of ROIs targeted.
%     .nSequentialTrials           - Number of sequential pulses delivered (= nROIs).
%     .nEnsembleTrials             - 1.
%     .nPowerSeriesTrials          - Number of power-series pulses.
%     .powerSeriesVoltages         - AO voltages used for each power-series trial (V).
%     .powerSeriesFractions        - Power fractions used.
%     .dmdCentroids                - Nx2 DMD-pixel coords for each ROI.
%     .stimDurationS               - Stim duration used (s).
%     .interStimS                  - Inter-stim gap used (s).
%     .powerV                      - Full-power AO voltage (V).
%     .sampleRate                  - DAQ session sampleRate (Hz).
%     .sessionStartDatetime        - Wall-clock anchor (host snapshot at start).
%     .sequentialOnsetSamples      - uint64 N×1 t_onset_daq_samples per ROI.
%     .sequentialOffsetSamples     - uint64 N×1 t_offset_daq_samples per ROI.
%     .ensembleOnsetSample         - uint64 scalar.
%     .ensembleOffsetSample        - uint64 scalar.
%     .powerSeriesOnsetSamples     - uint64 K×1.
%     .powerSeriesOffsetSamples    - uint64 K×1.
%     .trialIndices                - struct with .sequential, .ensemble,
%                                    .powerSeries giving the trialIdx values
%                                    used when saving via tfp.io.saveTrial.
%     .trials                      - tfp.trial.Trial array, one per stim (all
%                                    conditions concatenated in trialIdx
%                                    order). Carries per-trial siTiffPath +
%                                    episodic alignment after the post-hoc
%                                    aligner runs.
%     .tiffPaths                   - cellstr, one entry per trial in
%                                    `result.trials`. '' for trials that ran
%                                    without a bridge.
%     .sessionData                 - Result of `stopContinuousSession`
%                                    (aiData, diData, etc).
%     .timing.sessionInfo          - Echo of siBridge.beginSession output
%                                    (empty struct if no bridge).
%     .frameStartSamples           - Decoded frame-clock rising-edge samples
%                                    (uint64 column vector). Empty when
%                                    no frame-clock DI line was configured.
%     .frameRateInferredHz         - Median-of-intervals inference, or NaN.
%     .alignReport                 - Output of tfp.io.alignTrialsEpisodic.
%     .perTrialAlignment           - Per-trial struct array from the aligner.
%     .perFrame                    - Per-frame table from the aligner.
%     .completedAt                 - datetime of completion.
%
%   See also tfp.io.receiveROIsFromScanImage, tfp.calibration.composeCalibration,
%            tfp.io.saveTrial, tfp.io.alignTrialsEpisodic, docs/SYNC_EPISODIC.md.

if nargin < 5 || isempty(options)
    options = struct();
end

siBridge       = configField(options, 'siBridge',       []);
beginSessionOpts = configField(options, 'siBridgeBeginSessionOpts', struct());
spotRadiusPx   = configField(options, 'spotRadiusPx',   14);
illuminatedRegion = configField(options, 'illuminatedRegion', []);
stimDurationS  = configField(options, 'stimDurationS',  0.5);
interStimS     = configField(options, 'interStimS',     0.5);
aoChannel      = configField(options, 'aoChannel',      'ao1');
aoChannelIdx   = configField(options, 'aoChannelIdx',   1);
sampleRate     = configField(options, 'sampleRate',     10000);
powerV         = configField(options, 'powerV',         5.0);
powerCurve            = configField(options, 'powerCurve',            []);
powerFractions        = configField(options, 'powerFractions',        0.2:0.2:1.0);
powerSeriesInterStimS = configField(options, 'powerSeriesInterStimS', 3.0);
showLiveFigure = configField(options, 'showLiveFigure', true);
sessionDir     = configField(options, 'sessionDir',     '');
saveTrials     = configField(options, 'saveTrials',     ~isempty(sessionDir));
exposureUs     = configField(options, 'exposureUs',     5000);   % µs per pattern frame
darkTimeUs     = configField(options, 'darkTimeUs',     0);
frameClockLine = configField(options, 'frameClockLine', '');    % DI line carrying ScanImage frame TTL
syncDOLine         = configField(options, 'syncDOLine',         'port0/line10');
startAcqPulseS     = configField(options, 'startAcqPulseS',     2e-4);
sessionStartPulseS = configField(options, 'sessionStartPulseS', 0.100);
bufferFrames       = configField(options, 'bufferFrames',       2);
waitTimeoutFactor  = configField(options, 'waitTimeoutFactor',  1.5);
imagingFrameRate   = configField(options, 'imagingFrameRate',   30);   % Hz, for framesPerTrial

% --- Validate inputs ---
if ~isnumeric(roiCentroids_scan) || ndims(roiCentroids_scan) ~= 2 ...
        || size(roiCentroids_scan, 2) ~= 2 || size(roiCentroids_scan, 1) < 1
    error('tfp:experiments:exp_ensemble_activation:badROIs', ...
        'roiCentroids_scan must be Nx2 with N >= 1.');
end
if ~isstruct(calib) || ~isfield(calib, 'dmdToScan_affine')
    error('tfp:experiments:exp_ensemble_activation:badCalib', ...
        'calib must be a struct with field .dmdToScan_affine (3x3).');
end

if ~isempty(illuminatedRegion)
    if numel(illuminatedRegion) ~= 4 || ~all(isfinite(illuminatedRegion))
        error('tfp:experiments:exp_ensemble_activation:badRegion', ...
            'illuminatedRegion must be a 4-element [c0 c1 r0 r1] vector or [].');
    end
    illuminatedRegion = double(illuminatedRegion(:)');
    if illuminatedRegion(1) > illuminatedRegion(2) ...
            || illuminatedRegion(3) > illuminatedRegion(4)
        error('tfp:experiments:exp_ensemble_activation:badRegion', ...
            'illuminatedRegion must satisfy c0<=c1 and r0<=r1; got %s.', ...
            mat2str(illuminatedRegion));
    end
end

nROIs = size(roiCentroids_scan, 1);

% --- Convert scan-field coords -> DMD pixel coords ---
dmdCentroids = scanFieldToDMD(roiCentroids_scan, calib);

% Clamp to DMD bounds (warn if any ROI is outside)
dmdCentroids = clampToDMD(dmdCentroids, dmd, roiCentroids_scan);

% --- Soft check: ROI spots should fit inside the illuminated DMD region ---
if ~isempty(illuminatedRegion)
    c0 = illuminatedRegion(1); c1 = illuminatedRegion(2);
    r0 = illuminatedRegion(3); r1 = illuminatedRegion(4);
    outside = (dmdCentroids(:,1) - spotRadiusPx) < c0 ...
            | (dmdCentroids(:,1) + spotRadiusPx) > c1 ...
            | (dmdCentroids(:,2) - spotRadiusPx) < r0 ...
            | (dmdCentroids(:,2) + spotRadiusPx) > r1;
    if any(outside)
        warning('tfp:experiments:exp_ensemble_activation:roiOutsideIllumination', ...
            ['%d of %d ROI spots (r=%g px) extend outside the illuminated DMD ' ...
             'region [c=%g..%g, r=%g..%g]. Pixels outside this region will not ' ...
             'receive laser light. ROIs: %s'], ...
            sum(outside), size(dmdCentroids, 1), spotRadiusPx, c0, c1, r0, r1, ...
            mat2str(find(outside(:))'));
    end
end

% --- Build patterns ---
fprintf('[ensemble_activation] Generating %d spot patterns + 1 ensemble...\n', nROIs);
individualPatterns = cell(nROIs, 1);
for i = 1:nROIs
    individualPatterns{i} = tfp.patterns.singleSpot(dmd, dmdCentroids(i,:), spotRadiusPx);
end
ensemblePattern = individualPatterns{1};
for i = 2:nROIs
    ensemblePattern = ensemblePattern | individualPatterns{i};
end

% Stack all N+1 patterns for DMD sequence: [ROI_1 ... ROI_N  ensemble]
allPatterns = false(dmd.nRows, dmd.nCols, nROIs + 1);
for i = 1:nROIs
    allPatterns(:,:,i) = individualPatterns{i};
end
allPatterns(:,:, nROIs + 1) = ensemblePattern;

% --- Load sequence onto DMD ---
dmdSeqOpts.exposureUs = exposureUs;
dmdSeqOpts.darkTimeUs = darkTimeUs;
dmd.loadPatternSequence(allPatterns, dmdSeqOpts);
dmd.armSequence();

% --- Live figure ---
if showLiveFigure
    lh = initLiveFigure(dmd.nRows, dmd.nCols, dmdCentroids);
else
    lh = [];
end

% Safety: ensure laser is off at start (before opening the continuous session).
daq.outputSingleAnalog(aoChannel, 0);
cleanupLaser   = onCleanup(@() safetyOff(daq, aoChannel));        %#ok<NASGU>

% --- Start continuous, hardware-clocked DAQ session for the whole run ---
% See docs/SYNC_FRAME.md §4.1 (still load-bearing per SYNC_EPISODIC.md §4).
sessionStartDatetime = datetime('now');
diLines = daq.digitalInChannels;
if isempty(diLines)
    diLines = {};
else
    diLines = cellstr(diLines);
    diLines = diLines(:)';
end
if ~isempty(frameClockLine) && ~any(strcmp(char(frameClockLine), diLines))
    diLines{end+1} = char(frameClockLine);
end
sessionCfg = struct( ...
    'sampleRate',     sampleRate, ...
    'aiChannels',     [], ...
    'aoChannels',     aoChannelIdx, ...
    'diLines',        {diLines}, ...
    'doLines',        {{}}, ...
    'frameClockLine', char(frameClockLine));
daq.startContinuousSession(sessionCfg);
cleanupSession = onCleanup(@() ensureSessionStopped(daq));        %#ok<NASGU>

% --- Operator-visible session-start pulse on syncDOLine (long edge) ---
% Per SYNC_EPISODIC.md §4: the session-start pulse on syncDOLine survives
% for operator-visible aux-trace boundaries; the per-trial onset pulse role
% is now the start-acq TTL into ScanImage (still on the same line).
if ~isempty(syncDOLine) && sessionStartPulseS > 0
    try
        daq.sendDigitalPulse(char(syncDOLine), sessionStartPulseS);
    catch ME
        warning('tfp:experiments:exp_ensemble_activation:sessionStartPulseFailed', ...
            'session-start pulse on %s failed: %s. Continuing without it.', ...
            char(syncDOLine), ME.message);
    end
end

% --- Open the episodic ScanImage session (once per experiment) ---
sessionInfo = struct();
hasBridge   = ~isempty(siBridge);
if hasBridge
    if ~isstruct(beginSessionOpts)
        beginSessionOpts = struct();
    end
    sessionInfo = siBridge.beginSession(beginSessionOpts);
    cleanupBridge = onCleanup(@() ensureBridgeDisconnected(siBridge));   %#ok<NASGU>
end

% Per-stim waveform: constant powerV for stimDurationS, then a single 0 V
% trailing sample so the AO line returns to baseline once the queued
% waveform completes. (queueClockedAO does not implicitly drive 0 V after
% the last queued sample.)
nStimSamples = max(1, round(stimDurationS * sampleRate));

% Frames per trial — ScanImage acquires `framesPerTrial` frames per
% external trigger. preStim_s is 0 for this experiment, postStim_s is the
% ISI; we count frames that span the stim window plus a small buffer to
% absorb ScanImage's external-trigger arm latency.
framesPerTrial = uint32(max(1, ceil(stimDurationS * imagingFrameRate) + bufferFrames));
waitTimeoutS   = max(0.05, stimDurationS * waitTimeoutFactor);

% Pre-allocate per-trial sample-index buffers.
seqOnsetSamples  = zeros(nROIs, 1, 'uint64');
seqOffsetSamples = zeros(nROIs, 1, 'uint64');

% Trial index used when persisting via tfp.io.saveTrial. Sequential trials
% occupy 1..nROIs; ensemble = nROIs+1; power-series = nROIs+2 .. end.
trialIndices.sequential = (1:nROIs)';
trialIndices.ensemble   = nROIs + 1;

% Accumulator for Trial objects (one per stim, all conditions concatenated).
allTrials  = tfp.trial.Trial.empty(0, 1);
allTiffs   = {};

% =========================================================================
% Sequential condition
% =========================================================================
fprintf('\n=== SEQUENTIAL (%d ROIs, %.0f ms on / %.0f ms off) ===\n', ...
    nROIs, stimDurationS * 1e3, interStimS * 1e3);

for i = 1:nROIs
    dmd.advanceToPattern(i);

    updateFigure(lh, individualPatterns{i}, dmdCentroids, i, ...
        sprintf('Sequential  %d / %d  —  ROI %d  —  ON', i, nROIs, i));

    [tr, tiffPath] = runEpisodicTrial(daq, siBridge, hasBridge, ...
        trialIndices.sequential(i), 'sequential', i, ...
        dmdCentroids, i, powerV, stimDurationS, interStimS, ...
        nStimSamples, sampleRate, sessionStartDatetime, ...
        framesPerTrial, syncDOLine, startAcqPulseS, waitTimeoutS, ...
        aoChannel, sessionInfo, [], powerCurve);
    seqOnsetSamples(i)  = tr.t_onset_daq_samples;
    seqOffsetSamples(i) = tr.t_offset_daq_samples;
    allTrials(end+1, 1) = tr; %#ok<AGROW>
    allTiffs{end+1, 1}  = tiffPath; %#ok<AGROW>

    maybeSaveTrial(saveTrials, sessionDir, tr);

    updateFigure(lh, individualPatterns{i}, dmdCentroids, [], ...
        sprintf('Sequential  %d / %d  —  ROI %d  —  off', i, nROIs, i));

    pause(interStimS);
    fprintf('  [seq] ROI %d / %d done\n', i, nROIs);
end

% =========================================================================
% Ensemble condition
% =========================================================================
fprintf('\n=== ENSEMBLE (all %d ROIs simultaneously, %.0f ms) ===\n', ...
    nROIs, stimDurationS * 1e3);

dmd.advanceToPattern(nROIs + 1);

updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
    sprintf('Ensemble  —  all %d ROIs  —  ON', nROIs));

[trEns, ensTiff] = runEpisodicTrial(daq, siBridge, hasBridge, ...
    trialIndices.ensemble, 'ensemble', nROIs + 1, ...
    dmdCentroids, 1:nROIs, powerV, stimDurationS, interStimS, ...
    nStimSamples, sampleRate, sessionStartDatetime, ...
    framesPerTrial, syncDOLine, startAcqPulseS, waitTimeoutS, ...
    aoChannel, sessionInfo, [], powerCurve);
ensOnsetSample  = trEns.t_onset_daq_samples;
ensOffsetSample = trEns.t_offset_daq_samples;
allTrials(end+1, 1) = trEns; %#ok<AGROW>
allTiffs{end+1, 1}  = ensTiff; %#ok<AGROW>

maybeSaveTrial(saveTrials, sessionDir, trEns);

updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
    sprintf('Ensemble  —  all %d ROIs  —  done', nROIs));

pause(interStimS);
fprintf('  [ensemble] done\n');

% =========================================================================
% Power-series condition — ensemble pattern at [0.2:0.2:1.0] × max power
% =========================================================================
powerFractions  = powerFractions(:)';           % ensure row vector
nPowerLevels    = numel(powerFractions);
seriesVoltages  = zeros(1, nPowerLevels);
for k = 1:nPowerLevels
    seriesVoltages(k) = fractionToVoltage(powerFractions(k), powerCurve, powerV);
end

psOnsetSamples  = zeros(nPowerLevels, 1, 'uint64');
psOffsetSamples = zeros(nPowerLevels, 1, 'uint64');
trialIndices.powerSeries = (nROIs + 1 + (1:nPowerLevels))';

fprintf('\n=== POWER SERIES (ensemble, %d levels: %s of max, %.0f s ISI) ===\n', ...
    nPowerLevels, mat2str(powerFractions, 2), powerSeriesInterStimS);
for k = 1:nPowerLevels
    v = seriesVoltages(k);
    fprintf('  Level %d/%d: %.0f%% max  →  %.3f V\n', ...
        k, nPowerLevels, powerFractions(k) * 100, v);

    dmd.advanceToPattern(nROIs + 1);   % ensemble pattern already loaded

    updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
        sprintf('Power series  %d/%d  —  %.0f%% (%.3f V)  —  ON', ...
            k, nPowerLevels, powerFractions(k) * 100, v));

    extraMeta = struct( ...
        'powerFraction', powerFractions(k), ...
        'levelIdx',      k, ...
        'nLevels',       nPowerLevels);
    [trPs, psTiff] = runEpisodicTrial(daq, siBridge, hasBridge, ...
        trialIndices.powerSeries(k), 'powerSeries', nROIs + 1, ...
        dmdCentroids, 1:nROIs, v, stimDurationS, powerSeriesInterStimS, ...
        nStimSamples, sampleRate, sessionStartDatetime, ...
        framesPerTrial, syncDOLine, startAcqPulseS, waitTimeoutS, ...
        aoChannel, sessionInfo, extraMeta, powerCurve);
    psOnsetSamples(k)  = trPs.t_onset_daq_samples;
    psOffsetSamples(k) = trPs.t_offset_daq_samples;
    allTrials(end+1, 1) = trPs; %#ok<AGROW>
    allTiffs{end+1, 1}  = psTiff; %#ok<AGROW>

    maybeSaveTrial(saveTrials, sessionDir, trPs);

    updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
        sprintf('Power series  %d/%d  —  %.0f%%  —  off', ...
            k, nPowerLevels, powerFractions(k) * 100));

    pause(powerSeriesInterStimS);
end
fprintf('  [power series] done\n');

% --- Stop the continuous DAQ session and recover the captured data ---
sessionData = daq.stopContinuousSession();

% =========================================================================
% Post-session: decode frame-clock DI and run the episodic aligner.
% =========================================================================
frameStartSamples    = uint64.empty(0, 1);
frameRateInferredHz  = NaN;
if isstruct(sessionData) && isfield(sessionData, 'lineNames') ...
        && isfield(sessionData.lineNames, 'diLines') ...
        && ~isempty(sessionData.lineNames.diLines) ...
        && ~isempty(frameClockLine)
    diNames = sessionData.lineNames.diLines;
    if isstring(diNames); diNames = cellstr(diNames); end
    frameClockCol = find(strcmp(diNames, char(frameClockLine)), 1);
    if ~isempty(frameClockCol) && isfield(sessionData, 'diData') ...
            && size(sessionData.diData, 2) >= frameClockCol
        try
            [frameStartSamples, frameRateInferredHz] = ...
                tfp.io.decodeFrameClock( ...
                    sessionData.diData(:, frameClockCol), sessionData.sampleRate);
        catch ME
            warning('tfp:experiments:exp_ensemble_activation:frameClockDecodeFailed', ...
                'decodeFrameClock raised %s: %s', ME.identifier, ME.message);
            frameStartSamples   = uint64.empty(0, 1);
            frameRateInferredHz = NaN;
        end
    end
end

% Collect TIFF paths and run the aligner.
tiffPathsCell = allTiffs(:)';
for kk = 1:numel(tiffPathsCell)
    if isempty(tiffPathsCell{kk})
        tiffPathsCell{kk} = '';
    else
        tiffPathsCell{kk} = char(tiffPathsCell{kk});
    end
end

alignReport       = struct('fatal', false, 'fatalReason', "");
perTrialAlignment = struct([]);
perFrameTable     = table( ...
    uint64.empty(0, 1), uint64.empty(0, 1), ...
    nan(0, 1), strings(0, 1), ...
    'VariableNames', {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});

if ~isempty(allTrials)
    try
        [perTrialAlignment, perFrameTable, alignReport] = ...
            tfp.io.alignTrialsEpisodic(allTrials, tiffPathsCell, ...
                frameStartSamples, sessionData.sampleRate);
    catch ME
        warning('tfp:experiments:exp_ensemble_activation:alignerFailed', ...
            'alignTrialsEpisodic threw %s: %s', ME.identifier, ME.message);
        alignReport = struct('fatal', true, ...
            'fatalReason', string(sprintf('%s: %s', ME.identifier, ME.message)));
    end

    % Push alignment back onto each trial (only for high/low confidence;
    % quarantine and none are left at the Trial-side defaults).
    if isfield(alignReport, 'fatal') && ~alignReport.fatal ...
            && ~isempty(perTrialAlignment)
        for i = 1:numel(allTrials)
            if i > numel(perTrialAlignment); break; end
            conf = perTrialAlignment(i).alignmentConfidence;
            if (conf == "high" || conf == "low") ...
                    && allTrials(i).status == "complete"
                try
                    allTrials(i).attachEpisodicAlignment( ...
                        perTrialAlignment(i).frame_indices_during_stim, ...
                        perTrialAlignment(i).frame_indices_baseline, ...
                        perTrialAlignment(i).alignmentDiscrepancy, ...
                        perTrialAlignment(i).alignmentConfidence);
                catch ME
                    warning('tfp:experiments:exp_ensemble_activation:attachAlignmentFailed', ...
                        'attachEpisodicAlignment failed for trial %d: %s', ...
                        double(allTrials(i).trialIdx), ME.message);
                end
            end
        end
    end
end

% --- Log ---
if ~isempty(sessionDir) && isfolder(sessionDir)
    tfp.io.sessionLog(sessionDir, 'ensemble-activation-complete', struct( ...
        'nROIs', nROIs, 'powerV', powerV, ...
        'stimDurationS', stimDurationS, 'interStimS', interStimS, ...
        'sampleRate', sampleRate, ...
        'sessionStartDatetime', char(sessionStartDatetime), ...
        'alignFatal', isfield(alignReport, 'fatal') && alignReport.fatal));
    if isfield(alignReport, 'fatal') && alignReport.fatal
        tfp.io.sessionLog(sessionDir, 'ensemble-activation-align-fatal', struct( ...
            'fatalReason', char(alignReport.fatalReason)));
    end
end

% --- Result ---
result.nROIs                    = nROIs;
result.nSequentialTrials        = nROIs;
result.nEnsembleTrials          = 1;
result.nPowerSeriesTrials       = nPowerLevels;
result.powerSeriesVoltages      = seriesVoltages;
result.powerSeriesFractions     = powerFractions;
result.dmdCentroids             = dmdCentroids;
result.stimDurationS            = stimDurationS;
result.interStimS               = interStimS;
result.powerV                   = powerV;
result.sampleRate               = sampleRate;
result.sessionStartDatetime     = sessionStartDatetime;
result.sequentialOnsetSamples   = seqOnsetSamples;
result.sequentialOffsetSamples  = seqOffsetSamples;
result.ensembleOnsetSample      = ensOnsetSample;
result.ensembleOffsetSample     = ensOffsetSample;
result.powerSeriesOnsetSamples  = psOnsetSamples;
result.powerSeriesOffsetSamples = psOffsetSamples;
result.trialIndices             = trialIndices;
result.trials                   = allTrials;
result.tiffPaths                = tiffPathsCell;
result.sessionData              = sessionData;
result.timing.sessionInfo       = sessionInfo;
result.frameStartSamples        = frameStartSamples;
result.frameRateInferredHz      = frameRateInferredHz;
result.alignReport              = alignReport;
result.perTrialAlignment        = perTrialAlignment;
result.perFrame                 = perFrameTable;
result.completedAt              = datetime('now');

fprintf('\n[ensemble_activation] Complete: %d sequential + 1 ensemble + %d power-series trials.\n', ...
    nROIs, nPowerLevels);

if isfield(alignReport, 'fatal') && alignReport.fatal
    fprintf(2, ['\n*** WARNING: episodic alignment FATAL — %s ***\n' ...
                '    Raw data is preserved on disk; re-run the aligner ' ...
                'manually once the root cause is resolved.\n\n'], ...
        char(alignReport.fatalReason));
end
end

% =========================================================================
% Episodic per-trial primitive
% =========================================================================

function [tr, tiffPath] = runEpisodicTrial(daq, siBridge, hasBridge, ...
        trialIdx, conditionLabel, stackIdx, dmdCentroids, activeCellIds, ...
        voltageV, durationS, postStimS, nStimSamples, sampleRate, ...
        sessionStartDatetime, framesPerTrial, syncDOLine, startAcqPulseS, ...
        waitTimeoutS, aoChannel, sessionInfo, extraMeta, powerCurve) %#ok<INUSL>
%runEpisodicTrial Drive one episodic stim trial end-to-end and return a Trial.
%
%   Per SYNC_EPISODIC.md §3:
%     1. armForExternalTrigger(nFrames)
%     2. queueClockedAO  → record onsetSample
%     3. sendDigitalPulse(syncDOLine, startAcqPulseS)  ← the start-acq TTL
%     4. waitForCompletion
%     5. getLastTiffPath
%     6. markComplete(data, offsetSample, tiffPath)

activeCellIds = activeCellIds(:)';

tr            = tfp.trial.Trial();
tr.trialIdx   = trialIdx;
tr.targetSpec = struct( ...
    'condition',  conditionLabel, ...
    'stackIdx',   stackIdx, ...
    'cellIds',    activeCellIds, ...
    'dmdCoords',  dmdCentroids(activeCellIds, :));

% TODO S9 resolution: this experiment stores the requested AO voltage on
% the trial. Convert to milliwatts when a calibration is available so
% downstream analysis sees true power; otherwise fall back to volts.
[powerMw, powerNote] = voltageToPowerMw(voltageV, powerCurve);
tr.powerMw   = powerMw;
tr.duration_s = durationS;
tr.pulseTrain = struct('nPulses', 1, 'interPulse_s', 0, 'pulseWidth_s', durationS);
tr.preStim_s  = 0;
tr.postStim_s = postStimS;
meta = struct( ...
    'aoChannel',    char(aoChannel), ...
    'voltageV',     voltageV, ...
    'powerNote',    powerNote);
if ~isempty(extraMeta) && isstruct(extraMeta)
    f = fieldnames(extraMeta);
    for k = 1:numel(f)
        meta.(f{k}) = extraMeta.(f{k});
    end
end
tr.metadata = meta;

% 1) Arm ScanImage for an external-trigger acquisition of framesPerTrial frames.
if hasBridge
    siBridge.armForExternalTrigger(double(framesPerTrial));
end

% 2) Queue the clocked AO waveform — returns the DAQ sample index of the
%    first AO sample, which is the canonical onset anchor.
waveform           = zeros(nStimSamples + 1, 1);
waveform(1:nStimSamples) = voltageV;
onsetSample = daq.queueClockedAO(waveform, sampleRate, 'immediate');

% 3) Fire the start-acq TTL into ScanImage. This pulse IS the per-trial
%    DO event on syncDOLine; SYNC_EPISODIC.md §4 retired its alignment-
%    anchor role — its only job here is to wake ScanImage's external
%    trigger.
if ~isempty(syncDOLine)
    try
        daq.sendDigitalPulse(char(syncDOLine), startAcqPulseS);
    catch ME
        warning('tfp:experiments:exp_ensemble_activation:startAcqPulseFailed', ...
            'start-acq pulse on %s failed: %s. Trial %d will likely have no TIFF.', ...
            char(syncDOLine), ME.message, double(trialIdx));
    end
end

tr.markRunning(onsetSample, sampleRate, sessionStartDatetime);

% 4) Block until ScanImage finishes writing the TIFF.
if hasBridge
    siBridge.waitForCompletion(waitTimeoutS);
end

% Real elapsed stim time (the queued AO has been streaming since
% queueClockedAO returned).
pause(nStimSamples / sampleRate);

% 5) Compute offset sample from the AO waveform length (anchor at the
%    last stim sample) and pull the deterministic TIFF path.
offsetSample = onsetSample + uint64(nStimSamples) - uint64(1);

tiffPath = '';
if hasBridge
    try
        tiffPath = siBridge.getLastTiffPath();
    catch ME
        warning('tfp:experiments:exp_ensemble_activation:getLastTiffPathFailed', ...
            'getLastTiffPath failed for trial %d (%s): %s', ...
            double(trialIdx), ME.identifier, ME.message);
        tiffPath = '';
    end
end
if isempty(tiffPath); tiffPath = ''; end

% Trial payload — keep light; per-trial AI/DI lives in sessionData.
trialData = struct( ...
    'voltageV',       voltageV, ...
    'aoChannel',      char(aoChannel), ...
    'sessionStartAcq', sessionInfo);

tr.markComplete(trialData, offsetSample, tiffPath);
end

% =========================================================================
% Per-trial persistence
% =========================================================================

function maybeSaveTrial(saveTrials, sessionDir, tr)
%maybeSaveTrial Persist a Trial via tfp.io.saveTrial when enabled.
if ~saveTrials || isempty(sessionDir)
    return
end
if ~isfolder(sessionDir)
    mkdir(sessionDir);
end
tfp.io.saveTrial(tr, sessionDir, struct('saveRawData', false));
end

% =========================================================================
% Coordinate transform
% =========================================================================

function dmdCoords = scanFieldToDMD(scanCoords, calib)
%scanFieldToDMD Apply inverse of dmdToScan_affine to map scan-field -> DMD pixels.
scanToDmd = inv(calib.dmdToScan_affine);
nPts  = size(scanCoords, 1);
pts_h = [scanCoords, ones(nPts, 1)]';   % 3 x N homogeneous
dmd_h = scanToDmd * pts_h;              % 3 x N
dmdCoords = dmd_h(1:2, :)';            % N x 2  [col row]
end

function dmdCoords = clampToDMD(dmdCoords, dmd, scanCoords)
nPts = size(dmdCoords, 1);
for k = 1:nPts
    col = dmdCoords(k, 1);
    row = dmdCoords(k, 2);
    if col < 1 || col > dmd.nCols || row < 1 || row > dmd.nRows
        warning('tfp:experiments:exp_ensemble_activation:roiOutOfBounds', ...
            'ROI %d at scan-field [%.1f %.1f] maps to DMD [%.1f %.1f], outside [1..%d, 1..%d]. Clamping.', ...
            k, scanCoords(k,1), scanCoords(k,2), col, row, dmd.nCols, dmd.nRows);
        dmdCoords(k, 1) = max(1, min(dmd.nCols, col));
        dmdCoords(k, 2) = max(1, min(dmd.nRows, row));
    end
end
end

% =========================================================================
% Live figure
% =========================================================================

function lh = initLiveFigure(nRows, nCols, dmdCentroids)
lh.fig = figure('Name', 'Ensemble Activation — Live DMD Pattern', ...
    'NumberTitle', 'off', 'Color', 'k', ...
    'Position', [80 80 960 640]);
lh.ax = axes(lh.fig, 'Color', 'k', ...
    'Position', [0.02 0.10 0.96 0.83]);

% Pattern image (starts all-black)
lh.img = imagesc(lh.ax, zeros(nRows, nCols));
colormap(lh.ax, gray);
clim(lh.ax, [0 1]);
axis(lh.ax, 'image');
axis(lh.ax, 'off');
hold(lh.ax, 'on');

% All ROI markers (dim gray circles, always visible)
lh.markersAll = plot(lh.ax, dmdCentroids(:,1), dmdCentroids(:,2), ...
    'o', 'Color', [0.35 0.35 0.35], 'MarkerSize', 15, ...
    'LineWidth', 1.5, 'MarkerFaceColor', 'none');

% Active ROI markers (bright red, updated each trial)
lh.markersActive = plot(lh.ax, NaN, NaN, 'ro', ...
    'MarkerSize', 15, 'LineWidth', 2.5, 'MarkerFaceColor', 'none');

lh.titleTxt = title(lh.ax, 'Loading patterns...', ...
    'Color', 'w', 'FontSize', 13, 'FontWeight', 'bold');
drawnow;
end

function updateFigure(lh, pattern, dmdCentroids, activeIdx, titleStr)
if isempty(lh)
    return
end
set(lh.img, 'CData', double(pattern));
if isempty(activeIdx)
    set(lh.markersActive, 'XData', NaN, 'YData', NaN);
else
    set(lh.markersActive, ...
        'XData', dmdCentroids(activeIdx, 1), ...
        'YData', dmdCentroids(activeIdx, 2));
end
set(lh.titleTxt, 'String', titleStr);
drawnow limitrate;
end

% =========================================================================
% Safety / cleanup
% =========================================================================

function safetyOff(daq, aoChannel)
try
    daq.outputSingleAnalog(aoChannel, 0);
catch
end
end

function ensureSessionStopped(daq)
%ensureSessionStopped Best-effort stop of the continuous DAQ session.
%   Used only as an onCleanup fallback for error paths — the normal exit
%   path stops the session explicitly so its return value can be captured.
try
    if daq.isRunning
        daq.stopContinuousSession();
    end
catch
end
end

function ensureBridgeDisconnected(bridge)
%ensureBridgeDisconnected Best-effort disconnect for the ScanImage bridge.
%   Mocks and real bridges both implement disconnect(); we ignore any
%   error here because we're inside an onCleanup tail.
try
    bridge.disconnect();
catch
end
end

% =========================================================================
% Local helpers
% =========================================================================

function v = fractionToVoltage(fraction, powerCurve, maxV)
%fractionToVoltage Convert a fraction of max power to an AO voltage.
%   Uses the measured power curve (output of powerMeterSweep) to invert
%   power → voltage.  Falls back to linear scaling on voltage if no curve.
if isempty(powerCurve) || ~isfield(powerCurve, 'powerMw') ...
        || ~isfield(powerCurve, 'voltageV')
    % No calibration: treat voltage as linear proxy for power.
    v = fraction * maxV;
    return
end
maxPowerMw = max(powerCurve.powerMw);
targetMw   = fraction * maxPowerMw;
[sortedP, idx] = sort(powerCurve.powerMw);
sortedV = powerCurve.voltageV(idx);
v = interp1(sortedP, sortedV, targetMw, 'linear', 'extrap');
v = max(0, min(maxV, v));
end

function [powerMw, note] = voltageToPowerMw(voltageV, powerCurve)
%voltageToPowerMw Convert an AO command voltage to power in mW via the curve.
%   TODO S9 resolution: previously this experiment stored the AO voltage
%   into `Trial.powerMw` directly, conflating units. Now we interpolate
%   along `powerCurve` (if provided); without a curve we fall through to
%   the voltage value but flag the unit via `note`.
if ~isempty(powerCurve) && isfield(powerCurve, 'voltageV') ...
        && isfield(powerCurve, 'powerMw')
    [sortedV, idx] = sort(powerCurve.voltageV);
    sortedP = powerCurve.powerMw(idx);
    powerMw = interp1(sortedV, sortedP, voltageV, 'linear', 'extrap');
    powerMw = max(0, double(powerMw));
    note    = 'calibrated_mW';
else
    powerMw = double(voltageV);
    note    = 'uncalibrated_AO_volts';
end
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
