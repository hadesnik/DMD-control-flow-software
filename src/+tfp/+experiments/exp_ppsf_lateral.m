function result = exp_ppsf_lateral(configOrPath, sessionName)
%exp_ppsf_lateral Run a lateral-PPSF session and return summary results.
%
%   result = exp_ppsf_lateral(configOrPath, sessionName)
%
%   configOrPath may be a path to a YAML config or a pre-built config
%   struct (test path).
%
%   Phase 1: 3 hardcoded mock targets x 3 distances x 2 reps = 18 trials.
%   For real hardware, targets would be picked interactively from a
%   GCaMP FOV.
%
%   TODO(Phase 3): replace hardcoded targets with interactive picking.

config = loadOrUseConfig(configOrPath);

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_ppsf_lateral', 'sessionName', char(sessionName)));

[dmd, daq] = makeHardware(config);
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

% Phase 1 mock target picking.
targets     = [400, 400; 500, 400; 600, 400];
distancesUm = [0, 10, 20];
nReps       = 2;
powerMw     = 5;
radiusPx    = 5;

sequence = tfp.trial.TrialSequence.generatePPSF( ...
    targets, distancesUm, nReps, powerMw);

% Attach patternRef per trial: spot at center + (distance um -> px) along +x.
for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    center     = tr.targetSpec.dmdCoords;
    d          = tr.metadata.distanceUm;
    offsetPx   = d * calibration.pixelsPerUm;
    stimTarget = center + [offsetPx, 0];
    tr.targetSpec.patternRef = tfp.patterns.singleSpot(dmd, stimTarget, radiusPx);
end

% Run; swallow errors so the analysis layer still produces a result.
sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
runError = [];
try
    sequencer.run();
catch ME
    runError = ME;
    tfp.io.sessionLog(sessionDir, 'experiment-run-error', struct( ...
        'identifier', ME.identifier, 'message', ME.message));
end

statuses    = {sequence.trials.status};
nCompleted  = sum(strcmp(statuses, 'complete'));
nFailed     = sum(strcmp(statuses, 'failed'));

summary = summarizeByDistance(sequence.trials, distancesUm);

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
    error('tfp:experiments:exp_ppsf_lateral:badConfig', ...
        'configOrPath must be a char/string path or a config struct.');
end
end

function [dmd, daq] = makeHardware(config)
switch lower(char(config.hardwareKind))
    case 'mock'
        dmd = tfp.hardware.MockDMD();
        daq = tfp.hardware.MockDAQ();
    case 'real'
        error('tfp:experiments:exp_ppsf_lateral:notImplemented', ...
            'real hardware is Phase 2+.');
    otherwise
        error('tfp:experiments:exp_ppsf_lateral:badKind', ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
dmd.initialize(config.dmd);
daq.initialize(config.daq);
end

function teardownHardware(dmd, daq)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
end

function calibration = loadCalibrationOrIdentity(config)
if isfield(config, 'calibration_file') && ~isempty(char(config.calibration_file))
    error('tfp:experiments:exp_ppsf_lateral:notImplemented', ...
        'calibration_file loading is Phase 3.');
end
calibration.dmdToSample_affine = eye(3);
calibration.pixelsPerUm        = 1;
calibration.umPerPixel         = 1;
calibration.timestamp          = datetime('now');
calibration.notes              = 'identity fallback (mock)';
end

function r = tracePeakResponse(ai)
% Pipe AI(N x nChans) through onlineDFF by treating channels as ROI pixels.
[N, nChans] = size(ai);
frames    = reshape(ai, [N, 1, nChans]);
roi       = true(1, nChans);
nBaseline = max(1, round(N / 4));
trace     = tfp.analysis.onlineDFF(frames, roi, 1:nBaseline);
r         = max(trace);
end

function summary = summarizeByDistance(trials, distancesUm)
summary = struct('distanceUm', {}, 'meanResponse', {}, 'nTrials', {});
for d = 1:numel(distancesUm)
    dist = distancesUm(d);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data) || ~isfield(tr.data, 'aiData'), continue; end
        if abs(tr.metadata.distanceUm - dist) > 1e-9, continue; end
        responses(end+1) = tracePeakResponse(tr.data.aiData); %#ok<AGROW>
    end
    summary(d).distanceUm = dist;
    if isempty(responses)
        summary(d).meanResponse = NaN;
        summary(d).nTrials      = 0;
    else
        summary(d).meanResponse = mean(responses);
        summary(d).nTrials      = numel(responses);
    end
end
end
