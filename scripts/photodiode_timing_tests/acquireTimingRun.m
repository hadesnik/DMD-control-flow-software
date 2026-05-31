function raw = acquireTimingRun(cfg, dmd, daq, commandedRateHz)
%acquireTimingRun Run ONE DMD switching-timing capture at a single commanded rate.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure.
%
%   raw = acquireTimingRun(cfg, dmd, daq, commandedRateHz)
%
%   This function performs a single hardware-clocked acquisition at one
%   commanded pattern-advance rate and returns a rawCapture struct that is
%   schema-identical to the one produced by synthTimingTrace (so the same
%   analyzeTimingTrace routine consumes either).  A full rate sweep is built
%   by calling this once per rate in cfg.sweep.ratesHz.
%
%   ---------------------------------------------------------------------
%   HARDWARE-INTEGRATION SHIM  (read this — it is the reason this file is
%   structured the way it is)
%   ---------------------------------------------------------------------
%   Repo rule: "no code outside +hardware/ ever touches hardware-specific
%   APIs directly."  The timing toolset honours that rule by funnelling ALL
%   of its hardware interaction through this ONE function.  Every other file
%   in scripts/photodiode_timing_tests/ is pure computation (pattern building, synthetic
%   trace generation, analysis, plotting) and never touches a DMD or DAQ
%   object.  acquireTimingRun is the toolset's single hardware-integration
%   shim: it speaks only to the *abstract* tfp.hardware.DMD and
%   tfp.hardware.DAQ interfaces (loadPatternSequence / armSequence /
%   softTrigger and the continuous-session API), never to a concrete backend
%   (no ALP_* calls, no DAQmx calls).  Backend selection — Mock* vs. real —
%   is the caller's responsibility: it constructs and initialises the dmd
%   and daq objects and hands them in here already live.
%
%   ---------------------------------------------------------------------
%   ACQUISITION MODEL
%   ---------------------------------------------------------------------
%   Two trigger topologies are supported, selected by cfg.trigger.mode:
%
%     'external' (DAQ is timing master, DMD is slave):
%         The DAQ generates the pattern-advance triggers as a hardware-
%         clocked analog-output (AO) square wave on cfg.channels.trigAO.
%         That AO line is physically looped back into the digital-input (DI)
%         line cfg.channels.trigDI so the recorded trigger train is captured
%         on the same sample clock as the APD.  The DMD is loaded in
%         external/slave trigger mode and free-advances on each AO rising
%         edge.  The APD (behind the pinhole, see makeTimingPatterns) is
%         sampled on the analog-input line cfg.channels.apdAI.
%
%     'internal' (DMD is timing master, pacer free-runs):
%         The DMD is loaded in internal trigger mode with a per-frame
%         exposure chosen so the frame period equals 1/commandedRateHz.  The
%         DAQ generates NO AO; it records the APD on cfg.channels.apdAI and
%         the controller's frame-sync OUTPUT on cfg.channels.trigDI.  (For
%         the DLPC410/ALP backend that sync is a controller output line; on
%         the mock it is the synthetic frame clock on the DI line.)
%
%   In BOTH modes the returned rawCapture has .apd (APD voltage) and .trig
%   (recorded trigger / sync line, thresholded to 0/1) on a common clock.
%
%   ---------------------------------------------------------------------
%   MOCK vs REAL behaviour (branch on cfg.hardwareKind / cfg.useSynthSignal)
%   ---------------------------------------------------------------------
%   (1) MOCK + useSynth  (the dev-Mac path, the default):
%       Exercises the REAL call sequence against the Mock* objects so the
%       plumbing (pattern load -> arm -> trigger -> session start -> AO
%       queue -> session stop) is validated, then DISCARDS the mock data
%       (MockDAQ returns noise + a synthetic frame clock; it does NOT model
%       the APD) and OVERLAYS a physically meaningful synthetic trace from
%       synthTimingTrace.  The whole plumbing pass is wrapped in try/catch:
%       if any mock call throws, a note is recorded but the synth trace is
%       still returned, so the dev path NEVER throws for a valid cfg.
%
%   (2) MOCK + ~useSynth:
%       Same plumbing, but returns the mock DAQ data mapped into the
%       rawCapture schema (apd = noise, trig = thresholded synthetic frame
%       clock).  Analysis on this is meaningless; this path exists only to
%       exercise the mock noise/return path.  raw.truth = [].
%
%   (3) REAL:
%       Genuine acquisition.  Loads patterns, arms, starts the continuous
%       session, (external mode) queues the AO trigger waveform, polls
%       currentSampleIndex until enough samples are captured (or a timeout),
%       stops the session, and maps the captured AI/DI columns into the
%       rawCapture schema.  raw.truth = [] (no ground truth on real data).
%
%   Inputs
%   ------
%   cfg : struct
%       Timing config (see scripts/photodiode_timing_tests/defaultTimingConfig.m).  Fields
%       read here:
%         cfg.hardwareKind        'mock' | 'real'.
%         cfg.useSynthSignal      logical; overlay synth trace in mock path.
%         cfg.sampleRateHz        DAQ sample rate (Hz).
%         cfg.aiRangeV            [lo hi] analog-input range (V).
%         cfg.channels.apdAI      APD analog-input channel number.
%         cfg.channels.trigDI     trigger/sync digital-input line name.
%         cfg.channels.trigAO     trigger analog-output channel (external).
%         cfg.trigger.mode        'external' | 'internal'.
%         cfg.trigger.highV       AO trigger high level (V, external mode).
%         cfg.trigger.lowV        AO trigger low  level (V, external mode).
%         cfg.trigger.pulseWidthFrac  high fraction of each AO period.
%         cfg.sweep.transitionsPerRate  number of commanded toggles.
%         cfg.pattern.*           pattern spec for makeTimingPatterns, plus
%                                 optional cfg.pattern.stack (cached HxWx2).
%         cfg.dmd.darkTimeUs      DMD dark time between frames (us).
%
%   dmd : tfp.hardware.DMD subclass, already constructed AND initialized.
%   daq : tfp.hardware.DAQ subclass, already constructed AND initialized.
%   commandedRateHz : scalar double > 0, the pattern-advance rate for this run.
%
%   Output
%   ------
%   raw : struct (a rawCapture), schema-identical to synthTimingTrace:
%       .sampleRateHz    scalar.
%       .t               (N x 1) double, (0:N-1)'/sampleRateHz.
%       .apd             (N x 1) double, APD voltage (V).
%       .trig            (N x 1) double in {0,1}, recorded trigger/sync line.
%       .commandedRateHz scalar.
%       .nCommanded      scalar = nTransitions.
%       .meta            provenance struct.
%       .truth           ground-truth struct (mock+synth) or [] otherwise.
%
%   Errors (identifier format: tfp:timing:acquireTimingRun:<reason>)
%   ------
%   tfp:timing:acquireTimingRun:badCfg
%       cfg is not a scalar struct, or a required cfg field is missing.
%   tfp:timing:acquireTimingRun:badDmd
%       dmd is empty or not a tfp.hardware.DMD.
%   tfp:timing:acquireTimingRun:badDaq
%       daq is empty or not a tfp.hardware.DAQ.
%   tfp:timing:acquireTimingRun:badRate
%       commandedRateHz is not a positive finite scalar.
%   tfp:timing:acquireTimingRun:badTriggerMode
%       cfg.trigger.mode is not 'external' or 'internal'.
%   tfp:timing:acquireTimingRun:acquisitionTimeout
%       (real path) the DAQ never reached the required sample count.
%
%   Example
%   -------
%   cfg = defaultTimingConfig();                 % mock + synth by default
%   dmd = tfp.hardware.MockDMD();  dmd.initialize(struct());
%   daq = tfp.hardware.MockDAQ();  daq.initialize(struct( ...
%       'analogInChannels', cfg.channels.apdAI, ...
%       'analogOutChannels', cfg.channels.trigAO, ...
%       'digitalInChannels', {{cfg.channels.trigDI}}));
%   raw = acquireTimingRun(cfg, dmd, daq, 1000);
%
%   See also synthTimingTrace, makeTimingPatterns, analyzeTimingTrace,
%            defaultTimingConfig, scripts/photodiode_timing_tests/README.md

% =========================================================================
% 0.  Validate inputs
% =========================================================================
if ~isstruct(cfg) || ~isscalar(cfg)
    error('tfp:timing:acquireTimingRun:badCfg', ...
        'cfg must be a scalar struct; got %s.', class(cfg));
end

% Required cfg fields (top-level + the nested groups we dereference).
requireField(cfg, 'hardwareKind');
requireField(cfg, 'useSynthSignal');
requireField(cfg, 'sampleRateHz');
requireField(cfg, 'aiRangeV');
requireField(cfg, 'channels');
requireField(cfg, 'trigger');
requireField(cfg, 'sweep');
requireField(cfg, 'pattern');
requireField(cfg, 'dmd');
requireField(cfg.channels, 'apdAI', 'channels');
requireField(cfg.channels, 'trigDI', 'channels');
requireField(cfg.channels, 'trigAO', 'channels');
requireField(cfg.trigger, 'mode', 'trigger');
requireField(cfg.trigger, 'highV', 'trigger');
requireField(cfg.trigger, 'lowV', 'trigger');
requireField(cfg.trigger, 'pulseWidthFrac', 'trigger');
requireField(cfg.sweep, 'transitionsPerRate', 'sweep');
requireField(cfg.dmd, 'darkTimeUs', 'dmd');

if isempty(dmd) || ~isa(dmd, 'tfp.hardware.DMD')
    error('tfp:timing:acquireTimingRun:badDmd', ...
        'dmd must be a non-empty tfp.hardware.DMD subclass; got %s.', class(dmd));
end
if isempty(daq) || ~isa(daq, 'tfp.hardware.DAQ')
    error('tfp:timing:acquireTimingRun:badDaq', ...
        'daq must be a non-empty tfp.hardware.DAQ subclass; got %s.', class(daq));
end
if ~isnumeric(commandedRateHz) || ~isscalar(commandedRateHz) || ...
        ~isfinite(commandedRateHz) || commandedRateHz <= 0
    error('tfp:timing:acquireTimingRun:badRate', ...
        'commandedRateHz must be a positive finite scalar; got %s.', ...
        mat2str(commandedRateHz));
end

% =========================================================================
% 1.  Unpack the parameters we use repeatedly
% =========================================================================
sampleRateHz = double(cfg.sampleRateHz);
nTransitions = double(cfg.sweep.transitionsPerRate);
trigMode     = char(cfg.trigger.mode);

if ~any(strcmp(trigMode, {'external', 'internal'}))
    error('tfp:timing:acquireTimingRun:badTriggerMode', ...
        'cfg.trigger.mode must be ''external'' or ''internal''; got ''%s''.', trigMode);
end

isMock   = strcmpi(cfg.hardwareKind, 'mock');
useSynth = logical(cfg.useSynthSignal);

% =========================================================================
% 2.  Obtain the 2-pattern logical stack (HxWx2)
% =========================================================================
% Prefer a cached stack on cfg.pattern.stack (the sweep driver fills this
% once so every rate point reuses it); otherwise build it from the geometry.
if isfield(cfg.pattern, 'stack') && ~isempty(cfg.pattern.stack)
    patterns = logical(cfg.pattern.stack);
else
    [patterns, ~] = makeTimingPatterns(dmd, cfg);
end

% =========================================================================
% 3.  Per-mode exposure (us) for the DMD frame
% =========================================================================
% In external/slave mode the ALP "exposure" (illuminate) time is the MINIMUM
% display time per frame; the external edge governs the actual advance, so we
% set it to fit comfortably inside one commanded period, minus the dark time.
% In internal-pacer mode the exposure (+ dark time) IS the frame period, so we
% solve exposure = framePeriod - darkTime.
darkTimeUs    = double(cfg.dmd.darkTimeUs);
framePeriodUs = 1e6 / commandedRateHz;
if strcmp(trigMode, 'external')
    expUsForRate = max(1, floor(framePeriodUs) - darkTimeUs);
else  % internal
    expUsForRate = max(1, round(framePeriodUs - darkTimeUs));
end

% =========================================================================
% 4.  Dispatch on the three paths
% =========================================================================
switch true

    % ---------------------------------------------------------------------
    case isMock && useSynth
    % ---------------------------------------------------------------------
    % (1) MOCK + useSynth — the dev-Mac path.
    %     Exercise the real call sequence on the mocks (plumbing validation),
    %     discard the (meaningless) mock data, then overlay a synthetic trace.
    %     MUST NEVER throw for a valid cfg: the plumbing is wrapped so a mock
    %     error becomes a note rather than a failure.
        plumbingNote = '';
        try
            runPlumbing(dmd, daq, patterns, expUsForRate, darkTimeUs, ...
                trigMode, cfg, commandedRateHz, sampleRateHz, nTransitions);
            % Capture (and discard) the mock data so MockDAQ's log is fully
            % populated and the session is cleanly closed.
            daq.stopContinuousSession();
        catch ME
            plumbingNote = sprintf('mock plumbing pass raised %s: %s', ...
                ME.identifier, ME.message);
            % Make a best effort to leave the DAQ session closed so a later
            % run does not hit "alreadyRunning".
            try
                if daq.isRunning
                    daq.stopContinuousSession();
                end
            catch
                % swallow — dev path stays robust no matter what
            end
        end

        % Overlay the physically meaningful synthetic trace.  This is the
        % data the analysis pipeline actually consumes on the dev machine.
        raw = synthTimingTrace(cfg, commandedRateHz, nTransitions);
        raw.meta.hardwareKind = 'mock';
        if ~isempty(plumbingNote)
            raw.meta.plumbingNote = plumbingNote;
        end

    % ---------------------------------------------------------------------
    case isMock && ~useSynth
    % ---------------------------------------------------------------------
    % (2) MOCK + ~useSynth — exercise the mock noise/return path.
    %     Returns the mock DAQ data mapped into the rawCapture schema; the
    %     analysis on this is meaningless (APD is just noise) and truth = [].
        runPlumbing(dmd, daq, patterns, expUsForRate, darkTimeUs, ...
            trigMode, cfg, commandedRateHz, sampleRateHz, nTransitions);
        res = daq.stopContinuousSession();
        [apd, trig] = mapDaqResult(res, cfg.channels.apdAI, cfg.channels.trigDI);
        raw = assembleRaw(apd, trig, sampleRateHz, commandedRateHz, ...
            nTransitions, cfg, trigMode, []);

    % ---------------------------------------------------------------------
    otherwise   % REAL hardware (cfg.hardwareKind == 'real')
    % ---------------------------------------------------------------------
    % (3) REAL — genuine acquisition.  This branch CANNOT be exercised on the
    %     dev Mac (no DLL); the %VERIFY comments below flag the ordering and
    %     column-mapping assumptions that must be confirmed on the scope PC.
        if strcmp(trigMode, 'external')
            % ---- EXTERNAL: DAQ master, DMD slave ----
            % %VERIFY (scope PC): ALP slave-trigger ordering. We load patterns
            % in external/slave mode, arm, then softTrigger to START projection
            % so the device is ready to advance on each incoming AO edge. The
            % external edges from the AO line then drive the actual frame
            % advances. Confirm on hardware that softTrigger in SLAVE mode
            % merely enables/starts (does not itself advance) and that the
            % first AO rising edge produces the first optical toggle.
            dmd.loadPatternSequence(patterns, struct( ...
                'exposureUs', expUsForRate, ...
                'darkTimeUs', darkTimeUs, ...
                'triggerMode', 'external'));
            dmd.armSequence();
            dmd.softTrigger();

            % Build the hardware-clocked AO trigger square wave.
            aoWave = buildAoTriggerWave(sampleRateHz, commandedRateHz, ...
                nTransitions, cfg.trigger.pulseWidthFrac, ...
                cfg.trigger.highV, cfg.trigger.lowV);

            % Start the single clocked session: APD on AI, trigger looped back
            % on DI, AO on the trigger channel.
            sessCfg = buildSessCfg(sampleRateHz, cfg.channels.apdAI, ...
                cfg.aiRangeV, cfg.channels.trigAO, cfg.channels.trigDI);
            daq.startContinuousSession(sessCfg);
            daq.queueClockedAO(aoWave, sampleRateHz, 'immediate');

            % Poll until the AO waveform has been clocked out (plus its tail),
            % or a generous timeout elapses.
            nNeeded = numel(aoWave);
            timeout = 3 * nNeeded / sampleRateHz + 1;
            pollUntil(daq, nNeeded, timeout, commandedRateHz);

            res = daq.stopContinuousSession();
            % %VERIFY (scope PC): AI+DI-on-one-clock column ordering. aiData
            % columns are ordered as cfg.aiChannels (here a single channel),
            % diData columns as cfg.diLines (here a single line). We map by
            % position / by matching the line name in res.lineNames.diLines.
            apd  = res.aiData(:, 1);
            trig = pickDiColumn(res, cfg.channels.trigDI);

        else
            % ---- INTERNAL: DMD master (free-running pacer) ----
            % %VERIFY (scope PC): in internal/master mode the controller drives
            % its frame-sync OUTPUT into trigDI; softTrigger starts the free run.
            % Confirm the sync polarity / one-pulse-per-frame mapping.
            dmd.loadPatternSequence(patterns, struct( ...
                'exposureUs', expUsForRate, ...
                'darkTimeUs', darkTimeUs, ...
                'triggerMode', 'internal'));
            dmd.armSequence();
            dmd.softTrigger();   % device free-runs

            % No AO: record APD on AI and the device sync on DI only.
            sessCfg = buildSessCfg(sampleRateHz, cfg.channels.apdAI, ...
                cfg.aiRangeV, [], cfg.channels.trigDI);
            daq.startContinuousSession(sessCfg);

            % Enough samples to span all transitions at the commanded rate,
            % plus a couple of periods of guard.
            samplesPerPeriod = round(sampleRateHz / commandedRateHz);
            nNeeded = round(nTransitions / commandedRateHz * sampleRateHz) ...
                + 2 * samplesPerPeriod;
            timeout = 3 * nNeeded / sampleRateHz + 1;
            pollUntil(daq, nNeeded, timeout, commandedRateHz);

            res  = daq.stopContinuousSession();
            apd  = res.aiData(:, 1);
            trig = pickDiColumn(res, cfg.channels.trigDI);
        end

        raw = assembleRaw(apd, trig, sampleRateHz, commandedRateHz, ...
            nTransitions, cfg, trigMode, []);
end

end % acquireTimingRun


% =========================================================================
% Local helper — run the (mock or real) DMD+DAQ call sequence "plumbing"
% =========================================================================
function runPlumbing(dmd, daq, patterns, expUsForRate, darkTimeUs, ...
        trigMode, cfg, commandedRateHz, sampleRateHz, nTransitions)
%runPlumbing Execute the load->arm->trigger->session-start->(AO)->wait sequence.
%   Used by the mock paths to validate that the abstract call sequence is
%   accepted by whatever backend was handed in. Does NOT stop the session;
%   the caller stops it (and decides whether to keep or discard the data).

% Load + arm + (soft) start the DMD in the requested trigger mode.
dmd.loadPatternSequence(patterns, struct( ...
    'exposureUs',  expUsForRate, ...
    'darkTimeUs',  darkTimeUs, ...
    'triggerMode', trigMode));
dmd.armSequence();
dmd.softTrigger();

if strcmp(trigMode, 'external')
    % Build and queue the AO trigger waveform on the same clock as the AI/DI.
    aoWave  = buildAoTriggerWave(sampleRateHz, commandedRateHz, ...
        nTransitions, cfg.trigger.pulseWidthFrac, ...
        cfg.trigger.highV, cfg.trigger.lowV);
    sessCfg = buildSessCfg(sampleRateHz, cfg.channels.apdAI, ...
        cfg.aiRangeV, cfg.channels.trigAO, cfg.channels.trigDI);
    daq.startContinuousSession(sessCfg);
    daq.queueClockedAO(aoWave, sampleRateHz, 'immediate');
else
    % Internal pacer: no AO channel, no AO queue.
    sessCfg = buildSessCfg(sampleRateHz, cfg.channels.apdAI, ...
        cfg.aiRangeV, [], cfg.channels.trigDI);
    daq.startContinuousSession(sessCfg);
end

% Deliberately do NOT pause/poll in a loop for real wall-clock time here:
% on the mock there is nothing to wait for, and the dev path must stay fast
% and deterministic. The caller immediately stops the session to capture the
% (discarded) mock data and finish populating the log.

end % runPlumbing


% =========================================================================
% Local helper — build the AO trigger square wave (external mode)
% =========================================================================
function aoWave = buildAoTriggerWave(sampleRateHz, commandedRateHz, ...
        nTransitions, pulseWidthFrac, highV, lowV)
%buildAoTriggerWave Construct the hardware-clocked AO pattern-advance waveform.
%   One period = highN samples at highV then (sPer-highN) samples at lowV;
%   repeated nTransitions times, with a low tail of ~2 periods appended so
%   the final commanded edge has room to complete optically. Column vector.

sPer  = round(sampleRateHz / commandedRateHz);          % samples per period
sPer  = max(1, sPer);
highN = max(1, round(pulseWidthFrac * sPer));           % high-phase length
highN = min(highN, sPer);                               % clamp into [1, sPer]

onePeriod = [highV * ones(highN, 1); lowV * ones(sPer - highN, 1)];
aoWave    = repmat(onePeriod, nTransitions, 1);

tailN  = round(2 * sPer);
aoWave = [aoWave; lowV * ones(tailN, 1)];

aoWave = aoWave(:);   % guarantee column vector

end % buildAoTriggerWave


% =========================================================================
% Local helper — build the continuous-session cfg struct
% =========================================================================
function sessCfg = buildSessCfg(sampleRateHz, apdAI, aiRangeV, aoCh, trigDI)
%buildSessCfg Assemble the struct for daq.startContinuousSession.
%   aoCh = trigAO channel (external mode) or [] (internal mode). The
%   cell-valued fields use the struct(...,'field',{{...}}) idiom so each
%   holds a 1x1 cell (a 1x1 struct array), NOT a struct array per element.

sessCfg = struct( ...
    'sampleRate',     sampleRateHz, ...
    'aiChannels',     apdAI, ...
    'aiRangeV',       aiRangeV, ...
    'aoChannels',     aoCh, ...
    'diLines',        {{char(trigDI)}}, ...
    'doLines',        {{}}, ...
    'frameClockLine', '');

end % buildSessCfg


% =========================================================================
% Local helper — poll currentSampleIndex until enough samples or timeout
% =========================================================================
function pollUntil(daq, nNeeded, timeout, commandedRateHz)
%pollUntil Block (lightly) until the DAQ has clocked >= nNeeded samples.
%   Throws tfp:timing:acquireTimingRun:acquisitionTimeout if the count is
%   not reached within `timeout` seconds. Used on the real path only.

t0 = tic;
while double(daq.currentSampleIndex()) < nNeeded && toc(t0) < timeout
    pause(0.005);
end
if double(daq.currentSampleIndex()) < nNeeded
    error('tfp:timing:acquireTimingRun:acquisitionTimeout', ...
        ['DAQ reached only %g of %g required samples within %.2f s at ' ...
         'commandedRateHz=%g Hz. Check trigger wiring / AO loopback.'], ...
        double(daq.currentSampleIndex()), nNeeded, timeout, commandedRateHz);
end

end % pollUntil


% =========================================================================
% Local helper — map a stopContinuousSession result into apd + trig
% =========================================================================
function [apd, trig] = mapDaqResult(res, apdAI, trigDI)
%mapDaqResult Extract the APD column and the trigger DI column.
%   apd  : the aiData column corresponding to apdAI (column 1 — the single
%          AI channel we requested).
%   trig : the diData column for trigDI, thresholded to 0/1.

if isempty(res.aiData)
    apd = zeros(0, 1);
else
    apd = res.aiData(:, 1);
end
trig = pickDiColumn(res, trigDI);

end % mapDaqResult


% =========================================================================
% Local helper — pick a DI column by line name, thresholded to 0/1
% =========================================================================
function trig = pickDiColumn(res, trigDI)
%pickDiColumn Return the diData column for trigDI as a 0/1 double column.
%   Locates the column by matching trigDI against res.lineNames.diLines.

nRows = size(res.diData, 1);
col   = [];
if isfield(res, 'lineNames') && isfield(res.lineNames, 'diLines') ...
        && ~isempty(res.lineNames.diLines)
    col = find(strcmp(char(trigDI), res.lineNames.diLines), 1);
end
if isempty(col)
    % Fall back to the first DI column if the name match failed (single-line
    % case); if there is no DI data at all, return zeros of the right length.
    if size(res.diData, 2) >= 1
        col = 1;
    end
end

if isempty(col)
    trig = zeros(nRows, 1);
else
    trig = double(res.diData(:, col) ~= 0);   % strict 0/1
end
trig = trig(:);

end % pickDiColumn


% =========================================================================
% Local helper — assemble the rawCapture struct (schema matches synth)
% =========================================================================
function raw = assembleRaw(apd, trig, sampleRateHz, commandedRateHz, ...
        nTransitions, cfg, trigMode, truth)
%assembleRaw Build the rawCapture struct shared with synthTimingTrace.
%   apd and trig are forced to equal-length column doubles; t is derived
%   from their common length and the sample rate.

apd  = double(apd(:));
trig = double(trig(:));

% Reconcile lengths defensively (real DAQ should return equal-length AI/DI,
% but be robust to off-by-one between the AI and DI capture buffers).
N = min(numel(apd), numel(trig));
if isempty(apd);  N = numel(trig); end
if isempty(trig); N = numel(apd);  end
apd  = fitLength(apd,  N);
trig = fitLength(trig, N);

t = (0:N-1)' / sampleRateHz;

raw = struct();
raw.sampleRateHz    = sampleRateHz;
raw.t               = t;
raw.apd             = apd;
raw.trig            = trig;
raw.commandedRateHz = commandedRateHz;
raw.nCommanded      = nTransitions;

raw.meta = struct( ...
    'device',          'DMD', ...
    'triggerMode',     trigMode, ...
    'hardwareKind',    cfg.hardwareKind, ...
    'channels',        cfg.channels, ...
    'sampleRateHz',    sampleRateHz, ...
    'commandedRateHz', commandedRateHz, ...
    'datetime',        datetime('now'));

raw.truth = truth;

end % assembleRaw


% =========================================================================
% Local helper — pad/trim a column vector to exactly N samples
% =========================================================================
function v = fitLength(v, N)
%fitLength Force column vector v to length N (trim or zero-pad at the end).
v = v(:);
if numel(v) >= N
    v = v(1:N);
else
    v = [v; zeros(N - numel(v), 1)];
end
end % fitLength


% =========================================================================
% Local helper — require a (possibly nested) cfg field to be present
% =========================================================================
function requireField(s, name, parentName)
%requireField Throw tfp:timing:acquireTimingRun:badCfg if field is absent.
%   parentName (optional) names the parent struct for a clearer message.
if nargin < 3
    parentName = 'cfg';
else
    parentName = ['cfg.' parentName];
end
if ~isfield(s, name)
    error('tfp:timing:acquireTimingRun:badCfg', ...
        'Required field %s.%s is missing.', parentName, name);
end
end % requireField
