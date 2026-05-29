classdef Sequencer < handle
    %Sequencer State machine that runs a TrialSequence end-to-end.
    %
    %   Constructor:
    %     Sequencer(dmd, daq, sequence, sessionDir, opts)
    %       opts.siBridge (optional, default empty)
    %
    %   Phase 1 contract: the caller (experiment script / test) is
    %   responsible for configuring the DAQ's AI/AO/DO channels via
    %   configureAnalogInput / configureAnalogOutput / configureDigitalOutput
    %   *before* run() is called. The Sequencer reads daq.analogOutChannels
    %   and daq.digitalOutChannels (the available lists) and assumes the
    %   caller has configured all of them.
    %
    %   See ARCHITECTURE.md "+tfp.+trial / Sequencer" and
    %   "Data flow for one trial".

    properties
        dmd
        daq
        siBridge
        plm              % optional PLM for per-trial defocus (axial PPSF)
        sequence
        log              % path to session directory
        sessionStartTime % datetime set at the top of run()
    end

    properties (Access = private)
        nStreamCells_  % ROI count passed to siBridge.armStreaming(); 0 = streaming disabled
        saveRawData_   % logical: write trial_NNNN_raw.mat per trial (default true)
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
        end

        function run(obj)
            obj.sessionStartTime = datetime('now');
            tfp.io.sessionLog(obj.log, 'run-start', ...
                struct('nTrials', numel(obj.sequence.trials)));

            % Open F-streaming socket once before trial loop (imaging PC connects once/session).
            if ~isempty(obj.siBridge) && obj.siBridge.supportsStreaming() && ...
                    obj.nStreamCells_ > 0
                obj.siBridge.armStreaming(obj.nStreamCells_);
            end

            trials = obj.sequence.trials;
            for k = 1:numel(trials)
                trial          = trials(k);
                trialStartTime = datetime('now');
                trialError     = [];
                try
                    tfp.util.safetyChecks('check');
                    trial.markRunning();
                    obj.runOne(trial);                 % calls markComplete
                    tfp.io.saveTrial(trial, obj.log, struct('saveRawData', obj.saveRawData_));
                catch ME
                    trial.markFailed(ME);
                    tfp.io.saveTrial(trial, obj.log, struct('saveRawData', obj.saveRawData_));  % save failed trials too
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

            tfp.io.sessionLog(obj.log, 'run-complete', ...
                struct('nTrials', numel(trials)));
        end

        function abort(obj)
            tfp.util.safetyChecks('abort');
            try, obj.daq.stop(); catch, end %#ok<CTCH>
            try, obj.dmd.cleanup(); catch, end %#ok<CTCH>
            try, if ~isempty(obj.plm), obj.plm.cleanup(); end; catch, end %#ok<CTCH>
            tfp.io.sessionLog(obj.log, 'abort', []);
        end
    end

    methods (Access = private)
        function runOne(obj, trial)
            %runOne Execute the 11-step trial loop for a single trial.

            % Load PLM defocus pattern for this trial (axial PPSF; no-op otherwise).
            if ~isempty(obj.plm) && isfield(trial.targetSpec, 'plmPattern') && ...
                    ~isempty(trial.targetSpec.plmPattern)
                obj.plm.loadPattern(trial.targetSpec.plmPattern);
            end

            % Step 2: load DMD pattern and arm.
            loadOpts.exposureUs = trial.pulseTrain.pulseWidth_s * 1e6;
            loadOpts.darkTimeUs = trial.pulseTrain.interPulse_s * 1e6;
            obj.dmd.loadPatternSequence(trial.targetSpec.patternRef, loadOpts);
            obj.dmd.armSequence();

            % Extract 2D pattern for siBridge (patternRef may be 2D or 3D).
            patternMask = trial.targetSpec.patternRef;
            if ndims(patternMask) > 2
                patternMask = patternMask(:, :, 1);
            end

            % Step 3: queue DAQ outputs.
            nSamples = round(trial.duration_s * obj.daq.sampleRate);
            nAo = numel(obj.daq.analogOutChannels);
            obj.daq.queueAnalogOutput(zeros(nSamples, nAo));

            doLines = obj.daq.digitalOutChannels;
            if iscell(doLines) && ~isempty(doLines)
                firstLine = doLines{1};
            elseif ~isempty(doLines)
                firstLine = doLines(1);
            else
                firstLine = '';
            end
            if ~isempty(firstLine)
                obj.daq.queueDigitalPulses({char(firstLine)}, ...
                    trial.preStim_s, trial.pulseTrain.pulseWidth_s);
            end

            % Step 4: arm ScanImage if bridge present, else log skip.
            if ~isempty(obj.siBridge)
                obj.siBridge.setPendingPower(trial.powerMw);
                obj.siBridge.armForExternalTrigger(round(trial.duration_s * 30));
                obj.siBridge.setActivePattern(patternMask, trial.preStim_s, ...
                    trial.pulseTrain.pulseWidth_s);
                if obj.siBridge.supportsStreaming()
                    % Reset the per-trial F accumulator + frame anchor (after
                    % armForExternalTrigger, so nFrames_ is set; before frames arrive).
                    obj.siBridge.clearLiveTraces();
                end
            else
                tfp.io.sessionLog(obj.log, 'siBridge-skipped', ...
                    struct('trialIdx', trial.trialIdx, ...
                           'reason',   'no siBridge (Phase 1)'));
            end

            % Step 5: start DAQ.
            obj.daq.start();

            % Step 6: trigger DMD and acquire.
            obj.dmd.softTrigger();
            ai = obj.daq.readAnalogInput(nSamples);

            % Read frame clock DI line before stop() clears the buffer.
            frameClock = [];
            diLines = obj.daq.digitalInChannels;
            if iscell(diLines) && ~isempty(diLines)
                try
                    frameClock = obj.daq.readDigitalInput(diLines{1}, nSamples);
                catch ME
                    warning('tfp:trial:Sequencer:frameClockReadFailed', ...
                        'Frame clock read failed for %s: %s', diLines{1}, ME.message);
                end
            end

            % Step 7: stop DAQ.
            obj.daq.stop();

            % Step 8: wait for SI completion; collect imaging data if bridge present.
            frameTimestamps = [];
            imaging         = [];
            imagingTiffPath = '';
            liveF           = [];
            if ~isempty(obj.siBridge)
                obj.siBridge.waitForCompletion(trial.duration_s * 2);
                [framesPath, frameTimestamps] = obj.siBridge.getLastAcquisition();
                if isa(obj.siBridge, 'tfp.hardware.MockScanImageBridge')
                    imaging = obj.siBridge.getSyntheticResult();
                else
                    % Real bridge: ScanImage writes TIFFs on the imaging PC.
                    % Store the path; don't copy the matrix into the trial .mat.
                    imagingTiffPath = framesPath;
                end
                if obj.siBridge.supportsStreaming()
                    % Per-frame ROI fluorescence streamed over port 3044 this trial
                    % (nCells × nFrames; NaN columns = frames not received).
                    liveF = obj.siBridge.getLiveTraces();
                end
            end

            % Steps 9-10: package data.
            plmLog = [];
            if ~isempty(obj.plm)
                plmLog = obj.plm.getLog();
            end
            data = struct( ...
                'aiData',             ai, ...
                'frameClock',         frameClock, ...
                'frameTimestamps',    frameTimestamps, ...
                'imaging',            imaging, ...
                'imagingTiffPath',    imagingTiffPath, ...
                'liveF',              liveF, ...
                'dmdLog',             obj.dmd.getLog(), ...
                'daqLog',             obj.daq.getLog(), ...
                'plmLog',             plmLog, ...
                'trialIdx',           trial.trialIdx, ...
                'commandedPowerMw',   trial.powerMw, ...
                'completedAt',        datetime('now'));

            % Step 11: mark complete (outer run() does the saveTrial).
            trial.markComplete(data);
        end
    end
end
