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

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_ppsf_lateral');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_ppsf_lateral', 'sessionName', char(sessionName)));

[dmd, daq] = tfp.util.makeHardware(config, 'exp_ppsf_lateral');
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

targets     = resolveTargets(config, calibration);
target      = tfp.util.validatePPSFTarget(targets, dmd, 'exp_ppsf_lateral');
targets     = target;     % single-target sequence
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
    cells    = tfp.util.buildCells(config.fakeCells);
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

function summary = summarizeByDistance(trials, distancesUm)
%summarizeByDistance Bin trials by the SIGNED x-component of their offset.
%
%   distancesUm is 1D so generatePPSF treats each entry d as the 2D offset
%   [d, 0]. Trial.metadata stores both .offsetUm = [dx dy] (signed) and
%   .distanceUm = norm([dx dy]) (radial, always non-negative). For a
%   symmetric input like [-40 ... 40] the radial distanceUm aliases
%   sign-flipped pairs, so we bin on the signed x-offset instead.
summary = struct('distanceUm', {}, 'meanResponse', {}, 'nTrials', {});
for d = 1:numel(distancesUm)
    dist = distancesUm(d);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data), continue; end
        % Match the signed x-offset (column 1 of offsetUm) for 1D PPSF runs.
        if abs(tr.metadata.offsetUm(1) - dist) > 1e-9, continue; end
        if ~isfield(tr.data, 'imaging') || isempty(tr.data.imaging) || ...
                ~isfield(tr.data.imaging, 'F')
            continue;
        end
        responses(end+1) = tfp.analysis.peakResponseFromF(tr.data.imaging.F); %#ok<AGROW>
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
