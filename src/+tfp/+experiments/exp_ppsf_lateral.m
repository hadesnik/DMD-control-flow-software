function result = exp_ppsf_lateral(configOrPath, sessionName)
%exp_ppsf_lateral Run a lateral-PPSF session and return summary results.
%
%   result = exp_ppsf_lateral(configOrPath, sessionName)
%
%   configOrPath may be a path to a YAML config or a pre-built config
%   struct (test path).
%
%   Phase 1: 3 hardcoded mock targets x 9 distances x 2 reps = 54 trials.
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
distancesUm = [0, 3, 6, 9, 12, 15, 20, 30, 40];
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

% Build mock ScanImage bridge from fakeCells if defined in config.
siBridge = [];
if isfield(config, 'fakeCells') && ~isempty(config.fakeCells)
    siCfg = struct('frameRate', 30, 'simulateLatency', false);
    if isfield(config, 'imaging')
        siCfg = config.imaging;
    end
    cells    = buildCells(config.fakeCells);
    siBridge = tfp.hardware.MockScanImageBridge(cells, siCfg);
end

% Run; swallow errors so the analysis layer still produces a result.
sequencerOpts = struct();
if ~isempty(siBridge)
    sequencerOpts.siBridge = siBridge;
end
sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir, sequencerOpts);
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

function cells = buildCells(fakeCellsCfg)
% Build CellResponseModel cell array from the fakeCells config struct array.
% Returns 1×N cell array; callers index with cells{k}.
% Typed-array pre-allocation (backward loop) requires a no-arg constructor,
% which CellResponseModel intentionally omits — hence cell array here.
nCells = numel(fakeCellsCfg);
cells  = cell(1, nCells);
for k = 1:nCells
    fc   = fakeCellsCfg(k);
    args = {};
    if isfield(fc, 'amplitude'),   args = [args, {'amplitude',   double(fc.amplitude)}]; end %#ok<AGROW>
    if isfield(fc, 'sigma'),       args = [args, {'sigma',       double(fc.sigma)}]; end %#ok<AGROW>
    if isfield(fc, 'aiChannel'),   args = [args, {'aiChannel',   double(fc.aiChannel)}]; end %#ok<AGROW>
    if isfield(fc, 'tag'),         args = [args, {'responseTag', char(fc.tag)}]; end %#ok<AGROW>
    cells{k} = tfp.sim.CellResponseModel( ...
        [double(fc.dmdCol), double(fc.dmdRow)], double(fc.radiusDmd), args{:});
end
end

function r = tracePeakResponse(F)
% F: nCells x T raw fluorescence from SyntheticImaging.
%   Encoding: F = BASELINE + dFF * BASELINE, BASELINE = 1000.
BASELINE = 1000;
dff = (double(F) - BASELINE) / BASELINE;
r   = max(dff(:));
end

function summary = summarizeByDistance(trials, distancesUm)
summary = struct('distanceUm', {}, 'meanResponse', {}, 'nTrials', {});
for d = 1:numel(distancesUm)
    dist = distancesUm(d);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data), continue; end
        if abs(tr.metadata.distanceUm - dist) > 1e-9, continue; end
        if ~isfield(tr.data, 'imaging') || isempty(tr.data.imaging) || ...
                ~isfield(tr.data.imaging, 'F')
            continue;
        end
        responses(end+1) = tracePeakResponse(tr.data.imaging.F); %#ok<AGROW>
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
