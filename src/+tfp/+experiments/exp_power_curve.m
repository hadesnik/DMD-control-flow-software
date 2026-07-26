function result = exp_power_curve(configOrPath, sessionName)
%exp_power_curve Run a power-curve session at one mock target.
%
%   Phase 1: 1 hardcoded target, 3 powers, 2 reps = 6 trials.
%
%   SPOT SIZE IS ASKED FOR IN MICRONS (TASK-BU T-BU-2c). The stim spot is
%   specified as a SAMPLE-plane diameter and converted to DMD geometry by
%   tfp.patterns.somaSpotGeometry, which reads the optical constants from
%   tfp.util.opticalModel. Set `config.dmd.spotDiameterUm` to override;
%   omitted, it defaults to the soma-sized 12.7 um.
%
%   Config keys consumed here beyond the usual dmd/daq/paths blocks:
%     dmd.spotDiameterUm - sample-plane stim spot DIAMETER in um. Default []
%                          -> somaSpotGeometry's 12.7 um soma.
%
%   Extra `result` fields: .spotDiameterUm, .spotNPixels, .spotGeometry.

config = tfp.util.loadOrUseConfig(configOrPath, 'exp_power_curve');

sessionDir = fullfile(config.paths.dataDir, char(sessionName));
if ~isfolder(sessionDir), mkdir(sessionDir); end

tfp.io.sessionLog(sessionDir, 'session-start', struct( ...
    'experiment', 'exp_power_curve', 'sessionName', char(sessionName)));

[dmd, daq] = tfp.util.makeHardware(config, 'exp_power_curve');
cleanupHw = onCleanup(@() teardownHardware(dmd, daq)); %#ok<NASGU>

aiSE = []; if isfield(config.daq,'aiSingleEndedChannels'), aiSE = config.daq.aiSingleEndedChannels; end
daq.configureAnalogInput(config.daq.analogInChannels, config.daq.aiRangeV, aiSE);
daq.configureAnalogOutput(config.daq.analogOutChannels);
daq.configureDigitalOutput(config.daq.digitalOutChannels);

target   = [500, 400];
powersMw = [1, 2, 4];
nReps    = 2;

% --- Spot size (TASK-BU T-BU-2c) -----------------------------------------
% This used to read `radiusPx = 15`, a pixel count chosen against the
% pre-optics 0.270 um/px guess. At the real (anisotropic, ~4x larger) sample
% scale an isotropic 15 px circle is a 34 x 42 um blob covering several
% neurons — which would make a "power curve at a target cell" a power curve
% over a small ensemble. Ask in microns instead and let somaSpotGeometry do
% the pixel arithmetic from tfp.util.opticalModel, so the next optics change
% (or a fitted rig affine dropped into the config) updates this by itself.
dmdCfg   = configField(config, 'dmd', struct());
spotGeom = tfp.patterns.somaSpotGeometry( ...
    configField(dmdCfg, 'spotDiameterUm', []), config);   % [] -> 12.7 um soma

tfp.io.sessionLog(sessionDir, 'spot-geometry', struct( ...
    'diameterUm',  spotGeom.diameterUm, ...
    'semiAxesPx',  spotGeom.semiAxesPx, ...
    'nPixels',     spotGeom.nPixels, ...
    'description', spotGeom.description));

sequence = tfp.trial.TrialSequence.generatePowerCurve(target, powersMw, nReps);

if isfield(config, 'bringupMode') && config.bringupMode
    for k = 1:numel(sequence.trials)
        sequence.trials(k).duration_s = 0.1;
        sequence.trials(k).preStim_s  = 0.0;
    end
end

for k = 1:numel(sequence.trials)
    tr = sequence.trials(k);
    % Anisotropic hand-off, done the ONE way that is correct (T-BU-1f):
    % `spotGeom.spotOptions` carries .semiAxisGroovePx, which overrides the
    % positional radius, so the mask is the sample-round ellipse. Passing
    % `spotGeom.radiusPx` (the AREA-MATCHED isotropic fallback) as the
    % positional radius of an anisotropic call instead paints 67 pixels
    % rather than 81 — a silent 17% power deficit. The positional argument
    % below is therefore the groove-axis semi-axis, matching what the
    % options struct asserts.
    tr.targetSpec.patternRef = tfp.patterns.singleSpot( ...
        dmd, target, spotGeom.semiAxisGroovePx, spotGeom.spotOptions);
end

sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
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

summary = summarizeByPower(sequence.trials, powersMw);

tfp.io.sessionLog(sessionDir, 'session-end', struct( ...
    'nTrialsCompleted', nCompleted, 'nTrialsFailed', nFailed));

result.sessionDir       = sessionDir;
result.nTrialsCompleted = nCompleted;
result.nTrialsFailed    = nFailed;
result.summary          = summary;
result.spotDiameterUm   = spotGeom.diameterUm;
result.spotNPixels      = spotGeom.nPixels;
result.spotGeometry     = spotGeom;
if ~isempty(runError)
    result.runError = struct('identifier', runError.identifier, ...
                             'message',    runError.message);
end
end

% --- Local helpers ---

function value = configField(s, name, default)
%configField Read s.(name) with a fallback (repo-wide convention).
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end

function teardownHardware(dmd, daq)
try, daq.cleanup(); catch, end %#ok<CTCH>
try, dmd.cleanup(); catch, end %#ok<CTCH>
end

function summary = summarizeByPower(trials, powersMw)
summary = struct('powerMw', {}, 'meanResponse', {}, 'nTrials', {});
for p = 1:numel(powersMw)
    pw = powersMw(p);
    responses = [];
    for k = 1:numel(trials)
        tr = trials(k);
        if ~strcmp(tr.status, 'complete'), continue; end
        if ~isstruct(tr.data) || ~isfield(tr.data, 'aiData'), continue; end
        if abs(tr.powerMw - pw) > 1e-9, continue; end
        responses(end+1) = tfp.analysis.peakResponseFromAi(tr.data.aiData); %#ok<AGROW>
    end
    summary(p).powerMw = pw;
    if isempty(responses)
        summary(p).meanResponse = NaN;
        summary(p).nTrials      = 0;
    else
        summary(p).meanResponse = mean(responses);
        summary(p).nTrials      = numel(responses);
    end
end
end
