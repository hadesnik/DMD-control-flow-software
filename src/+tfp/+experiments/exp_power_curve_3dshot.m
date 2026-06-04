function result = exp_power_curve_3dshot(configOrPath, sessionName)
%exp_power_curve_3dshot Run a per-cell power-curve session with SLM holography.
%
%   result = exp_power_curve_3dshot(configOrPath, sessionName)
%
%   Combines the standard power-curve paradigm (multiple power levels, multiple
%   reps per level) with SLM-mediated multi-cell targeting via 3D-SHOT.  The
%   SLM is configured once at session start (via RemoteSLM loopback or msocket),
%   the hologram is projected onto all target cells, and the power sweep is
%   then executed through the DMD/DAQ pipeline exactly as in exp_power_curve.
%
%   Power axis: per-cell powers in mW are divided by the SLM's delivered
%   fraction (eta) to produce the total powers fed to the laser AO channel.
%   Any total-power value that would exceed config.laser.modulation_voltage_max
%   is dropped with a warning.  If all values are dropped the function errors.
%
%   In mock mode (config.hardwareKind = 'mock'):
%     - MockDMD + MockDAQ are used for the trial pipeline.
%     - RemoteSLM in 'loopback' connectionMode wraps a MockSLM internally.
%     - config.mockTargets (N×2) is used as the SI centroid list.
%
%   In real mode (config.hardwareKind = 'real'):
%     - DLP650LNIR_DMD + NI6323_DAQ are used.
%     - RemoteSLM in 'msocket' connectionMode connects to the SLM PC.
%     - SI centroids are received via tfp.io.receiveROIsFromScanImage.
%
%   Inputs:
%     configOrPath - char/string path to a YAML config or a config struct.
%     sessionName  - char/string identifier for this session (used as sub-dir).
%
%   Output:
%     result - struct with fields:
%       sessionDir             path to session directory
%       nTrialsCompleted       count of successfully completed trials
%       nTrialsFailed          count of failed trials
%       perCellPowersMw        1×nP vector of per-cell power levels used
%       nCells                 number of SLM-accepted target cells
%       perCellDeliveredFraction  SLM hologram efficiency (scalar)
%       summary                struct from summarizeByPowerPerCell
%       runError               (optional) struct if the sequencer threw

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_power_curve_3dshot');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_power_curve_3dshot', ...
    'sessionName', char(sessionName)));

% --- Hardware setup --------------------------------------------------------
[dmd, daq] = tfp.util.makeHardware(config, 'exp_power_curve_3dshot');
slm        = tfp.hardware.RemoteSLM(config.slm);
slm.initialize(config.slm);

cleanupHw = onCleanup(@() teardownHardware(dmd, daq, slm)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

% --- Resolve target centroids (SI scan-field µm) --------------------------
if strcmpi(char(config.hardwareKind), 'mock')
    if isfield(config, 'mockTargets') && ~isempty(config.mockTargets)
        siCentroids = double(config.mockTargets);
    else
        % Well-separated default ensemble (>= typical minSpacingUm, within a
        % typical addressableRadiusUm) so a no-mockTargets run still exercises
        % the multi-cell path rather than collapsing to one survivor.
        siCentroids = [0, 0; 40, 0; -40, 0; 0, 40; 0, -40];
    end
else
    roiOpts = struct();
    if isfield(config, 'roi'), roiOpts = config.roi; end
    siCentroids = tfp.io.receiveROIsFromScanImage(roiOpts);
end

% --- Project hologram via SLM --------------------------------------------
slm.slmPower(true);
res = slm.projectTargets(siCentroids);
N   = res.nAccepted;
f   = res.perCellDeliveredFraction;

tfp.io.sessionLog(sessionDir, 'slm-targets-projected', struct( ...
    'n', N, 'fraction', f));

% --- Build power axis, safety-clip ----------------------------------------
perCell     = double(config.powerCurve.perCellPowersMw(:))';   % 1×nP
nReps       = double(config.powerCurve.nReps);
totalPowers = perCell ./ max(f, eps);                          % 1×nP

% NOTE (calibration TODO, %VERIFY on rig): totalPowers are in per-cell-derived
% mW (perCell / f). On the rig these must pass through the laser mW->V power
% calibration before comparison to modulation_voltage_max (volts). Until that
% calibration exists, the Sequencer treats powerMw as a direct voltage, so this
% ceiling is a nominal guard rather than a calibrated power limit.
maxVoltage = configField(config.laser, 'modulation_voltage_max', 5);
keep = totalPowers <= maxVoltage;
if ~all(keep)
    dropIdx = find(~keep);
    warning('tfp:experiments:exp_power_curve_3dshot:powerClipped', ...
        ['%d power level(s) exceed modulation_voltage_max=%.3g and were dropped: ' ...
         'perCellMw = [%s].'], ...
        numel(dropIdx), maxVoltage, num2str(perCell(dropIdx)));
    totalPowers = totalPowers(keep);
    perCell     = perCell(keep);
end
if isempty(totalPowers)
    error('tfp:experiments:exp_power_curve_3dshot:noFeasiblePowers', ...
        'All power levels exceed modulation_voltage_max=%.3g; no feasible powers remain.', ...
        maxVoltage);
end

% --- Build trial sequence -------------------------------------------------
nCols = double(config.dmd.nCols);
nRows = double(config.dmd.nRows);
dummyTarget = [round(nCols/2), round(nRows/2)];    % 1×2 [col row]

sequence = tfp.trial.TrialSequence.generatePowerCurve( ...
    dummyTarget, totalPowers, nReps);

% Annotate each trial: attach pattern + per-cell metadata.
% generatePowerCurve uses rep-outer / power-inner order.
nP     = numel(perCell);
radiusPx = 15;

for k = 1:numel(sequence.trials)
    tr      = sequence.trials(k);
    % Compute which power index this trial corresponds to.
    % Trial k is at (rep-1)*nP + p, so p = mod(k-1, nP) + 1.
    pIdx = mod(k - 1, nP) + 1;
    tr.targetSpec.patternRef = tfp.patterns.singleSpot(dmd, dummyTarget, radiusPx);
    tr.metadata.perCellMw   = perCell(pIdx);
    tr.metadata.slmTargets  = siCentroids;
end

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

% --- Run sequencer ---------------------------------------------------------
% Build mock ScanImage bridge from fakeCells if defined in config.
siBridge = [];
if isfield(config, 'fakeCells') && ~isempty(config.fakeCells)
    siCfg = struct('frameRate', 30, 'simulateLatency', false);
    if isfield(config, 'imaging'), siCfg = config.imaging; end
    cells    = tfp.util.buildCells(config.fakeCells);
    siBridge = tfp.hardware.MockScanImageBridge(cells, siCfg);
end

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

% --- Collect results -------------------------------------------------------
statuses   = {sequence.trials.status};
nCompleted = sum(strcmp(statuses, 'complete'));
nFailed    = sum(strcmp(statuses, 'failed'));

summary = summarizeByPowerPerCell(sequence.trials, perCell, N);

tfp.io.sessionLog(sessionDir, 'session-end', struct( ...
    'nTrialsCompleted', nCompleted, 'nTrialsFailed', nFailed));

result.sessionDir               = sessionDir;
result.nTrialsCompleted         = nCompleted;
result.nTrialsFailed            = nFailed;
result.perCellPowersMw          = perCell;
result.nCells                   = N;
result.perCellDeliveredFraction = f;
result.summary                  = summary;
if ~isempty(runError)
    result.runError = struct('identifier', runError.identifier, ...
                             'message',    runError.message);
end
end

% =========================================================================
% Local helpers
% =========================================================================

function teardownHardware(dmd, daq, slm)
try, slm.blank();        catch, end %#ok<CTCH>
try, slm.slmPower(false); catch, end %#ok<CTCH>
try, slm.cleanup();      catch, end %#ok<CTCH>
try, daq.cleanup();       catch, end %#ok<CTCH>
try, dmd.cleanup();       catch, end %#ok<CTCH>
end

function r = tracePeakResponse(aiCol)
%tracePeakResponse Compute peak ΔF/F from a single AI channel column vector.
%   aiCol: T×1 raw voltage time-series. Uses the first quarter as baseline
%   (matching the exp_power_curve convention). Computed inline rather than via
%   tfp.analysis.onlineDFF: that helper requires a 3-D T×H×W stack, and a single
%   1-pixel trace cannot be represented as 3-D in MATLAB (trailing singleton
%   dimensions collapse), so a per-channel column must be reduced directly.
aiCol     = double(aiCol(:));
T         = numel(aiCol);
nBaseline = max(1, round(T / 4));
F0        = mean(aiCol(1:nBaseline));
if F0 == 0 || ~isfinite(F0)
    r = max(aiCol - F0);            % baseline-subtracted (avoid divide-by-zero)
else
    r = max((aiCol - F0) / F0);     % ΔF/F
end
end

function summary = summarizeByPowerPerCell(trials, perCell, nCells)
%summarizeByPowerPerCell Average peak ΔF/F per cell per power level.
%
%   Iterates over complete trials.  For each trial the per-channel columns
%   of tr.data.aiData are read; each column is treated as one cell's signal.
%   If a trial has fewer channels than nCells, only the available channels
%   are processed (extra positions remain NaN).
%
%   Returns a struct with fields:
%     perCellMw   1×nP double — the per-cell power values in mW
%     response    nCells×nP double — mean peak ΔF/F, NaN where no data
%     nCells      scalar

nP       = numel(perCell);
acc      = NaN(nCells, nP);    % accumulator: sum of responses
counts   = zeros(nCells, nP);  % number of complete reps contributing

for k = 1:numel(trials)
    tr = trials(k);
    if ~strcmp(tr.status, 'complete'), continue; end
    if ~isstruct(tr.data) || ~isfield(tr.data, 'aiData'), continue; end
    if ~isfield(tr.metadata, 'perCellMw'), continue; end

    % Identify the matching power index.
    [~, pIdx] = min(abs(perCell - tr.metadata.perCellMw));
    if isempty(pIdx), continue; end

    aiData   = double(tr.data.aiData);          % T × nChan
    nChanAvail = min(size(aiData, 2), nCells);

    for c = 1:nChanAvail
        col  = aiData(:, c);
        resp = tracePeakResponse(col);
        if isnan(acc(c, pIdx))
            acc(c, pIdx) = resp;
        else
            acc(c, pIdx) = acc(c, pIdx) + resp;
        end
        counts(c, pIdx) = counts(c, pIdx) + 1;
    end
end

% Divide accumulator by counts; leave NaN where counts==0.
response = NaN(nCells, nP);
nonzero  = counts > 0;
response(nonzero) = acc(nonzero) ./ counts(nonzero);

summary.perCellMw = perCell(:)';     % 1×nP
summary.response  = response;        % nCells×nP
summary.nCells    = nCells;
end

% --- Local helper ---

function value = configField(cfg, name, default)
if isstruct(cfg) && isfield(cfg, name)
    value = cfg.(name);
else
    value = default;
end
end
