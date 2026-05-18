function result = exp_rapid_sequential(configOrPath, sessionName)
%exp_rapid_sequential Run a rapid-sequential session and return summary.
%
%   Phase 1: 3 hardcoded targets, ISI=0.1s, 2 reps = 6 trials.
%
%   TODO(Phase 3): replace hardcoded targets with interactive picking.

config = loadOrUseConfig(configOrPath);

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_rapid_sequential', 'sessionName', char(sessionName)));

[dmd, daq] = makeHardware(config);
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

% Mock targets.
targets  = [400, 400; 500, 400; 600, 400];
isi_s    = 0.1;
nReps    = 2;
radiusPx = 5;

sequence = tfp.trial.TrialSequence.generateRapidSequential(targets, isi_s, nReps);

for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    tr.targetSpec.patternRef = tfp.patterns.singleSpot( ...
        dmd, tr.targetSpec.dmdCoords, radiusPx);
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

summary = summarizeByTarget(sequence.trials, targets);

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

function config = loadOrUseConfig(configOrPath)
if isstruct(configOrPath)
    config = configOrPath;
elseif ischar(configOrPath) || (isstring(configOrPath) && isscalar(configOrPath))
    config = tfp.io.loadConfig(char(configOrPath));
else
    error('tfp:experiments:exp_rapid_sequential:badConfig', ...
        'configOrPath must be a char/string path or a config struct.');
end
end

function [dmd, daq] = makeHardware(config)
switch lower(char(config.hardwareKind))
    case 'mock'
        dmd = tfp.hardware.MockDMD();
        daq = tfp.hardware.MockDAQ();
    case 'real'
        error('tfp:experiments:exp_rapid_sequential:notImplemented', ...
            'real hardware is Phase 2+.');
    otherwise
        error('tfp:experiments:exp_rapid_sequential:badKind', ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
dmd.initialize(config.dmd);
daq.initialize(config.daq);
end

function teardownHardware(dmd, daq)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
end

function r = tracePeakResponse(ai)
[N, nChans] = size(ai);
frames    = reshape(ai, [N, 1, nChans]);
roi       = true(1, nChans);
nBaseline = max(1, round(N / 4));
trace     = tfp.analysis.onlineDFF(frames, roi, 1:nBaseline);
r         = max(trace);
end

function summary = summarizeByTarget(trials, targets)
summary = struct('target', {}, 'meanResponse', {}, 'nTrials', {});
for t = 1:size(targets, 1)
    tgt = targets(t, :);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data) || ~isfield(tr.data, 'aiData'), continue; end
        if ~isequal(tr.targetSpec.dmdCoords, tgt), continue; end
        responses(end+1) = tracePeakResponse(tr.data.aiData); %#ok<AGROW>
    end
    summary(t).target = tgt;
    if isempty(responses)
        summary(t).meanResponse = NaN;
        summary(t).nTrials      = 0;
    else
        summary(t).meanResponse = mean(responses);
        summary(t).nTrials      = numel(responses);
    end
end
end
