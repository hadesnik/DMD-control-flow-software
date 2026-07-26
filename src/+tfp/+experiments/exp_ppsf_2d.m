function result = exp_ppsf_2d(configOrPath, sessionName)
%exp_ppsf_2d Run a 2D lateral-PPSF session and return a 2D response map.
%
%   result = exp_ppsf_2d(configOrPath, sessionName)
%
%   configOrPath may be a path to a YAML config or a pre-built config
%   struct (test path).
%
%   Samples a Gaussian-spaced 2D offset grid (gaussianGrid2D) around
%   each target cell. Returns result.ppsf2d_summary with fields:
%     .offsetsDx    sorted unique dx values (1 x nDx, um)
%     .offsetsDy    sorted unique dy values (1 x nDy, um)
%     .responseMap  nDy x nDx matrix of mean peak dF/F
%     .semMap       nDy x nDx matrix of standard error

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_ppsf_2d');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_ppsf_2d', 'sessionName', char(sessionName)));

[dmd, daq] = tfp.util.makeHardware(config, 'exp_ppsf_2d');
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

% Target cells and 2D offset grid (overridable via config.ppsf2d for tests).
targets = resolveTargets(config, calibration);
g = struct('maxUm', 40, 'nPointsPerHalfAxis', 4, 'sigmaPsfUm', 8, 'nReps', 2);
if isfield(config, 'ppsf2d')
    ov = config.ppsf2d;
    if isfield(ov, 'maxUm'),              g.maxUm              = ov.maxUm;              end
    if isfield(ov, 'nPointsPerHalfAxis'), g.nPointsPerHalfAxis = ov.nPointsPerHalfAxis; end
    if isfield(ov, 'sigmaPsfUm'),         g.sigmaPsfUm         = ov.sigmaPsfUm;         end
    if isfield(ov, 'nReps'),              g.nReps              = ov.nReps;              end
end
offsetsUm = tfp.trial.TrialSequence.gaussianGrid2D(g.maxUm, g.nPointsPerHalfAxis, g.sigmaPsfUm);
nReps     = g.nReps;
powerMw   = 5;

% Spot size is stated at the SAMPLE plane and converted by somaSpotGeometry.
% The old `radiusPx = 15` came from a pre-optics 0.270 um/px guess; at the real
% anisotropic scale it is a 34 x 42 um blob, three to four cells wide.
spotDiameterUm = spotDiameterFromConfig(config, 12.7);   %ASSUMED soma; %VERIFY per prep
spotGeom       = tfp.patterns.somaSpotGeometry(spotDiameterUm, config);

% The target must leave room for the WHOLE 2D grid inside the illuminated
% patch, measured from the illumination centroid (not the chip centre).
target  = tfp.util.validatePPSFTarget(targets, dmd, 'exp_ppsf_2d', struct( ...
    'offsetsUm',    offsetsUm, ...
    'spotRadiusPx', spotGeom.semiAxisGroovePx, ...
    'model',        calibration.model));
targets = target;     % single-target sequence

sequence = tfp.trial.TrialSequence.generatePPSF( ...
    targets, offsetsUm, nReps, powerMw);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

% Attach patternRef per trial: spot at center + 2D offset. The um -> DMD-px
% conversion is anisotropic and runs along the chip DIAGONALS (45 deg
% clocking), so it must go through sampleToDmdOffset; a scalar would skew the
% 2D response map, not just scale it. Per T-BU-1f the positional radius is the
% GROOVE-axis (long) semi-axis, never spotGeom.radiusPx.
for k = 1:numel(sequence.trials)
    tr         = sequence.trials(k);
    center     = tr.targetSpec.dmdCoords;
    offsetPx   = tfp.patterns.sampleToDmdOffset(tr.metadata.offsetUm, calibration.model);
    stimTarget = center + offsetPx;
    tr.targetSpec.patternRef = tfp.patterns.singleSpot( ...
        dmd, stimTarget, spotGeom.semiAxisGroovePx, spotGeom.spotOptions);
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

% Run sequencer.
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

statuses   = {sequence.trials.status};
nCompleted = sum(strcmp(statuses, 'complete'));
nFailed    = sum(strcmp(statuses, 'failed'));

ppsf2d_summary = summarize2D(sequence.trials, offsetsUm);

tfp.io.sessionLog(sessionDir, 'session-end', struct( ...
    'nTrialsCompleted', nCompleted, 'nTrialsFailed', nFailed));

result.sessionDir       = sessionDir;
result.nTrialsCompleted = nCompleted;
result.nTrialsFailed    = nFailed;
result.ppsf2d_summary   = ppsf2d_summary;
if ~isempty(runError)
    result.runError = struct('identifier', runError.identifier, ...
                             'message',    runError.message);
end

result.ppsf2d_figure_path = savePPSF2DFigure(ppsf2d_summary, sessionDir);
end

% --- Local helpers ---

function teardownHardware(dmd, daq)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
end

function calibration = loadCalibrationOrIdentity(config)
%loadCalibrationOrIdentity Design-constant "calibration" until Phase 3 fits one.
%   The scalar pixelsPerUm this used to carry is retired (T-BU-2b): isotropic,
%   axis-unaware, and colliding by name with the CAMERA-plane scalar that
%   tfp.calibration.alignDMDtoCamera writes. Callers get the optical model and
%   let tfp.patterns.sampleToDmdOffset do the arithmetic. config.dmd.umPerPixel
%   is deliberately NOT read — it is the deprecated isotropic key.
if isfield(config, 'calibration_file') && ~isempty(char(config.calibration_file))
    error('tfp:experiments:exp_ppsf_2d:notImplemented', ...
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

function summary = summarize2D(trials, offsetsUm)
offsetsDx = unique(offsetsUm(:, 1))';
offsetsDy = unique(offsetsUm(:, 2))';
nDx = numel(offsetsDx);
nDy = numel(offsetsDy);

responseMap = NaN(nDy, nDx);
semMap      = NaN(nDy, nDx);

for iy = 1:nDy
    for ix = 1:nDx
        dx = offsetsDx(ix);
        dy = offsetsDy(iy);
        responses = [];
        for k = 1:numel(trials)
            tr = trials(k);
            if ~strcmp(tr.status, 'complete'), continue; end
            if ~isstruct(tr.data),             continue; end
            off = tr.metadata.offsetUm;
            if abs(off(1) - dx) > 1e-9 || abs(off(2) - dy) > 1e-9, continue; end
            if ~isfield(tr.data, 'imaging') || isempty(tr.data.imaging) || ...
                    ~isfield(tr.data.imaging, 'F')
                continue;
            end
            responses(end+1) = tfp.analysis.peakResponseFromF(tr.data.imaging.F); %#ok<AGROW>
        end
        if ~isempty(responses)
            responseMap(iy, ix) = mean(responses);
            semMap(iy, ix)      = std(responses) / sqrt(numel(responses));
        end
    end
end

summary.offsetsDx   = offsetsDx;
summary.offsetsDy   = offsetsDy;
summary.responseMap = responseMap;
summary.semMap      = semMap;
end

function figPath = savePPSF2DFigure(summary, sessionDir)
fig = figure('Visible', 'off');
imagesc(summary.offsetsDx, summary.offsetsDy, summary.responseMap);
axis image;
colorbar;
xlabel('dx (um)');
ylabel('dy (um)');
title('PPSF 2D map');
figPath = fullfile(sessionDir, 'ppsf2d_heatmap.png');
saveas(fig, figPath);
close(fig);
end
