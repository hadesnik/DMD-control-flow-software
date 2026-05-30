function result = exp_ppsf_lateral(configOrPath, sessionName)
%exp_ppsf_lateral Run a lateral-PPSF session and return summary results.
%
%   result = exp_ppsf_lateral(configOrPath, sessionName)
%
%   configOrPath may be a path to a YAML config or a pre-built config
%   struct (test path).
%
%   Target cells are received from the ScanImage imaging PC via msocket
%   when hardwareKind='real' (config.roi options control port/timeout).
%   In mock mode, config.mockTargets overrides the built-in defaults.

config = loadOrUseConfig(configOrPath);

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_ppsf_lateral', 'sessionName', char(sessionName)));

[dmd, daq] = makeHardware(config);
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

targets     = resolveTargets(config, calibration);
distancesUm = [-40, -30, -20, -15, -12, -9, -6, -3, 0, 3, 6, 9, 12, 15, 20, 30, 40];
nReps       = 2;
powerMw     = 5;
radiusPx    = 15;

sequence = tfp.trial.TrialSequence.generatePPSF( ...
    targets, distancesUm, nReps, powerMw);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

% Attach patternRef per trial: spot at center + signed offset along +x.
for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    center     = tr.targetSpec.dmdCoords;
    offsetPx   = tr.metadata.offsetUm * calibration.pixelsPerUm;
    stimTarget = center + offsetPx;
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
        dmd = tfp.hardware.DLP650LNIR_DMD(config.dmd);
        daq = tfp.hardware.NI6323_DAQ(config.daq);
    otherwise
        error('tfp:experiments:exp_ppsf_lateral:badKind', ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
if strcmp(lower(char(config.hardwareKind)), 'mock')
    dmd.initialize(config.dmd);
    daq.initialize(config.daq);
end
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
umPerPx = 1;
if isfield(config, 'dmd') && isfield(config.dmd, 'umPerPixel')
    umPerPx = double(config.dmd.umPerPixel);
end
calibration.dmdToSample_affine = eye(3);
calibration.dmdToScan_affine   = eye(3);
calibration.pixelsPerUm        = 1 / umPerPx;
calibration.umPerPixel         = umPerPx;
calibration.timestamp          = datetime('now');
calibration.notes              = sprintf('pixel-scale only: %.4f um/px (no spatial calibration)', umPerPx);
end

function targets = resolveTargets(config, calibration)
%resolveTargets Return Nx2 target cell centres in DMD pixel coordinates.
%   Mock: uses config.mockTargets if provided, otherwise built-in defaults.
%   Real: receives ROI centroids from ScanImage PC via msocket and converts
%         scan-field coords -> DMD pixels using calibration.dmdToScan_affine.
if strcmpi(char(config.hardwareKind), 'mock')
    if isfield(config, 'mockTargets') && ~isempty(config.mockTargets)
        targets = double(config.mockTargets);
    else
        targets = [400, 400; 500, 400; 600, 400];
    end
    return
end
if isfield(config, 'testTargets') && ~isempty(config.testTargets)
    targets = reshape(double(config.testTargets(:)), 2, [])';
    return
end
roiOpts = struct();
if isfield(config, 'roi')
    roiOpts = config.roi;
end
centroids_scan = tfp.io.receiveROIsFromScanImage(roiOpts);
targets = scanFieldToDMD(centroids_scan, calibration);
end

function dmdCoords = scanFieldToDMD(scanCoords, calibration)
if ~isfield(calibration, 'dmdToScan_affine')
    dmdCoords = scanCoords;
    return
end
scanToDmd = inv(calibration.dmdToScan_affine);
nPts  = size(scanCoords, 1);
pts_h = [scanCoords, ones(nPts, 1)]';
dmd_h = scanToDmd * pts_h;
dmdCoords = dmd_h(1:2, :)';
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
