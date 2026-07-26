function result = exp_axial_ppsf(configOrPath, sessionName)
%exp_axial_ppsf Run an axial-PPSF session and return summary results.
%
%   result = exp_axial_ppsf(configOrPath, sessionName)
%
%   configOrPath may be a path to a YAML config or a pre-built config
%   struct (test path).
%
%   For each axial dz step a PLM defocus pattern is computed once at
%   session start, cached, and attached to trial.targetSpec.plmPattern.
%   The Sequencer loads the pattern into the PLM before each trial.
%   The DMD stim pattern is centred on the target with no lateral offset.
%
%   Optional config fields:
%     config.axialPpsf.dzUm    — vector of dz steps (um); default: symmetric
%                                 ±[5 10 20 30 50] + 0.
%     config.axialPpsf.nReps   — reps per (target, dz); default: 2.
%     config.axialPpsf.powerMw — stim power; default: 5.
%     config.plm.sys           — struct passed to computeDefocusPattern.
%     config.mockTargets        — Nx2 [col row] override for mock targets.

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_axial_ppsf');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_axial_ppsf', 'sessionName', char(sessionName)));

[dmd, daq] = tfp.util.makeHardware(config, 'exp_axial_ppsf');
plm        = makePlm(config);
cleanupHw  = onCleanup(@() teardownHardware(dmd, daq, plm)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

targets  = resolveTargets(config, calibration);

% Spot size is stated at the SAMPLE plane and converted by somaSpotGeometry.
% The old `radiusPx = 15` came from a pre-optics 0.270 um/px guess; at the real
% anisotropic scale it is a 34 x 42 um blob, three to four cells wide — which
% would also blur the axial falloff this experiment measures.
spotDiameterUm = spotDiameterFromConfig(config, 12.7);   %ASSUMED soma; %VERIFY per prep
spotGeom       = tfp.patterns.somaSpotGeometry(spotDiameterUm, config);

% Axial PPSF sweeps in z only, so the DMD spot never moves laterally: the
% containment check is the target plus its own radius, from the illumination
% centroid.
target   = tfp.util.validatePPSFTarget(targets, dmd, 'exp_axial_ppsf', struct( ...
    'spotRadiusPx', spotGeom.semiAxisGroovePx, ...
    'model',        calibration.model));
targets  = target;     % single-target sequence

dzUm     = [0, 5, 10, 20, 30, 50, -5, -10, -20, -30, -50];
nReps    = 2;
powerMw  = 5;
if isfield(config, 'axialPpsf')
    ap = config.axialPpsf;
    if isfield(ap, 'dzUm'),    dzUm    = ap.dzUm;    end
    if isfield(ap, 'nReps'),   nReps   = ap.nReps;   end
    if isfield(ap, 'powerMw'), powerMw = ap.powerMw; end
end

sequence = tfp.trial.TrialSequence.generateAxialPPSF( ...
    targets, dzUm, nReps, powerMw);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

% Compute PLM patterns once per unique dz; attach patternRef and plmPattern
% to each trial. Both are needed: DMD fires the lateral stim; PLM shifts focus.
sys = struct();
if isfield(config, 'plm') && isfield(config.plm, 'sys')
    sys = config.plm.sys;
end
plmCache = containers.Map('KeyType', 'double', 'ValueType', 'any');
for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    dz = tr.metadata.dzUm;
    if ~isKey(plmCache, dz)
        plmCache(dz) = plm.computeDefocusPattern(dz, sys);
    end
    tr.targetSpec.plmPattern = plmCache(dz);
    % Per T-BU-1f the positional radius is the GROOVE-axis (long) semi-axis and
    % spotOptions carries it explicitly; spotGeom.radiusPx is the area-matched
    % ISOTROPIC fallback and would paint ~17% fewer mirrors if mixed in here.
    tr.targetSpec.patternRef = tfp.patterns.singleSpot( ...
        dmd, tr.targetSpec.dmdCoords, spotGeom.semiAxisGroovePx, spotGeom.spotOptions);
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

sequencerOpts.plm = plm;
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

statuses   = {sequence.trials.status};
nCompleted = sum(strcmp(statuses, 'complete'));
nFailed    = sum(strcmp(statuses, 'failed'));

summary = summarizeByDz(sequence.trials, dzUm);

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

function plm = makePlm(config)
switch lower(char(config.hardwareKind))
    case 'mock'
        plm = tfp.hardware.MockPLM();
    case 'real'
        error('tfp:experiments:exp_axial_ppsf:notImplemented', ...
            'real PLM hardware is Phase 4.');
    otherwise
        error('tfp:experiments:exp_axial_ppsf:badKind', ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
plmConfig = struct();
if isfield(config, 'plm')
    plmConfig = config.plm;
end
plm.initialize(plmConfig);
end

function teardownHardware(dmd, daq, plm)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
try, plm.cleanup(); catch, end %#ok<CTCH>
end

function calibration = loadCalibrationOrIdentity(config)
%loadCalibrationOrIdentity Design-constant "calibration" until Phase 3 fits one.
%   The scalar pixelsPerUm this used to carry is retired (T-BU-2b): isotropic,
%   axis-unaware, and colliding by name with the CAMERA-plane scalar that
%   tfp.calibration.alignDMDtoCamera writes. Callers get the optical model and
%   let tfp.patterns.sampleToDmdOffset do the arithmetic. config.dmd.umPerPixel
%   is deliberately NOT read — it is the deprecated isotropic key.
if isfield(config, 'calibration_file') && ~isempty(char(config.calibration_file))
    error('tfp:experiments:exp_axial_ppsf:notImplemented', ...
        'calibration_file loading is Phase 3.');
end
model = tfp.util.opticalModel(config);
% DMD px -> substage CAMERA px; NOT um-valued (TASKS.md T-BU-M0).
calibration.dmdToSample_affine   = eye(3);
calibration.dmdToScan_affine     = eye(3);
calibration.model                = model;
calibration.umPerPixelGroove     = model.umPerPixelGroove;
calibration.umPerPixelDispersion = model.umPerPixelDispersion;
calibration.timestamp            = datetime('now');
calibration.notes                = sprintf( ...
    ['design optical model only (no fitted spatial calibration): ' ...
     '%.4f um/px groove, %.4f um/px dispersion, chip clocked %g deg'], ...
    model.umPerPixelGroove, model.umPerPixelDispersion, model.clockingDeg);
end

function d = spotDiameterFromConfig(config, defaultUm)
%spotDiameterFromConfig Sample-plane stim-spot diameter in um (key stim.spotDiameterUm).
d = defaultUm;
if isfield(config, 'stim') && isstruct(config.stim) ...
        && isfield(config.stim, 'spotDiameterUm') && ~isempty(config.stim.spotDiameterUm)
    d = double(config.stim.spotDiameterUm);
end
end

function targets = resolveTargets(config, calibration)
%resolveTargets Return Nx2 target cell centres in DMD pixel coordinates.
%   Mock: uses config.mockTargets if provided, otherwise built-in defaults.
%   Real: receives ROI centroids from ScanImage PC via msocket.
if strcmpi(char(config.hardwareKind), 'mock')
    if isfield(config, 'mockTargets') && ~isempty(config.mockTargets)
        targets = double(config.mockTargets);
    else
        targets = [640, 400];
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

function summary = summarizeByDz(trials, dzUm)
summary = struct('dzUm', {}, 'meanResponse', {}, 'nTrials', {});
for d = 1:numel(dzUm)
    dz = dzUm(d);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data), continue; end
        if abs(tr.metadata.dzUm - dz) > 1e-9, continue; end
        if ~isfield(tr.data, 'imaging') || isempty(tr.data.imaging) || ...
                ~isfield(tr.data.imaging, 'F')
            continue;
        end
        responses(end+1) = tfp.analysis.peakResponseFromF(tr.data.imaging.F); %#ok<AGROW>
    end
    summary(d).dzUm = dz;
    if isempty(responses)
        summary(d).meanResponse = NaN;
        summary(d).nTrials      = 0;
    else
        summary(d).meanResponse = mean(responses);
        summary(d).nTrials      = numel(responses);
    end
end
end
