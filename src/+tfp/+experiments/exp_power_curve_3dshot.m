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
%   SPOT SIZE IN THIS ARM IS SET BY THE CGH MODEL, NOT BY THE DMD.
%   This is the SLM comparison arm. The photostim spot the sample actually
%   sees is the 3D-SHOT temporal-focusing disk, sized by
%   `config.slm.diskRadius_um` (see tfp.patterns.threeDShot.defaultParams and
%   the `slm` block of configs/real.yaml) — the grating anisotropy of
%   docs/dmd_control_handoff.md §5 does not apply to it. The DMD frame built
%   below is only a placeholder: the 3D-SHOT benchmark runs behind a manual
%   flip-mirror swap (CLAUDE.md; tasks_3D-SHOT.md Task 6), so the DMD is out
%   of the beam path here and the frame exists purely because
%   tfp.trial.Sequencer requires a `targetSpec.patternRef` to load and
%   advance. See the comment at the `placeholder` block below for why its
%   pixel count was still updated by TASK-BU T-BU-2c.
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
%       slmDiskDiameterUm      the CGH disk DIAMETER at the sample (um) —
%                              THIS is the spot size of this arm
%       placeholderSpotGeometry  geometry of the inert DMD placeholder frame
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

% --- DMD placeholder frame (NOT this arm's stimulation spot) -------------
% INVESTIGATED for TASK-BU T-BU-2c. The old `radiusPx = 15` here was copied
% verbatim from exp_power_curve (tasks_3D-SHOT.md Task 6 spells out the copy),
% and exp_power_curve's own 15 was the pre-optics 0.270 um/px guess. So it is
% NOT an SLM/CGH number that happens to live here — the CGH spot size is
% config.slm.diskRadius_um, consumed by tfp.patterns.threeDShot.defaultParams
% and never by this line. It is a DMD-pixel count that really is written to
% the chip by the Sequencer, so it is sized from somaSpotGeometry like every
% other DMD spot in the repo.
%
% What this does and does not change:
%   - It does NOT change this arm's optical spot size. The flip mirror takes
%     the DMD out of the path for the 3D-SHOT benchmark (%VERIFY on the rig
%     before a combined run), so the frame is optically inert.
%   - It DOES keep the placeholder honest: the frame the DMD holds during an
%     SLM run is now the same soma-sized spot the DMD arm uses, rather than a
%     34 x 42 um relic, and it is smaller (81 vs 709 ON pixels) — the safe
%     direction for the T-BU-1d pupil fill interlock if the mirror is ever
%     left in.
placeholderGeom = tfp.patterns.somaSpotGeometry( ...
    configField(config.dmd, 'spotDiameterUm', []), config);   % [] -> 12.7 um
% Anisotropic hand-off via .spotOptions (T-BU-1f): .semiAxisGroovePx in that
% struct overrides the positional radius. Passing .radiusPx positionally in
% anisotropic mode would silently paint 67 px instead of 81.
placeholderPattern = tfp.patterns.singleSpot( ...
    dmd, dummyTarget, placeholderGeom.semiAxisGroovePx, placeholderGeom.spotOptions);

for k = 1:numel(sequence.trials)
    tr      = sequence.trials(k);
    % Compute which power index this trial corresponds to.
    % Trial k is at (rep-1)*nP + p, so p = mod(k-1, nP) + 1.
    pIdx = mod(k - 1, nP) + 1;
    tr.targetSpec.patternRef = placeholderPattern;
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
% The spot size that matters in this arm is the CGH disk, not the DMD frame.
result.slmDiskDiameterUm        = 2 * double(configField(config.slm, 'diskRadius_um', 5));
result.placeholderSpotGeometry  = placeholderGeom;
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
%configField Read cfg.(name) with a fallback (repo-wide convention).
%   An empty stored value counts as "absent" so that a YAML key left blank
%   (e.g. `spotDiameterUm:`) falls through to the documented default rather
%   than propagating [] into arithmetic.
if isstruct(cfg) && isfield(cfg, name) && ~isempty(cfg.(name))
    value = cfg.(name);
else
    value = default;
end
end
