function result = exp_power_curve(configOrPath, sessionName)
%exp_power_curve Run a power-curve session at one mock target.
%
%   Phase 1: 1 hardcoded target, 3 powers, 2 reps = 6 trials.

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_power_curve');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_power_curve', 'sessionName', char(sessionName)));

[dmd, daq] = tfp.util.makeHardware(config, 'exp_power_curve');
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

target   = [500, 400];
powersMw = [1, 2, 4];
nReps    = 2;
radiusPx = 15;

sequence = tfp.trial.TrialSequence.generatePowerCurve(target, powersMw, nReps);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    tr.targetSpec.patternRef = tfp.patterns.singleSpot(dmd, target, radiusPx);
end

sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
runError = [];
try
    sequencer.run();
catch ME
    runError = ME;
    tfp.io.sessionLog(sessionDir, 'experiment-run-error', struct( ...
        'identifier', ME.identifier, 'message', ME.message));
end

statuses   = {sequence.trials.status};
nCompleted = sum(strcmp(statuses, 'complete'));
nFailed    = sum(strcmp(statuses, 'failed'));

summary = summarizeByPower(sequence.trials, powersMw);

tfp.io.sessionLog(sessionDir, 'session-end', struct( ...
    'nTrialsCompleted', nCompleted, 'nTrialsFailed', nFailed));

result.sessionDir       = sessionDir;
result.nTrialsCompleted = nCompleted;
result.nTrialsFailed    = nFailed;
result.summary          = summary;
if ~isempty(runError)
    result.runError = struct('identifier', runError.identifier, ...
                             'message',    runError.message);
end
end

% --- Local helpers ---

function teardownHardware(dmd, daq)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
end

function summary = summarizeByPower(trials, powersMw)
summary = struct('powerMw', {}, 'meanResponse', {}, 'nTrials', {});
for p = 1:numel(powersMw)
    pw = powersMw(p);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data) || ~isfield(tr.data, 'aiData'), continue; end
        if abs(tr.powerMw - pw) > 1e-9, continue; end
        responses(end+1) = tfp.analysis.peakResponseFromAi(tr.data.aiData); %#ok<AGROW>
    end
    summary(p).powerMw = pw;
    if isempty(responses)
        summary(p).meanResponse = NaN;
        summary(p).nTrials      = 0;
    else
        summary(p).meanResponse = mean(responses);
        summary(p).nTrials      = numel(responses);
    end
end
end
