function calib = calibrateSlmDefocus(dmd, slm, camera, zstage, config, options)
%calibrateSlmDefocus Map SLM defocus commands to physical um (INDIRECT, primary).
%
%   calib = tfp.calibration.calibrateSlmDefocus(dmd, slm, camera, zstage, config)
%   calib = tfp.calibration.calibrateSlmDefocus(..., options)
%
%   The primary z-calibration: no marks, no burning. A single DMD spot is
%   projected onto the thin fluorescent film; for each SLM defocus command
%   the objective z (the MP-285 ruler) is swept through focus and the
%   substage camera finds the stage position where the spot is sharpest
%   (tfp.calibration.throughFocusSweep). Best-focus z vs commanded defocus
%   is fit linearly:
%
%       zPhysUm = slopeUmPerCmd * dzCmdUm + interceptUm
%
%   The SLM defocus command is DEFINED in sample-plane um (the mask
%   formula), so |slope| should be ~1. A fitted slope far from the
%   expectation means m_relay / f_obj / immersion in
%   tfp.optics.buildDefocusSys disagree with the physical bench — the fit
%   is the truth; the expectation is the sanity band (WARNS, never errors,
%   while the optics handoff pre-dates the ratified f7=300 build; see
%   docs/optics_handoff.md "Which build").
%
%   Inputs:
%     dmd     — tfp.hardware.DMD (spot projection)
%     slm     — sequence-capable modulator (tfp.hardware.MockSLM /
%               MeadowlarkSLM), already initialized/connected
%     camera  — tfp.hardware.SubstageCamera, initialized
%     zstage  — tfp.hardware.ZStage, initialized (the common z ruler —
%               calibrateEtlPlanes must use the SAME axis)
%     config  — full config struct (objective/slm sections; powers)
%     options — optional struct:
%       .dzCmdUm         commanded defocus list (default -100:25:100)
%       .spotRadiusPx    DMD spot radius (default 8)
%       .spotCenter      [col row] (default chip centre)
%       .powerMw         calibration power for the safety check (default 5)
%       .zSearchHalfUm   half-range of each through-focus sweep around the
%                        expected best focus (default 30)
%       .zStepUm         sweep step (default 5)
%       .exposureS       DMD exposure per sweep plane (default 0.05)
%       .sweepOptions    struct forwarded to throughFocusSweep
%       .slopeTolFrac    sanity-band fractional tolerance (default 0.3)
%
%   Output calib struct (persist with tfp.io.saveCalibration):
%     .kind = 'slm_defocus', .dzCmdUm, .zPhysUm, .fit (slopeUmPerCmd,
%     interceptUm, r2), .objective, .sweeps (1xN struct), .zRuler,
%     .timestamp, .notes

if nargin < 6 || isempty(options)
    options = struct();
end

dzCmdUm      = double(tfp.util.configField(options, 'dzCmdUm', -100:25:100));
spotRadiusPx = double(tfp.util.configField(options, 'spotRadiusPx', 8));
powerMw      = double(tfp.util.configField(options, 'powerMw', 5));
zHalfUm      = double(tfp.util.configField(options, 'zSearchHalfUm', 30));
zStepUm      = double(tfp.util.configField(options, 'zStepUm', 5));
exposureS    = double(tfp.util.configField(options, 'exposureS', 0.05));
sweepOpts    = tfp.util.configField(options, 'sweepOptions', struct());
slopeTolFrac = double(tfp.util.configField(options, 'slopeTolFrac', 0.3));

if ~slm.supportsDefocusSequence()
    error('tfp:calibration:calibrateSlmDefocus:needsSequenceDevice', ...
        '%s does not support defocus sequences.', class(slm));
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:calibrateSlmDefocus:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera.');
end
if ~isa(zstage, 'tfp.hardware.ZStage')
    error('tfp:calibration:calibrateSlmDefocus:badZStage', ...
        'zstage must be a tfp.hardware.ZStage.');
end

% --- Project the calibration spot -----------------------------------
center = tfp.util.configField(options, 'spotCenter', ...
    [round(dmd.nCols / 2), round(dmd.nRows / 2)]);
pattern = tfp.patterns.singleSpot(dmd, center, spotRadiusPx);

% Safety: LC alignment cap (a single small spot passes trivially, but the
% check belongs on every SLM-in-path illumination path).
tfp.util.assertSlmPowerSafe(pattern, powerMw, config);

seqOpts.exposureUs = round(exposureS * 1e6);
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(pattern, seqOpts);   % assertPatternsSafe inside
dmd.armSequence();
dmd.softTrigger();

% --- Prepare the SLM sequence (dzCmdUm order = sequence order) -------
sys = tfp.optics.buildDefocusSys(config);
slm.prepareDefocusSequence(dzCmdUm, sys);
slm.armSequenceTrigger('software');   % calibration always software-paced

% --- Per-dz through-focus sweeps -------------------------------------
N       = numel(dzCmdUm);
zPhysUm = nan(1, N);
sweeps  = cell(1, N);
z0      = zstage.getPositionUm();   % calibration zero = starting position

for k = 1:N
    slm.advanceToIndex(k);
    % Expected best focus: slope ~ +/-1 => search around both signs by
    % centring the window on z0 + dzCmd and extending by |dzCmd| + half.
    zCenter = z0 + dzCmdUm(k);
    zGrid   = uniqueSorted([ ...
        (zCenter - zHalfUm):zStepUm:(zCenter + zHalfUm), ...
        (z0 - dzCmdUm(k) - zHalfUm):zStepUm:(z0 - dzCmdUm(k) + zHalfUm)]);
    sweep = tfp.calibration.throughFocusSweep(camera, zstage, zGrid, sweepOpts);
    zPhysUm(k) = sweep.bestFocusZUm - z0;   % report relative to start
    sweeps{k}  = sweep;
    fprintf('[calibrateSlmDefocus] dz_cmd %+7.1f um -> best focus %+8.2f um\n', ...
        dzCmdUm(k), zPhysUm(k));
end
zstage.moveToUm(z0);   % leave the stage where we found it

% --- Linear fit -------------------------------------------------------
valid = isfinite(zPhysUm);
if nnz(valid) < 3
    error('tfp:calibration:calibrateSlmDefocus:tooFewPoints', ...
        'Only %d of %d sweeps found focus — cannot fit. Check the film, exposure, and search range.', ...
        nnz(valid), N);
end
p     = polyfit(dzCmdUm(valid), zPhysUm(valid), 1);
zHat  = polyval(p, dzCmdUm(valid));
ssRes = sum((zPhysUm(valid) - zHat).^2);
ssTot = sum((zPhysUm(valid) - mean(zPhysUm(valid))).^2);
r2    = 1 - ssRes / max(ssTot, eps);

% --- Sanity band (warn, never error) ---------------------------------
% dz_cmd is defined in sample um, so |slope| ~ 1 when buildDefocusSys
% matches the bench. Read the handoff for context (fail-closed read).
caps = tfp.util.readHandoffConstants();
expectedMag = 1.0;
if abs(abs(p(1)) - expectedMag) > slopeTolFrac * expectedMag
    warning('tfp:calibration:calibrateSlmDefocus:slopeOutOfBand', ...
        ['Fitted defocus scale %.3f um/um deviates >%.0f%% from the ' ...
         'expected %.2f. Suspects: config.slm.m_relay, objective ' ...
         'selection, immersion. (Handoff rev %g — regenerate the handoff ' ...
         'at the ratified f7=300 build before trusting design bands.) ' ...
         'The FIT is the calibration; this is only a consistency flag.'], ...
        p(1), 100 * slopeTolFrac, expectedMag, caps.handoff_rev);
end

calib.kind      = 'slm_defocus';
calib.dzCmdUm   = dzCmdUm;
calib.zPhysUm   = zPhysUm;
calib.fit       = struct('slopeUmPerCmd', p(1), 'interceptUm', p(2), 'r2', r2);
calib.objective = char(tfp.util.configField( ...
    tfp.util.configField(config, 'objective', struct()), 'name', 'nikon10x045'));
calib.sweeps    = sweeps;
calib.zRuler    = zstage.rulerId();
calib.timestamp = datetime('now');
calib.notes     = sprintf('%d dz points, spot r=%d px @ [%d %d], power %.1f mW', ...
    N, spotRadiusPx, center(1), center(2), powerMw);
end

% --- Local helper ---

function z = uniqueSorted(z)
z = unique(round(z * 1e6) / 1e6);   % dedupe to sub-nm to merge overlap
end
