classdef Sequencer < handle
    %Sequencer State machine that runs a TrialSequence end-to-end.
    %
    %   T-EP-3c (Round 3 convergence) rewrites the Sequencer to use the
    %   continuous, hardware-clocked DAQ session + episodic ScanImage
    %   acquisition model documented in docs/SYNC_FRAME.md §4 and the
    %   ensemble experiments (exp_ensemble_activation,
    %   exp_ensemble_fill_factor_power).
    %
    %   Per-trial flow inside runOne:
    %     1. (Safety check + optional PLM defocus load.)
    %     2. Load + arm the DMD pattern sequence.
    %     3. DMD softTrigger BEFORE any DAQ AO activity (resolves S1 —
    %        the prior implementation ran daq.start() first).
    %     4. Arm ScanImage for the episodic capture (armForExternalTrigger
    %        + setActivePattern; nFrames is derived from
    %        config.imaging.frameRate, resolving S2 — the prior
    %        implementation hardcoded 30 Hz).
    %     5. Fire the start-acquisition TTL on the configured DO line
    %        via daq.sendDigitalPulse (resolves C1).
    %     6. Queue the stim AO via daq.queueClockedAO against the running
    %        continuous session; record the returned onset sample index.
    %     7. Block on siBridge.waitForCompletion.
    %     8. Retrieve the per-trial TIFF path via getLastTiffPath; the
    %        mock returns a .mat sidecar path (see SYNC_EPISODIC.md §9.7)
    %        and the real bridge returns the on-disk TIFF path. The
    %        synthetic ΔF/F struct (mock only) is fetched in parallel
    %        via getSyntheticResult(); the real bridge returns [] from
    %        that method, so no per-class isa check is required
    %        (resolves S3).
    %     9. Compute offset_sample = onset_sample + nStimSamples - 1.
    %    10. trial.markRunning(onset, sampleRate, sessionStartDatetime)
    %        and trial.markComplete(data, offsetSample, siTiffPath)
    %        (3-arg form populates the public Trial.siTiffPath property
    %        — see SYNC_EPISODIC.md §6).
    %
    %   Session-level flow inside run():
    %     a. siBridge.beginSession(struct()) — snapshot the ScanImage
    %        acquisition-counter / log-file-stem so per-trial TIFF paths
    %        are deterministic (see SYNC_EPISODIC.md §9.2). Called once,
    %        before the trial loop.
    %     b. startContinuousSession(sessionCfg), where
    %        sessionCfg.diLines includes frameClockLine so the frame
    %        clock is captured for the whole session (resolves C4 — the
    %        prior implementation called readDigitalInput without ever
    %        configuring the DI line).
    %     c. For each trial: runOne(trial).
    %     d. stopContinuousSession() to recover aiData + diData.
    %     e. tfp.io.decodeFrameClock on the frame-clock column of diData,
    %        then tfp.io.alignTrialsEpisodic + Trial.attachEpisodicAlignment
    %        to bind per-trial frame-index windows (see SYNC_EPISODIC.md §7).
    %     e. Per-trial AI slices are then extracted from sessionData and
    %        the trial.data struct is finalised, after which tfp.io.saveTrial
    %        writes both _meta and _raw files. Failed trials are still
    %        saved immediately on the error path.
    %
    %   TODO items resolved by this rewrite:
    %     C1 (start-acq TTL)              — daq.sendDigitalPulse(startAcqLine, ...)
    %     C3 (unify execution paths)      — Sequencer now uses the same
    %                                       continuous-DAQ + episodic-SI
    %                                       model as the ensemble experiments
    %     C4 (frame-clock DI config)      — frameClockLine in sessionCfg.diLines
    %     S1 (trigger ordering)           — dmd.softTrigger before DAQ AO queue
    %     S2 (hardcoded 30 Hz nFrames)    — uses config.imaging.frameRate
    %     S3 (isa MockScanImageBridge)    — removed; polymorphic getSyntheticResult
    %
    %   TODO items deferred to later streams:
    %     C2 (powerLUT plumbing)          — T-EP-3d will translate
    %                                       trial.powerMw → volts via
    %                                       tfp.patterns.powerLUT before
    %                                       queueing. For now the stim
    %                                       waveform is a constant
    %                                       trial.powerMw-volt block.
    %     C5 (full safetyChecks impl)     — tfp.util.safetyChecks('check')
    %                                       remains a placeholder hook
    %                                       (not implemented here).
    %
    %   New/changed config fields (defaults shown):
    %     config.daq.startAcqLine       — DO line to trigger ScanImage
    %                                     (default 'port0/line10').
    %     config.daq.startAcqPulseS     — start-acq pulse width
    %                                     (default 0.005, i.e. 5 ms).
    %     config.daq.frameClockLine     — DI line carrying SI's frame
    %                                     clock (default 'port0/line2').
    %     config.imaging.frameRate      — ScanImage frame rate
    %                                     (default 30, Hz).
    %
    %   The Sequencer is robust to missing keys — every config lookup
    %   uses the documented default — and to a DAQ that lacks one of
    %   the configured DI/DO lines (the line is dropped from sessionCfg
    %   with a warning rather than aborting the session).
    %
    %   See docs/SYNC_FRAME.md and the ensemble experiments for the
    %   reference per-trial flow this Sequencer mirrors.

    properties
        dmd
        daq
        siBridge
        plm              % optional PLM for per-trial defocus (axial PPSF)
        slm              % optional sequence-capable modulator (3D mode):
                         % prepared + armed by the experiment; the Sequencer
                         % advances it on depth-group changes (dedupe +
                         % settle live in advanceToIndex)
        sequence
        log              % path to session directory
        sessionStartTime % datetime set at the top of run()
        config_struct    % full user config (read by configField on demand)
    end

    properties (Access = private)
        nStreamCells_  % ROI count passed to siBridge.armStreaming(); 0 = streaming disabled
        saveRawData_   % logical: write trial_NNNN_raw.mat per trial (default true)

        % Continuous-session state captured during run().
        sessionInfo_       % struct with sessionStartDatetime, sampleRate
        sessionCfg_        % struct passed to startContinuousSession
        startAcqLine_      % DO line pulsed at the top of each trial
        startAcqPulseS_    % start-acq pulse width (s)
        frameClockLine_    % DI line carrying the SI frame clock
        sampleRate_        % DAQ sample rate (Hz) for the session
        frameRate_         % ScanImage frame rate (Hz) — drives nFrames
        aoChannelIdx_      % AO channel index used by queueClockedAO
        haveStartAcqLine_  % logical — true iff startAcqLine_ is configured on the DAQ
        runtimeStash_      % cell array of per-trial scratch structs (aligned by index)

        % 3D mode state
        threeD_            % logical: config.threeD.enabled
        nPlanes_           % config.etl.n_planes (free-run volume shape)
        paceTrials_        % logical: real-time pause per trial in free-run mode
        currentSlmGroup_   % last SLM group advanced to (0 = none)
        gradientSign_      % config.threeD.depth_gradient_sign
    end

    methods
        function obj = Sequencer(dmd, daq, sequence, sessionDir, opts)
            if nargin < 5 || isempty(opts)
                opts = struct();
            end
            obj.dmd      = dmd;
            obj.daq      = daq;
            obj.sequence = sequence;
            obj.log      = char(sessionDir);
            if isfield(opts, 'siBridge')
                obj.siBridge = opts.siBridge;
            else
                obj.siBridge = [];
            end
            if isfield(opts, 'plm')
                obj.plm = opts.plm;
            else
                obj.plm = [];
            end
            if isfield(opts, 'slm')
                obj.slm = opts.slm;
            else
                obj.slm = [];
            end
            obj.currentSlmGroup_ = 0;
            if isfield(opts, 'nStreamCells')
                obj.nStreamCells_ = opts.nStreamCells;
            else
                obj.nStreamCells_ = 0;
            end
            if isfield(opts, 'saveRawData')
                obj.saveRawData_ = logical(opts.saveRawData);
            else
                obj.saveRawData_ = true;
            end
            % User config passed straight through if provided; otherwise
            % an empty struct so configField() always finds defaults.
            if isfield(opts, 'config') && isstruct(opts.config)
                obj.config_struct = opts.config;
            else
                obj.config_struct = struct();
            end

            obj.runtimeStash_ = {};
        end

        function result = run(obj)
            %run Execute the trial loop against a continuous DAQ session.
            %
            %   Opens a single hardware-clocked DAQ session that spans the
            %   whole run, drives ScanImage episodically per trial, then
            %   recovers aiData + diData on session close and binds the
            %   per-trial frame alignment via tfp.io.alignTrialsEpisodic
            %   (see SYNC_EPISODIC.md §7).
            %
            %   Returns a struct with fields:
            %     .sessionInfo            struct (sessionStartDatetime,
            %                              sampleRate) plus the bridge's
            %                              beginSession() snapshot when a
            %                              bridge is wired up
            %     .sessionData            result of stopContinuousSession()
            %     .frameStartSamples      1xK uint64 — decoded SI frame edges
            %     .frameRateInferredHz    scalar — median-of-intervals
            %                              inference (NaN when <2 edges)
            %     .perFrame               table — frame->trial assignment
            %                              (output of alignTrialsEpisodic)
            %     .perTrialAlignment      1xN struct — per-trial diagnostic
            %                              rows (output of alignTrialsEpisodic)
            %     .alignReport            struct — session-level diagnostic
            %                              report from alignTrialsEpisodic
            obj.sessionStartTime = datetime('now');
            tfp.io.sessionLog(obj.log, 'run-start', ...
                struct('nTrials', numel(obj.sequence.trials)));

            % --- Resolve config (defaults document the new wire-up) ---
            cfg = obj.config_struct;
            obj.sampleRate_      = double(configField(cfg, 'daq.sampleRate',     obj.fallbackSampleRate()));
            obj.startAcqLine_    = char  (configField(cfg, 'daq.startAcqLine',   'port0/line10'));
            obj.startAcqPulseS_  = double(configField(cfg, 'daq.startAcqPulseS', 0.005));
            obj.frameClockLine_  = char  (configField(cfg, 'daq.frameClockLine', 'port0/line2'));
            obj.frameRate_       = double(configField(cfg, 'imaging.frameRate', 30));
            obj.aoChannelIdx_    = double(configField(cfg, 'daq.aoChannelIdx',   1));

            % 3D (free-run) mode wiring
            obj.threeD_       = logical(configField(cfg, 'threeD.enabled', false));
            obj.nPlanes_      = double(configField(cfg, 'etl.n_planes', 3));
            obj.paceTrials_   = logical(configField(cfg, 'threeD.pace_trials', true));
            obj.gradientSign_ = double(configField(cfg, 'threeD.depth_gradient_sign', 1));

            % --- Build sessionCfg ---
            obj.sessionCfg_ = obj.buildSessionCfg();

            % Open the continuous session.
            obj.daq.startContinuousSession(obj.sessionCfg_);
            cleanupSession = onCleanup(@() obj.ensureSessionStopped());  %#ok<NASGU>

            obj.sessionInfo_ = struct( ...
                'sessionStartDatetime', obj.sessionStartTime, ...
                'sampleRate',           obj.sampleRate_, ...
                'frameClockLine',       obj.frameClockLine_, ...
                'startAcqLine',         obj.startAcqLine_, ...
                'frameRate',            obj.frameRate_);

            % Snapshot the ScanImage acquisition-counter so per-trial
            % TIFF paths are deterministic (see SYNC_EPISODIC.md §9.2).
            % MUST be called before any armForExternalTrigger; the mock
            % bridge enforces sessionActive_ as a precondition.
            %
            % 3D mode instead opens a FREE-RUN session: ScanImage runs
            % continuous nPlanes ETL volumes for the whole session, no
            % per-trial arming/TIFFs; frames are plane-tagged post-hoc
            % (alignTrialsFreeRun).
            if ~isempty(obj.siBridge)
                if obj.threeD_
                    bridgeSessionInfo = obj.siBridge.beginFreeRunSession(obj.nPlanes_);
                else
                    bridgeSessionInfo = obj.siBridge.beginSession(struct());
                end
                obj.sessionInfo_.bridgeSession = bridgeSessionInfo;
            end

            % Open F-streaming socket once before trial loop, mirroring the
            % previous Sequencer behaviour. Real-bridge-only path.
            if ~isempty(obj.siBridge) && obj.siBridge.supportsStreaming() && ...
                    obj.nStreamCells_ > 0
                obj.siBridge.armStreaming(obj.nStreamCells_);
            end

            trials = obj.sequence.trials;
            obj.runtimeStash_ = cell(1, numel(trials));

            for k = 1:numel(trials)
                trial          = trials(k);
                trialStartTime = datetime('now');
                trialError     = [];
                try
                    tfp.util.safetyChecks('check');                  % C5 placeholder (TODO)
                    obj.runOne(trial, k);                            % populates runtimeStash_{k}

                    % Defer the full saveTrial until end-of-session so the
                    % per-trial AI slice (cut from sessionData.aiData) can
                    % be folded into trial.data alongside the imaging
                    % struct.  Failed trials are saved here on the
                    % error-path branch below.
                catch ME
                    if strcmp(trial.status, 'running')
                        trial.markFailed(ME);
                    elseif strcmp(trial.status, 'pending')
                        % Failed before markRunning could fire — still
                        % transition through running so markFailed is
                        % legal.
                        try
                            trial.markRunning();
                        catch
                            % If even that fails, fall through to log only.
                        end
                        try
                            trial.markFailed(ME);
                        catch
                            % Best-effort: leave the trial in whatever
                            % state it landed in.
                        end
                    end
                    tfp.io.saveTrial(trial, obj.log, ...
                        struct('saveRawData', obj.saveRawData_));
                    tfp.io.sessionLog(obj.log, 'trial-failed', struct( ...
                        'trialIdx',   trial.trialIdx, ...
                        'identifier', ME.identifier, ...
                        'message',    ME.message));
                    trialError = ME;
                end

                seqState = struct( ...
                    'trialIdx',            k, ...
                    'nTrials',             numel(trials), ...
                    'lastTrial',           trial, ...
                    'allTrials',           trials(1:k), ...
                    'sessionDir',          obj.log, ...
                    'sessionStartTime',    obj.sessionStartTime, ...
                    'lastTrialDuration_s', seconds(datetime('now') - trialStartTime));
                tfp.analysis.liveFigures(seqState);

                if ~isempty(trialError)
                    rethrow(trialError);
                end
            end

            % --- Stop session, decode frame clock, align trials ---
            sessionData = obj.daq.stopContinuousSession();

            % First pass: finalise (markComplete) every still-running
            % trial so its t_offset_daq_samples is set and aiData/imaging
            % are folded in.  Failed trials already saved + skipped.
            for k = 1:numel(trials)
                trial = trials(k);
                if strcmp(trial.status, 'running')
                    try
                        obj.finaliseTrialData(trial, k, sessionData);
                    catch ME
                        warning('tfp:trial:Sequencer:finaliseFailed', ...
                            'finaliseTrialData failed for trial %d: %s', ...
                            k, ME.message);
                    end
                end
            end

            % Decode frame clock and run the episodic aligner. See
            % SYNC_EPISODIC.md §7 for the contract.
            [frameStartSamples, frameRateInferredHz, perTrialAlignment, ...
                perFrame, alignReport] = obj.alignSession(sessionData, trials);

            % Second pass: attach episodic alignment + persist completed trials.
            for k = 1:numel(trials)
                trial = trials(k);
                if ~strcmp(trial.status, 'complete')
                    continue
                end

                if isfield(alignReport, 'fatal') && ~alignReport.fatal ...
                        && k <= numel(perTrialAlignment)
                    conf = perTrialAlignment(k).alignmentConfidence;
                    % Attach for any confidence tier other than "none".
                    % Quarantine status means "treat with skepticism" not
                    % "discard"; downstream analysis reads
                    % trial.alignmentConfidence to decide. "none" means the
                    % aligner couldn't even attempt alignment (trial not
                    % complete, missing DAQ anchor) — no data to attach.
                    if conf ~= "none"
                        try
                            trial.attachEpisodicAlignment( ...
                                perTrialAlignment(k).frame_indices_during_stim, ...
                                perTrialAlignment(k).frame_indices_baseline, ...
                                perTrialAlignment(k).alignmentDiscrepancy, ...
                                perTrialAlignment(k).alignmentConfidence);
                        catch ME
                            warning('tfp:trial:Sequencer:alignAttachFailed', ...
                                'attachEpisodicAlignment failed for trial %d: %s', ...
                                k, ME.message);
                        end
                    end
                end

                tfp.io.saveTrial(trial, obj.log, ...
                    struct('saveRawData', obj.saveRawData_));
            end

            tfp.io.sessionLog(obj.log, 'run-complete', ...
                struct('nTrials', numel(trials)));

            result = struct();
            result.sessionInfo         = obj.sessionInfo_;
            result.sessionData         = sessionData;
            result.frameStartSamples   = frameStartSamples;
            result.frameRateInferredHz = frameRateInferredHz;
            result.perFrame            = perFrame;
            result.perTrialAlignment   = perTrialAlignment;
            result.alignReport         = alignReport;
        end

        function abort(obj)
            tfp.util.safetyChecks('abort');
            try, obj.ensureSessionStopped(); catch, end %#ok<CTCH>
            try, obj.dmd.cleanup(); catch, end %#ok<CTCH>
            try, if ~isempty(obj.plm), obj.plm.cleanup(); end; catch, end %#ok<CTCH>
            try, if ~isempty(obj.slm), obj.slm.cleanup(); end; catch, end %#ok<CTCH>
            tfp.io.sessionLog(obj.log, 'abort', []);
        end
    end

    methods (Access = private)
        function runOne(obj, trial, trialIdxInSeq)
            %runOne Execute the new per-trial flow (T-EP-3c).
            %
            %   See class-doc step list. trialIdxInSeq is the position of
            %   `trial` inside obj.sequence.trials and is used to index
            %   into runtimeStash_ for the end-of-session AI slice.

            % --- (Optional) SLM depth-group advance (3D mode) ---------
            % Consecutive trials in the same group skip the advance (and
            % its 3.4 ms LC settle) entirely; advanceToIndex also dedupes
            % internally, but tracking here keeps the session log honest.
            if ~isempty(obj.slm) && isstruct(trial.metadata) && ...
                    isfield(trial.metadata, 'slmGroupIdx')
                g = trial.metadata.slmGroupIdx;
                if g ~= obj.currentSlmGroup_
                    obj.slm.advanceToIndex(g);
                    obj.currentSlmGroup_ = g;
                    tfp.io.sessionLog(obj.log, 'slm-advance', struct( ...
                        'trialIdx', trial.trialIdx, 'groupIdx', g, ...
                        'dzUm', trial.metadata.slmDefocusUm, ...
                        'settleS', obj.slm.settleTimeS()));
                end
            end

            % --- (Optional) Load PLM defocus for axial PPSF -----------
            if ~isempty(obj.plm) && isfield(trial.targetSpec, 'plmPattern') && ...
                    ~isempty(trial.targetSpec.plmPattern)
                obj.plm.loadPattern(trial.targetSpec.plmPattern);
            end

            % --- 1) Load + arm DMD pattern --------------------------
            loadOpts.exposureUs = trial.pulseTrain.pulseWidth_s * 1e6;
            loadOpts.darkTimeUs = trial.pulseTrain.interPulse_s * 1e6;
            obj.dmd.loadPatternSequence(trial.targetSpec.patternRef, loadOpts);
            obj.dmd.armSequence();

            % --- 2) Trigger DMD BEFORE the DAQ AO is queued (S1) ----
            % The DMD is showing the active pattern by the time the
            % laser ramps up via queueClockedAO below.
            obj.dmd.softTrigger();

            % Extract 2D pattern mask for siBridge (patternRef may be 3D).
            patternMask = trial.targetSpec.patternRef;
            if ndims(patternMask) > 2
                patternMask = patternMask(:, :, 1);
            end

            % --- 3) Arm ScanImage for the episodic capture (S2) -----
            % nFrames derives from config.imaging.frameRate + 2 frames of
            % cushion (one for the trigger/exposure latency, one tail).
            % In 3D free-run mode there is NO per-trial arming — SI is
            % already running continuous volumes; the bridge just gets the
            % pattern/defocus context (mock synthesis + logs). nFrames in
            % free-run counts VOLUME slices over the trial window
            % (frameRate is the per-frame rate; every plane produces a
            % frame, so the count is unchanged — only the interpretation).
            nFrames = max(1, uint32(ceil(trial.duration_s * obj.frameRate_) + 2));
            if ~isempty(obj.siBridge)
                obj.siBridge.setPendingPower(trial.powerMw);
                if ~obj.threeD_
                    obj.siBridge.armForExternalTrigger(double(nFrames));
                else
                    obj.siBridge.noteTrialFrames(double(nFrames));
                    if isstruct(trial.metadata) && ...
                            isfield(trial.metadata, 'slmDefocusUm')
                        caps = tfp.util.readHandoffConstants();
                        obj.siBridge.setActiveDefocus( ...
                            trial.metadata.slmDefocusUm, struct( ...
                            'gradientUmPerUm', caps.depth_gradient_um_per_um, ...
                            'gradientSign',    obj.gradientSign_));
                    end
                end
                obj.siBridge.setActivePattern(patternMask, ...
                    trial.preStim_s, trial.pulseTrain.pulseWidth_s);
                if obj.siBridge.supportsStreaming()
                    % Reset the per-trial F accumulator + frame anchor (after
                    % armForExternalTrigger, so nFrames_ is set; before frames arrive).
                    obj.siBridge.clearLiveTraces();
                end
            else
                tfp.io.sessionLog(obj.log, 'siBridge-skipped', ...
                    struct('trialIdx', trial.trialIdx, ...
                           'reason',   'no siBridge'));
            end

            % --- 4) Fire start-acquisition TTL (C1) -----------------
            % If the DAQ doesn't have the configured DO line we skip the
            % pulse with a warning rather than aborting the trial. The
            % real rig always has port0/line10 configured.
            if obj.haveStartAcqLine_
                try
                    obj.daq.sendDigitalPulse(obj.startAcqLine_, obj.startAcqPulseS_);
                catch ME
                    warning('tfp:trial:Sequencer:startAcqPulseFailed', ...
                        'sendDigitalPulse(%s) failed: %s', ...
                        obj.startAcqLine_, ME.message);
                end
            end

            % --- 5) Queue the clocked AO stim waveform --------------
            %
            % TODO C2 / T-EP-3d: trial.powerMw -> volts via
            % tfp.patterns.powerLUT before queueing. For now treat
            % powerMw as a direct voltage proxy.
            %
            % SLM LC safety (handoff §7b, live): near-uniform patterns are
            % power-capped when the SLM is in the path. No-op when
            % config.slm.enabled is false.
            tfp.util.assertSlmPowerSafe(trial.targetSpec.patternRef, ...
                trial.powerMw, obj.config_struct);
            stimWaveform   = obj.buildStimWaveform(trial);
            onsetSample    = obj.daq.queueClockedAO(stimWaveform, ...
                                                    obj.sampleRate_, 'immediate');
            nStimSamples   = size(stimWaveform, 1);
            offsetSample   = onsetSample + uint64(nStimSamples) - uint64(1);

            % --- 6) Mark trial running (capture sample anchors) -----
            trial.markRunning(onsetSample, obj.sampleRate_, obj.sessionStartTime);

            % --- 7) Wait for ScanImage to finish --------------------
            % Get the per-trial TIFF path via getLastTiffPath (the
            % episodic API; see SYNC_EPISODIC.md §9.5). The mock returns
            % a .mat sidecar path the aligner reads transparently; the
            % real bridge returns the on-disk TIFF path.
            %
            % Also call getLastAcquisition() polymorphically so the mock
            % bridge can synthesise the per-trial ΔF/F struct from the
            % active pattern + fake cells (this is what populates
            % lastResult_ on MockScanImageBridge). The real bridge
            % returns the on-disk TIFF path here — discarded in favour
            % of getLastTiffPath()'s derived value — and has no
            % synthetic data of its own. The downstream getSyntheticResult
            % call then returns the synth struct on the mock and [] on
            % the real bridge with no isa() check (resolves S3).
            if ~isempty(obj.siBridge)
                if obj.threeD_
                    % Free-run: no per-trial completion event or TIFF — the
                    % session is one long acquisition. Pace real time so
                    % trials don't overlap on the rig (mock tests disable
                    % via threeD.pace_trials = false).
                    if obj.paceTrials_
                        pause(trial.preStim_s + trial.duration_s + trial.postStim_s);
                    end
                    tiffPath = '';
                else
                    obj.siBridge.waitForCompletion(trial.duration_s * 1.5);
                    tiffPath = obj.siBridge.getLastTiffPath();
                end
                try
                    [~, ~] = obj.siBridge.getLastAcquisition();   %#ok<NCOMMA>
                catch ME
                    warning('tfp:trial:Sequencer:getLastAcquisitionFailed', ...
                        'getLastAcquisition failed for trial %d: %s', ...
                        trial.trialIdx, ME.message);
                end
                synthResult = obj.siBridge.getSyntheticResult();  % [] for real bridge (S3)
            else
                tiffPath    = '';
                synthResult = [];
            end

            % --- 8) Stash per-trial scratch for end-of-session finaliser
            stash.onsetSample        = onsetSample;
            stash.offsetSample       = offsetSample;
            stash.nStimSamples       = uint64(nStimSamples);
            stash.siTiffPath         = tiffPath;
            stash.imaging            = synthResult;
            stash.dmdLog             = obj.dmd.getLog();
            stash.daqLog             = obj.daq.getLog();
            if ~isempty(obj.plm)
                stash.plmLog = obj.plm.getLog();
            else
                stash.plmLog = [];
            end
            if ~isempty(obj.slm)
                stash.slmLog      = obj.slm.getLog();
                stash.slmGroupIdx = obj.currentSlmGroup_;
            else
                stash.slmLog      = [];
                stash.slmGroupIdx = NaN;
            end
            stash.commandedPowerMw   = trial.powerMw;
            stash.completedAt        = datetime('now');
            obj.runtimeStash_{trialIdxInSeq} = stash;

            % --- 9) Defer markComplete to end-of-session finaliser --
            % runOne deliberately stops at status='running'; the
            % end-of-session finaliser (finaliseTrialData) builds the
            % merged data struct including the AI/frame-clock slice
            % from sessionData and calls trial.markComplete exactly
            % once.  This honours Trial.data's SetAccess=private
            % contract (only set inside markComplete) and avoids the
            % "publish twice" anti-pattern.
        end

        function finaliseTrialData(obj, trial, idx, sessionData)
            %finaliseTrialData Build the final data struct and markComplete.
            %
            %   Transitions the trial from 'running' to 'complete' once
            %   all session-level slices (AI + frame clock) have been
            %   extracted from sessionData.  Called from run() in a
            %   post-loop pass.
            if idx > numel(obj.runtimeStash_) || isempty(obj.runtimeStash_{idx})
                return
            end
            stash = obj.runtimeStash_{idx};

            aiSlice = obj.sliceAi(sessionData, stash.onsetSample, ...
                                  stash.offsetSample, trial.preStim_s, trial.postStim_s);
            frameClockSlice = obj.sliceFrameClock(sessionData, stash.onsetSample, ...
                                                  stash.offsetSample, trial.preStim_s, trial.postStim_s);

            data = struct();
            data.aiData     = aiSlice;
            data.frameClock = frameClockSlice;
            % Fold in the rest of the per-trial snapshot.
            data.imaging           = stash.imaging;
            data.dmdLog            = stash.dmdLog;
            data.daqLog            = stash.daqLog;
            data.plmLog            = stash.plmLog;
            data.slmLog            = stash.slmLog;
            data.slmGroupIdx       = stash.slmGroupIdx;
            data.trialIdx          = trial.trialIdx;
            data.commandedPowerMw  = stash.commandedPowerMw;
            data.completedAt       = stash.completedAt;

            % Trial is in status='running' coming out of runOne;
            % markComplete is legal from 'running' and records the
            % offset sample anchor PLUS the per-trial TIFF path on the
            % public Trial.siTiffPath property (3-arg form, see
            % SYNC_EPISODIC.md §6).  This is the single publish point
            % for trial.data + trial.siTiffPath.
            trial.markComplete(data, stash.offsetSample, stash.siTiffPath);
        end

        function aiSlice = sliceAi(obj, sessionData, onsetSample, offsetSample, preStim_s, postStim_s)
            %sliceAi Cut [preStim, postStim] window around the stim from sessionData.aiData.
            if ~isstruct(sessionData) || ~isfield(sessionData, 'aiData')
                aiSlice = [];
                return
            end
            ai = sessionData.aiData;
            if isempty(ai)
                aiSlice = [];
                return
            end
            sr   = obj.sampleRate_;
            preN  = uint64(max(0, round(double(preStim_s)  * sr)));
            postN = uint64(max(0, round(double(postStim_s) * sr)));
            startIdx = double(onsetSample)  - double(preN);
            endIdx   = double(offsetSample) + double(postN);
            startIdx = max(1, floor(startIdx));
            endIdx   = min(size(ai, 1), ceil(endIdx));
            if endIdx < startIdx
                aiSlice = ai(1:0, :);  % empty with correct second dim
                return
            end
            aiSlice = ai(startIdx:endIdx, :);
        end

        function fcSlice = sliceFrameClock(obj, sessionData, onsetSample, offsetSample, preStim_s, postStim_s)
            %sliceFrameClock Cut the frame-clock DI column over the trial window.
            fcSlice = [];
            if ~isstruct(sessionData) || ~isfield(sessionData, 'diData') ...
                    || ~isfield(sessionData, 'lineNames')
                return
            end
            di = sessionData.diData;
            if isempty(di)
                return
            end
            ln = sessionData.lineNames;
            if ~isstruct(ln) || ~isfield(ln, 'diLines') || ~isfield(ln, 'frameClockLine')
                return
            end
            fcLine = ln.frameClockLine;
            if isempty(fcLine)
                return
            end
            col = find(strcmp(fcLine, ln.diLines), 1);
            if isempty(col) || col > size(di, 2)
                return
            end
            sr   = obj.sampleRate_;
            preN  = uint64(max(0, round(double(preStim_s)  * sr)));
            postN = uint64(max(0, round(double(postStim_s) * sr)));
            startIdx = double(onsetSample)  - double(preN);
            endIdx   = double(offsetSample) + double(postN);
            startIdx = max(1, floor(startIdx));
            endIdx   = min(size(di, 1), ceil(endIdx));
            if endIdx < startIdx
                return
            end
            fcSlice = di(startIdx:endIdx, col);
        end

        function [frameStartSamples, frameRateInferredHz, perTrialAlignment, ...
                perFrame, alignReport] = alignSession(obj, sessionData, trials)
            %alignSession Decode SI frame clock + run tfp.io.alignTrialsEpisodic.
            %
            %   Returns the episodic aligner outputs: per-trial diagnostic
            %   rows, the perFrame frame->trial table, and the session-level
            %   report (which the caller MUST consult — quarantined trials
            %   are NOT updated when report.fatal is true).
            %   See SYNC_EPISODIC.md §7.
            frameStartSamples   = uint64([]);
            frameRateInferredHz = NaN;
            perTrialAlignment   = struct([]);
            perFrame            = table( ...
                uint64.empty(0, 1), uint64.empty(0, 1), ...
                nan(0, 1), strings(0, 1), ...
                'VariableNames', {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});
            alignReport = struct('fatal', false, 'fatalReason', "");

            if ~isstruct(sessionData) || ~isfield(sessionData, 'diData') ...
                    || ~isfield(sessionData, 'lineNames')
                return
            end
            ln = sessionData.lineNames;
            if ~isstruct(ln) || ~isfield(ln, 'diLines') || ...
                    ~isfield(ln, 'frameClockLine') || isempty(ln.frameClockLine)
                return
            end
            col = find(strcmp(ln.frameClockLine, ln.diLines), 1);
            if isempty(col) || col > size(sessionData.diData, 2)
                return
            end
            diVec = sessionData.diData(:, col);
            sr    = sessionData.sampleRate;
            try
                [frameStartSamples, frameRateInferredHz] = ...
                    tfp.io.decodeFrameClock(diVec, sr);
            catch ME
                warning('tfp:trial:Sequencer:decodeFrameClockFailed', ...
                    'decodeFrameClock failed: %s', ME.message);
                return
            end

            % 3D free-run sessions align differently: one long acquisition,
            % frames plane-tagged from the clock train, no per-trial TIFF
            % cross-check. See tfp.io.alignTrialsFreeRun.
            if obj.threeD_
                try
                    [perTrialAlignment, perFrame, alignReport] = ...
                        tfp.io.alignTrialsFreeRun(trials, frameStartSamples, ...
                            sr, obj.nPlanes_);
                catch ME
                    warning('tfp:trial:Sequencer:alignTrialsFailed', ...
                        'alignTrialsFreeRun failed: %s', ME.message);
                    alignReport = struct('fatal', true, ...
                        'fatalReason', string(sprintf('%s: %s', ...
                            ME.identifier, ME.message)));
                end
                return
            end

            % Collect per-trial TIFF paths (from Trial.siTiffPath, populated
            % by the 3-arg markComplete in finaliseTrialData).
            tiffPaths = cell(1, numel(trials));
            for k = 1:numel(trials)
                p = trials(k).siTiffPath;
                if isempty(p)
                    tiffPaths{k} = '';
                else
                    tiffPaths{k} = char(p);
                end
            end
            % NOTE: per-trial liveF collection from port 3044 used to live in
            % this loop (orphan from the pre-merge bringup work), but it was
            % unguarded against empty siBridge AND in the wrong scope (it
            % overwrote liveF per trial, never persisting any). Streaming
            % collection belongs in runOne; re-add it there per-trial if/when
            % we wire F-stream into the trial schema.

            try
                [perTrialAlignment, perFrame, alignReport] = ...
                    tfp.io.alignTrialsEpisodic(trials, tiffPaths, ...
                        frameStartSamples, sr);
            catch ME
                warning('tfp:trial:Sequencer:alignTrialsFailed', ...
                    'alignTrialsEpisodic failed: %s', ME.message);
                alignReport = struct('fatal', true, ...
                    'fatalReason', string(sprintf('%s: %s', ...
                        ME.identifier, ME.message)));
            end
        end

        function sessionCfg = buildSessionCfg(obj)
            %buildSessionCfg Compose the struct passed to startContinuousSession.
            %
            %   Includes frameClockLine in diLines (resolves C4). DI/DO
            %   lines are filtered against what the DAQ actually exposes;
            %   missing lines emit a warning rather than aborting.

            % AI channels: use whatever the DAQ exposes (the caller will
            % already have called configureAnalogInput in the experiment
            % script — we mirror that channel list here so the
            % continuous-session AI capture matches).
            aiChannels = [];
            if ~isempty(obj.daq.analogInChannels)
                aiChannels = obj.daq.analogInChannels;
            end

            % AO channels: feed exactly the channel we intend to use for
            % queueClockedAO. The MockDAQ requires a single AO channel
            % when stimWaveform is Nx1.
            aoChannels = obj.aoChannelIdx_;

            % DI lines: include the frame-clock line if the DAQ
            % advertises it; otherwise drop with a warning.
            diLines = obj.resolveDiLines();

            % DO lines: include the start-acq line if the DAQ
            % advertises it; otherwise drop with a warning.
            [doLines, obj.haveStartAcqLine_] = obj.resolveDoLines();

            % frameClockLine field is required by MockDAQ.startContinuousSession
            % only if it appears in diLines; pass '' when we couldn't
            % register the line.
            frameClockField = '';
            if any(strcmp(obj.frameClockLine_, diLines))
                frameClockField = obj.frameClockLine_;
            end

            sessionCfg = struct( ...
                'sampleRate',     obj.sampleRate_, ...
                'aiChannels',     aiChannels, ...
                'aoChannels',     aoChannels, ...
                'diLines',        {diLines}, ...
                'doLines',        {doLines}, ...
                'frameClockLine', frameClockField);
        end

        function diLines = resolveDiLines(obj)
            %resolveDiLines Build the DI line list for the continuous session.
            available = cellstr(obj.coerceLines(obj.daq.digitalInChannels));
            frameLine = obj.frameClockLine_;
            if isempty(frameLine)
                diLines = {};
                return
            end
            if any(strcmp(frameLine, available))
                diLines = {frameLine};
            else
                warning('tfp:trial:Sequencer:noFrameClockLine', ...
                    ['Configured frameClockLine "%s" is not advertised by the DAQ ' ...
                     '(available: %s); frame-clock capture disabled for this session.'], ...
                    frameLine, obj.formatLines(available));
                diLines = {};
            end
        end

        function [doLines, haveStart] = resolveDoLines(obj)
            available = cellstr(obj.coerceLines(obj.daq.digitalOutChannels));
            startLine = obj.startAcqLine_;
            if isempty(startLine)
                doLines   = {};
                haveStart = false;
                return
            end
            if any(strcmp(startLine, available))
                doLines   = {startLine};
                haveStart = true;
            else
                warning('tfp:trial:Sequencer:noStartAcqLine', ...
                    ['Configured startAcqLine "%s" is not advertised by the DAQ ' ...
                     '(available: %s); ScanImage start-acq TTL will be skipped.'], ...
                    startLine, obj.formatLines(available));
                doLines   = {};
                haveStart = false;
            end
        end

        function lines = coerceLines(~, raw)
            if isempty(raw)
                lines = {};
            elseif iscell(raw)
                lines = raw(:)';
            else
                lines = cellstr(raw);
                lines = lines(:)';
            end
        end

        function s = formatLines(~, lines)
            if isempty(lines)
                s = '[]';
            else
                s = strjoin(lines, ', ');
            end
        end

        function sr = fallbackSampleRate(obj)
            %fallbackSampleRate Best-effort guess at sample rate before sessionCfg.
            %   Used when config.daq.sampleRate is absent. Reads from the
            %   DAQ's pre-session sampleRate property if set, else 10 kHz.
            sr = 10000;
            try
                if ~isempty(obj.daq.sampleRate)
                    sr = double(obj.daq.sampleRate);
                end
            catch
                % keep default
            end
        end

        function waveform = buildStimWaveform(obj, trial)
            %buildStimWaveform Construct the clocked-AO waveform for one trial.
            %
            %   TODO C2 / T-EP-3d: trial.powerMw -> volts via
            %   tfp.patterns.powerLUT (and an injected calibration
            %   curve) before this step. For now powerMw is the
            %   commanded voltage directly.
            nStim = max(1, round(trial.pulseTrain.pulseWidth_s * obj.sampleRate_));
            % Coerce missing power to 0 V — some sequence factories
            % (e.g. generateRapidSequential) leave trial.powerMw empty
            % and let downstream layers fill it in.
            v = trial.powerMw;
            if isempty(v) || ~isscalar(v) || ~isfinite(v)
                v = 0;
            end
            % Append a trailing 0 V sample so the AO line returns to
            % baseline at stim offset, mirroring exp_ensemble_activation.
            waveform          = zeros(nStim + 1, 1);
            waveform(1:nStim) = double(v);
        end

        function ensureSessionStopped(obj)
            %ensureSessionStopped Best-effort stop on the error path.
            try
                if ~isempty(obj.daq) && obj.daq.isRunning
                    obj.daq.stopContinuousSession();
                end
            catch
            end
        end
    end
end

% --- Local helpers ---

function value = configField(s, dottedName, default)
%configField Read a possibly-nested field from a config struct.
%   dottedName may be 'daq.sampleRate' or 'imaging.frameRate'; the
%   walker descends one struct per dot. Missing intermediate keys
%   fall back to `default`.
parts = strsplit(dottedName, '.');
cur = s;
for k = 1:numel(parts)
    if ~isstruct(cur) || ~isfield(cur, parts{k})
        value = default;
        return
    end
    cur = cur.(parts{k});
end
if isempty(cur)
    value = default;
else
    value = cur;
end
end
