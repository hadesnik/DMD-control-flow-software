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

config = loadOrUseConfig(configOrPath);

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_ppsf_2d', 'sessionName', char(sessionName)));

[dmd, daq] = makeHardware(config);
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = loadCalibrationOrIdentity(config);

% Target cells and 2D offset grid (overridable via config.ppsf2d for tests).
targets = [400, 400; 500, 400; 600, 400];
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
radiusPx  = 5;

sequence = tfp.trial.TrialSequence.generatePPSF( ...
    targets, offsetsUm, nReps, powerMw);

% Attach patternRef per trial: spot at center + 2D offset.
for k = 1:numel(sequence.trials)
    tr         = sequence.trials(k);
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

function config = loadOrUseConfig(configOrPath)
if isstruct(configOrPath)
    config = configOrPath;
elseif ischar(configOrPath) || (isstring(configOrPath) && isscalar(configOrPath))
    config = tfp.io.loadConfig(char(configOrPath));
else
    error('tfp:experiments:exp_ppsf_2d:badConfig', ...
        'configOrPath must be a char/string path or a config struct.');
end
end

function [dmd, daq] = makeHardware(config)
switch lower(char(config.hardwareKind))
    case 'mock'
        dmd = tfp.hardware.MockDMD();
        daq = tfp.hardware.MockDAQ();
    case 'real'
        error('tfp:experiments:exp_ppsf_2d:notImplemented', ...
            'real hardware is Phase 2+.');
    otherwise
        error('tfp:experiments:exp_ppsf_2d:badKind', ...
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
    error('tfp:experiments:exp_ppsf_2d:notImplemented', ...
        'calibration_file loading is Phase 3.');
end
calibration.dmdToSample_affine = eye(3);
calibration.pixelsPerUm        = 1;
calibration.umPerPixel         = 1;
calibration.timestamp          = datetime('now');
calibration.notes              = 'identity fallback (mock)';
end

function cells = buildCells(fakeCellsCfg)
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
% F: nCells x T raw fluorescence. Encoding: F = BASELINE + dFF * BASELINE.
BASELINE = 1000;
dff = (double(F) - BASELINE) / BASELINE;
r   = max(dff(:));
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
            responses(end+1) = tracePeakResponse(tr.data.imaging.F); %#ok<AGROW>
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
