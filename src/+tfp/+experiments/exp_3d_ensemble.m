function result = exp_3d_ensemble(configOrPath, sessionName)
%exp_3d_ensemble 3D patterned photostimulation via SLM remote focusing.
%
%   result = tfp.experiments.exp_3d_ensemble(configOrPath, sessionName)
%
%   The 3D mode experiment (optional-flag design: config.threeD.enabled
%   must be true). Targets live in three dimensions — [col row planeIdx
%   zTargetUm] — because the tilted DMD excitation plane (~35 µm walk
%   across the FOV, handoff §6) puts cells of a single DMD FOV into ~3
%   different ETL imaging planes. The sequence factory
%   (TrialSequence.generate3DEnsemble) computes each target's required SLM
%   defocus (dz = zTarget − tilt-native z at its lateral position), bins
%   targets into depth groups, and the Sequencer stimulates group-by-group:
%   advance the SLM (TTL or network, + LC settle), display the group's
%   multiSpot pattern, stimulate, move on. Imaging is ASYNC — ScanImage
%   free-runs n_planes ETL volumes all session; frames are plane-tagged
%   post-hoc from the frame clock (tfp.io.alignTrialsFreeRun).
%
%   Config fields (see configs/bringup_3d.yaml):
%     threeD.enabled / dz_bin_um / depth_gradient_sign / pace_trials
%     slm.*   — backend, geometry, m_relay, trigger mode (makeModulator)
%     etl.n_planes, etl.plane_calibration_file
%     mockTargets3D — Nx4 mock target list (mock path)
%     threeD.nReps, threeD.powerMw, threeD.radiusPx — sweep params
%
%   Real-target path: ROIs arrive plane-tagged over the msocket link
%   (si_send_rois 3D mode -> receiveROIsFromScanImage Nx4), lateral coords
%   map through the composed lateral calibration, depths through the
%   composed z-calibration (composeZCalibration -> etlPlaneZUm).

config = loadOrUseConfig(configOrPath);

if ~isfield(config, 'threeD') || ...
        ~logical(tfp.util.configField(config.threeD, 'enabled', false))
    error('tfp:experiments:exp_3d_ensemble:threeDDisabled', ...
        'config.threeD.enabled must be true for exp_3d_ensemble.');
end

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_3d_ensemble', 'sessionName', char(sessionName)));

[dmd, daq] = makeHardware(config);
slm        = tfp.hardware.makeModulator(config, makeModulatorOpts(config, daq));
cleanupHw  = onCleanup(@() teardownHardware(dmd, daq, slm)); %#ok<NASGU>
if isempty(slm)
    error('tfp:experiments:exp_3d_ensemble:noSlm', ...
        'config.slm.enabled must be true (the SLM does the remote focusing).');
end
if ~slm.supportsDefocusSequence()
    error('tfp:experiments:exp_3d_ensemble:needsSequenceDevice', ...
        '%s cannot run depth-grouped sequences.', class(slm));
end

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

calibration = tfp.io.loadCalibrationOrIdentity(config);
zcal        = loadZCalibration(config);

targets3D = resolveTargets3D(config, calibration, zcal);

% --- Sweep params -----------------------------------------------------
nReps    = double(tfp.util.configField(config.threeD, 'nReps',   2));
powerMw  = double(tfp.util.configField(config.threeD, 'powerMw', 5));
radiusPx = double(tfp.util.configField(config.threeD, 'radiusPx', 15));
dzBinUm  = double(tfp.util.configField(config.threeD, 'dz_bin_um', 10));
gradSign = double(tfp.util.configField(config.threeD, 'depth_gradient_sign', 1));

seqOpts = struct('dmdSize', [dmd.nRows, dmd.nCols], 'dzBinUm', dzBinUm, ...
    'nReps', nReps, 'powerMw', powerMw, 'gradientSign', gradSign);
if ~isempty(zcal)
    seqOpts.planeZUm = zcal.etlPlaneZUm;
end
[sequence, groups] = tfp.trial.TrialSequence.generate3DEnsemble(targets3D, seqOpts);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

% --- Attach per-group DMD patterns (multiSpot union) ------------------
for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    tr.targetSpec.patternRef = tfp.patterns.multiSpot( ...
        dmd, tr.targetSpec.dmdCoords, radiusPx);
end

% --- Prepare + arm the SLM sequence ONCE (group order contract) -------
sys = tfp.optics.buildDefocusSys(config);
slm.prepareDefocusSequence([groups.dzUm], sys);
slm.armSequenceTrigger(char(tfp.util.configField(config.slm, ...
    'trigger_mode', 'software')));

% --- Mock imaging bridge (fakeCells with dmdZUm -> 3D response chain) --
siBridge = [];
if isfield(config, 'fakeCells') && ~isempty(config.fakeCells)
    siCfg = struct('frameRate', 30, 'simulateLatency', false);
    if isfield(config, 'imaging')
        siCfg = config.imaging;
    end
    if ~isempty(zcal)
        siCfg.planeZUm = zcal.etlPlaneZUm;
    end
    cells    = buildCells3D(config.fakeCells);
    siBridge = tfp.hardware.MockScanImageBridge(cells, siCfg);
end

sequencerOpts.slm    = slm;
sequencerOpts.config = config;
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

summary = summarizeByGroup(sequence.trials, numel(groups));

tfp.io.sessionLog(sessionDir, 'session-end', struct( ...
    'nTrialsCompleted', nCompleted, 'nTrialsFailed', nFailed));

result.sessionDir       = sessionDir;
result.nTrialsCompleted = nCompleted;
result.nTrialsFailed    = nFailed;
result.groups           = groups;
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
    error('tfp:experiments:exp_3d_ensemble:badConfig', ...
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
        error('tfp:experiments:exp_3d_ensemble:badKind', ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
if strcmp(lower(char(config.hardwareKind)), 'mock')
    dmd.initialize(config.dmd);
    daq.initialize(config.daq);
end
end

function opts = makeModulatorOpts(config, daq)
%makeModulatorOpts Inject the TTL pulse callable when ttl mode is selected.
opts = struct();
slmCfg = tfp.util.configField(config, 'slm', struct());
if strcmpi(char(tfp.util.configField(slmCfg, 'trigger_mode', 'software')), 'ttl')
    line   = char(tfp.util.configField(slmCfg, 'trigger_line', 'port0/line8'));
    pulseS = double(tfp.util.configField(slmCfg, 'trigger_pulse_s', 2e-4));
    opts.ttlPulseFcn = @() daq.sendDigitalPulse(line, pulseS);
end
end

function teardownHardware(dmd, daq, slm)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
try, if ~isempty(slm), slm.cleanup(); end, catch, end %#ok<CTCH>
end

function zcal = loadZCalibration(config)
%loadZCalibration Load the composed z-calibration, or [] with a warning.
zcal = [];
etlCfg = tfp.util.configField(config, 'etl', struct());
zPath  = char(tfp.util.configField(etlCfg, 'plane_calibration_file', ''));
if ~isempty(zPath)
    zcal = tfp.io.loadCalibration(zPath, 'z_composed');
    return
end
if strcmpi(char(config.hardwareKind), 'real')
    warning('tfp:experiments:exp_3d_ensemble:noZCalibration', ...
        ['etl.plane_calibration_file is empty — target depths fall back ' ...
         'to raw zTargetUm values. Run calibrateSlmDefocus + ' ...
         'calibrateEtlPlanes + composeZCalibration first.']);
end
end

function targets3D = resolveTargets3D(config, calibration, zcal)
%resolveTargets3D Nx4 [col row planeIdx zUm] in DMD pixel coords.
if strcmpi(char(config.hardwareKind), 'mock')
    if isfield(config, 'mockTargets3D') && ~isempty(config.mockTargets3D)
        targets3D = double(config.mockTargets3D);
    else
        % Defaults: depths OPPOSE the tilt-native depth at each lateral
        % position so required defocus values spread across groups.
        targets3D = [400, 400, 3, 15; 640, 400, 2, 0; 900, 400, 1, -15];
    end
    return
end
roiOpts = struct();
if isfield(config, 'roi')
    roiOpts = config.roi;
end
[~, rois] = tfp.io.receiveROIsFromScanImage(roiOpts);
if ~rois.is3D
    error('tfp:experiments:exp_3d_ensemble:need3DROIs', ...
        ['Received a 2D (Nx2) ROI payload — run si_send_rois with the ' ...
         'multi-plane stack configured so ROIs carry plane tags.']);
end
dmdCoords = scanFieldToDMD(rois.centroids, calibration);
zUm = rois.zUm;
if ~isempty(zcal)
    % Authoritative depths come from the composed z-calibration; SI's
    % ETL-uncalibrated zUm is only a fallback.
    valid = isfinite(rois.planeIdx);
    zUm(valid) = zcal.etlPlaneZUm(rois.planeIdx(valid));
end
targets3D = [dmdCoords, rois.planeIdx, zUm];
end

function dmdCoords = scanFieldToDMD(scanCoords, calibration)
scanToDmd = inv(calibration.dmdToScan_affine);
nPts  = size(scanCoords, 1);
pts_h = [scanCoords, ones(nPts, 1)]';
dmd_h = scanToDmd * pts_h;
dmdCoords = dmd_h(1:2, :)';
end

function cells = buildCells3D(fakeCellsCfg)
%buildCells3D CellResponseModel array incl. optional per-cell depth.
nCells = numel(fakeCellsCfg);
cells  = cell(1, nCells);
for k = 1:nCells
    fc   = fakeCellsCfg(k);
    args = {};
    if isfield(fc, 'amplitude'),   args = [args, {'amplitude',   double(fc.amplitude)}]; end %#ok<AGROW>
    if isfield(fc, 'sigma'),       args = [args, {'sigma',       double(fc.sigma)}]; end %#ok<AGROW>
    if isfield(fc, 'aiChannel'),   args = [args, {'aiChannel',   double(fc.aiChannel)}]; end %#ok<AGROW>
    if isfield(fc, 'tag'),         args = [args, {'responseTag', char(fc.tag)}]; end %#ok<AGROW>
    if isfield(fc, 'dmdZUm'),      args = [args, {'positionZUm', double(fc.dmdZUm)}]; end %#ok<AGROW>
    cells{k} = tfp.sim.CellResponseModel( ...
        [double(fc.dmdCol), double(fc.dmdRow)], double(fc.radiusDmd), args{:});
end
end

function r = tracePeakResponse(F)
BASELINE = 1000;
dff = (double(F) - BASELINE) / BASELINE;
r   = max(dff(:));
end

function summary = summarizeByGroup(trials, nGroups)
%summarizeByGroup Peak response per depth group (mirrors summarizeByDz).
summary = struct('groupIdx', {}, 'slmDefocusUm', {}, ...
    'meanResponse', {}, 'nTrials', {});
for g = 1:nGroups
    responses = [];
    dz = NaN;
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data), continue; end
        if tr.metadata.slmGroupIdx ~= g, continue; end
        dz = tr.metadata.slmDefocusUm;
        if ~isfield(tr.data, 'imaging') || isempty(tr.data.imaging) || ...
                ~isfield(tr.data.imaging, 'F')
            continue;
        end
        responses(end+1) = tracePeakResponse(tr.data.imaging.F); %#ok<AGROW>
    end
    summary(g).groupIdx     = g;
    summary(g).slmDefocusUm = dz;
    if isempty(responses)
        summary(g).meanResponse = NaN;
        summary(g).nTrials      = 0;
    else
        summary(g).meanResponse = mean(responses);
        summary(g).nTrials      = numel(responses);
    end
end
end
