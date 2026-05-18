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
        sequence
        log              % path to session directory
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
        end

        function run(obj)
            tfp.io.sessionLog(obj.log, 'run-start', ...
                struct('nTrials', numel(obj.sequence.trials)));

            trials = obj.sequence.trials;
            for k = 1:numel(trials)
                trial = trials(k);
                try
                    tfp.util.safetyChecks('check');
                    trial.markRunning();
                    obj.runOne(trial);                 % calls markComplete
                    tfp.io.saveTrial(trial, obj.log);
                catch ME
                    trial.markFailed(ME);
                    tfp.io.saveTrial(trial, obj.log);  % save failed trials too
                    tfp.io.sessionLog(obj.log, 'trial-failed', struct( ...
                        'trialIdx',   trial.trialIdx, ...
                        'identifier', ME.identifier, ...
                        'message',    ME.message));
                    rethrow(ME);
                end
            end

            tfp.io.sessionLog(obj.log, 'run-complete', ...
                struct('nTrials', numel(trials)));
        end

        function abort(obj)
            tfp.util.safetyChecks('abort');
            try, obj.daq.stop(); catch, end %#ok<CTCH>
            try, obj.dmd.cleanup(); catch, end %#ok<CTCH>
            tfp.io.sessionLog(obj.log, 'abort', []);
        end
    end

    methods (Access = private)
        function runOne(obj, trial)
            %runOne Execute the 11-step trial loop for a single trial.

            % Step 2: load DMD pattern and arm.
            loadOpts.exposureUs = trial.pulseTrain.pulseWidth_s * 1e6;
            loadOpts.darkTimeUs = trial.pulseTrain.interPulse_s * 1e6;
            obj.dmd.loadPatternSequence(trial.targetSpec.patternRef, loadOpts);
            obj.dmd.armSequence();

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
                obj.siBridge.armForExternalTrigger(round(trial.duration_s * 30));
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

            % Step 7: stop DAQ.
            obj.daq.stop();

            % Step 8: wait for SI completion if bridge present.
            if ~isempty(obj.siBridge)
                obj.siBridge.waitForCompletion(trial.duration_s * 2);
            end

            % Steps 9-10: package data.
            data = struct( ...
                'aiData',      ai, ...
                'dmdLog',      obj.dmd.getLog(), ...
                'daqLog',      obj.daq.getLog(), ...
                'trialIdx',    trial.trialIdx, ...
                'completedAt', datetime('now'));

            % Step 11: mark complete (outer run() does the saveTrial).
            trial.markComplete(data);
        end
    end
end
