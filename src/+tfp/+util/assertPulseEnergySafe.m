function info = assertPulseEnergySafe(patterns, powerMw, laserState, options)
%assertPulseEnergySafe Enforce the DMD relay-pupil air-breakdown interlock.
%
%   info = tfp.util.assertPulseEnergySafe(patterns, powerMw, laserState)
%   info = tfp.util.assertPulseEnergySafe(patterns, powerMw, laserState, options)
%
%   This is the gate that scripts/alignmentField.m and scripts/alpSmokeTest43.m
%   have advertised since 2026-07 as "where that interlock lives". It did not
%   exist until now, so docs/optics_handoff.md's safe_pulse_energy_uJ was
%   unenforced and the "do not run all-ON with the CARBIDE" rule was a comment.
%
%   THE PHYSICS (optics_handoff.md section 7a). Every 4f relay of a collimated
%   DMD forms a real focus at its pupil. With a uniform ON patch the whole
%   pulse lands in one ~33 um spot in air there. At the CARBIDE's full 400 uJ
%   at 100 kHz that is 2.3e14 W/cm^2, ~5x over the ~5e13 W/cm^2 where air
%   ionises for a 205 fs pulse. The interlock sits at L1a's pupil, UPSTREAM of
%   the grating, because every pupil after the grating has the spectrum smeared
%   into a line (~189x longer local pulse), so no post-grating lens swap moves
%   the hazard.
%
%   TWO CHECKS, both gated on the largest CONTIGUOUS ON blob — the same
%   discriminator as tfp.util.assertSlmPowerSafe, and for the same reason: what
%   concentrates light at a pupil is the largest contiguous region, not the
%   total ON count. A frame that is 50% ON as scattered cell-sized targets is
%   orders of magnitude safer than one that is 50% ON as a filled block.
%
%     1. Pulse energy above safe_pulse_energy_uJ (89 uJ) while the largest blob
%        exceeds options.blobFractionFloor -> :pulseEnergyExceeded. This is the
%        handoff's rule stated literally, and it is deliberately conservative
%        for a large solid fill: the handoff says that if a solid alignment
%        target is ever wanted, keep it under 50% AND drop the power.
%     2. Estimated pupil intensity, anchored on the handoff's own table
%        (100% ON at 85 uJ / 100 kHz -> 4.8e13 W/cm^2) and scaling as the
%        SQUARE of the blob fraction:
%            I_pupil = I_ref * (E_pulse / E_ref) * blobFrac^2
%        -> :pupilIntensityNearThreshold (warn) above 0.5x the ~5e13 threshold,
%        -> :pupilIntensityExceeded (error) above 1x.
%
%   POWER REFERENCE — the easiest thing here to get wrong. The volts->mW curve
%   from tfp.calibration.powerMeterSweep* is measured AT THE SAMPLE, but the
%   hazard is at a pupil upstream of everything, so a sample-plane number
%   understates it by the whole arm transmission (~18.2% end to end per the
%   handoff, i.e. ~5.5x). Hence:
%     * options.powerReference = 'sample' (default) divides by
%       options.armTransmission and warns :armTransmissionAssumed whenever
%       that transmission is the unmeasured default.
%     * options.powerReference = 'laser' takes powerMw as already at the laser.
%     * powerMw = [] falls back to laserState.frontPanelPowerW, which is the
%       assumption-free path and the reason the GUI asks the operator to type
%       the front-panel wattage.
%
%   Inputs:
%     patterns   - logical(H,W) or logical(H,W,N) DMD frames. EMPTY IS TREATED
%                  AS ALL-ON (fail-closed): an unknown pattern is not a safe
%                  pattern.
%     powerMw    - commanded power in mW, referenced per options.powerReference;
%                  [] to use laserState.frontPanelPowerW instead.
%     laserState - struct accepted by tfp.util.validateLaserState. Rep rate and
%                  pulse-picker division come from here and are fail-closed.
%     options    - struct, all optional:
%       .powerReference    'sample' (default) | 'laser'
%       .armTransmission   laser -> sample end-to-end fraction; default 0.182
%                          from handoff section 7a %VERIFY — measure it and set
%                          config.laser.arm_transmission
%       .blobFractionFloor blob fraction below which the pulse-energy ceiling
%                          does not apply; default 0.10. NOTE this is
%                          deliberately NOT config.slm.uniform_blob_fraction
%                          (0.02): that constant discriminates alignment-style
%                          patterns at a POST-grating plane where the spectrum
%                          is smeared into a line and the hazard is roughly
%                          binary. Here the hazard is at a PRE-grating pupil
%                          where intensity falls as the SQUARE of the blob
%                          fraction, so it is continuous — and the handoff's own
%                          section 7a table starts at 10% ON. Below this floor
%                          check 2 governs, and below ~10% the CARBIDE cannot
%                          physically reach the breakdown threshold at all
%                          (it would need >10 mJ per pulse against a 400 uJ max).
%       .mode              'error' (default) | 'warn' | 'report'. 'report'
%                          neither throws nor warns — it only fills info, which
%                          is what the confirmation dialog uses to show numbers
%                          without tripping the interlock it is asking about.
%       .label             char prefix for messages; default ''
%
%   Output info struct (every number the dialog displays, so nothing is
%   recomputed downstream):
%     .pulseEnergyUJ .ceilingUJ .marginX .repRateHz
%     .laserPowerMw .powerReference .armTransmission .armTransmissionAssumed
%     .onFraction .largestBlobFraction .blobFractionFloor
%     .pupilIntensityWcm2 .thresholdWcm2 .pupilRefWcm2 .pupilRefPulseUJ
%     .verdict  'ok' | 'caution' | 'unsafe'
%     .warnings cellstr
%
%   Throws tfp:util:assertPulseEnergySafe:{badOptions,badMode,unknownPower,
%   badLaserState,pulseEnergyExceeded,pupilIntensityExceeded}.
%
%   See also tfp.util.assertSlmPowerSafe (the section 7b LC cap),
%   tfp.hardware.DMD.assertPatternsSafe (the 50% ON-fraction cap),
%   tfp.util.validateLaserState.

if nargin < 4 || isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('tfp:util:assertPulseEnergySafe:badOptions', ...
        'options must be a scalar struct; got %s.', class(options));
end

powerReference    = lower(char(tfp.util.configField(options, 'powerReference', 'sample')));
blobFractionFloor = double(tfp.util.configField(options, 'blobFractionFloor', 0.10));
mode              = lower(char(tfp.util.configField(options, 'mode', 'error')));
label             = char(tfp.util.configField(options, 'label', ''));

if ~ismember(mode, {'error', 'warn', 'report'})
    error('tfp:util:assertPulseEnergySafe:badMode', ...
        'options.mode must be ''error'', ''warn'' or ''report''; got ''%s''.', mode);
end
if ~ismember(powerReference, {'sample', 'laser'})
    error('tfp:util:assertPulseEnergySafe:badOptions', ...
        'options.powerReference must be ''sample'' or ''laser''; got ''%s''.', ...
        powerReference);
end

% arm transmission: track whether it is the unmeasured default, because that
% is the difference between a measurement and a guess.
if isfield(options, 'armTransmission') && ~isempty(options.armTransmission)
    armTransmission        = double(options.armTransmission);
    armTransmissionAssumed = false;
    if ~isfinite(armTransmission) || armTransmission <= 0 || armTransmission > 1
        error('tfp:util:assertPulseEnergySafe:badOptions', ...
            'options.armTransmission must be in (0, 1]; got %g.', armTransmission);
    end
else
    armTransmission        = 0.182;   % handoff section 7a "end to end 18.2%" %VERIFY
    armTransmissionAssumed = true;
end

% --- laser state: fail-closed ---
try
    laserState = tfp.util.validateLaserState(laserState);
catch ME
    error('tfp:util:assertPulseEnergySafe:badLaserState', ...
        ['%scannot evaluate the pulse-energy interlock without a valid laser ' ...
         'state (rep rate and pulse-picker division). %s'], prefix(label), ME.message);
end
repRateHz = laserState.effectiveRepRateHz;

% --- resolve the power, at the laser ---
warnings = {};
if isempty(powerMw) || ~isnumeric(powerMw) || ~isscalar(powerMw) || ~isfinite(powerMw)
    if isempty(laserState.frontPanelPowerW)
        error('tfp:util:assertPulseEnergySafe:unknownPower', ...
            ['%spower is unknown: pass powerMw, or enter the laser''s ' ...
             'front-panel average power as laserState.frontPanelPowerW. ' ...
             'This check fails closed rather than assuming a power.'], prefix(label));
    end
    laserPowerMw           = laserState.frontPanelPowerW * 1e3;
    powerReference         = 'laser';
    armTransmissionAssumed = false;   % no conversion applied
elseif strcmp(powerReference, 'laser')
    laserPowerMw = double(powerMw);
else
    laserPowerMw = double(powerMw) / armTransmission;
    if armTransmissionAssumed
        warnings{end+1} = sprintf(['sample-plane power %.1f mW scaled to ' ...
            '%.1f mW at the laser using the UNMEASURED default arm ' ...
            'transmission %.3f. Measure it and set ' ...
            'config.laser.arm_transmission, or enter the front-panel ' ...
            'wattage instead.'], powerMw, laserPowerMw, armTransmission);
        maybeWarn(mode, 'tfp:util:assertPulseEnergySafe:armTransmissionAssumed', ...
            '%s%s', prefix(label), warnings{end});
    end
end

if laserPowerMw < 0
    error('tfp:util:assertPulseEnergySafe:badOptions', ...
        '%spower must be non-negative; got %g mW.', prefix(label), laserPowerMw);
end

% mW -> uJ per pulse: P[mW]*1e-3 / f[Hz] = J, x 1e6 = uJ, i.e. P*1e3/f.
pulseEnergyUJ = laserPowerMw * 1e3 / repRateHz;

% --- pattern geometry ---
[onFraction, blobFraction, blobWarn] = patternFractions(patterns);
if ~isempty(blobWarn)
    warnings{end+1} = blobWarn;
    maybeWarn(mode, 'tfp:util:assertPulseEnergySafe:blobEstimateConservative', ...
        '%s%s', prefix(label), blobWarn);
end

% --- handoff constants (fail-closed on a missing handoff) ---
caps      = tfp.util.readHandoffConstants();
ceilingUJ = caps.safe_pulse_energy_uJ;

% Pupil-intensity anchors. The handoff's section 7a table gives 100% ON at the
% 8.5 W / 100 kHz operating point (85 uJ) as 4.8e13 W/cm^2, against a ~5e13
% W/cm^2 air-breakdown threshold for a 205 fs pulse. Read them from the handoff
% when the optics repo publishes them; until then these literals carry the
% section-7a provenance. %VERIFY - requested for the f7=300 regeneration:
%   pupil_intensity_ref_w_cm2, pupil_intensity_ref_pulse_uJ,
%   pupil_intensity_threshold_w_cm2
pupilRefWcm2    = handoffOr(caps, 'pupil_intensity_ref_w_cm2',       4.8e13);
pupilRefPulseUJ = handoffOr(caps, 'pupil_intensity_ref_pulse_uJ',    85);
thresholdWcm2   = handoffOr(caps, 'pupil_intensity_threshold_w_cm2', 5e13);

% Intensity scales with pulse energy and with the SQUARE of the contiguous ON
% fraction: power rises with the lit area while the DC spot area falls as its
% inverse (handoff section 7a).
pupilIntensityWcm2 = pupilRefWcm2 * (pulseEnergyUJ / pupilRefPulseUJ) * blobFraction^2;

% --- assemble info before any throw, so callers catching the error still get
%     the numbers via the error's own message ---
info = struct( ...
    'pulseEnergyUJ',          pulseEnergyUJ, ...
    'ceilingUJ',              ceilingUJ, ...
    'marginX',                ceilingUJ / max(pulseEnergyUJ, eps), ...
    'repRateHz',              repRateHz, ...
    'laserPowerMw',           laserPowerMw, ...
    'powerReference',         powerReference, ...
    'armTransmission',        armTransmission, ...
    'armTransmissionAssumed', armTransmissionAssumed, ...
    'onFraction',             onFraction, ...
    'largestBlobFraction',    blobFraction, ...
    'blobFractionFloor',      blobFractionFloor, ...
    'pupilIntensityWcm2',     pupilIntensityWcm2, ...
    'thresholdWcm2',          thresholdWcm2, ...
    'pupilRefWcm2',           pupilRefWcm2, ...
    'pupilRefPulseUJ',        pupilRefPulseUJ, ...
    'verdict',                'ok', ...
    'warnings',               {warnings});

% --- check 1: pulse-energy ceiling ---
if pulseEnergyUJ > ceilingUJ && blobFraction > blobFractionFloor
    info.verdict = 'unsafe';
    msg = sprintf(['%s%.1f uJ per pulse (%.1f mW at the laser / %.1f kHz ' ...
        'effective) exceeds the %g uJ relay-pupil ceiling while the largest ' ...
        'contiguous ON blob covers %.1f%% of the chip (> %.1f%%). Air ' ...
        'ionises at the DMD relay pupil (optics_handoff.md section 7a). ' ...
        'Lower the power, raise the rep rate, or break the pattern into ' ...
        'sparse targets.'], ...
        prefix(label), pulseEnergyUJ, laserPowerMw, repRateHz / 1e3, ...
        ceilingUJ, 100 * blobFraction, 100 * blobFractionFloor);
    info.warnings{end+1} = msg;
    raise(mode, 'tfp:util:assertPulseEnergySafe:pulseEnergyExceeded', msg);
    return
end

% --- check 2: pupil intensity ---
if pupilIntensityWcm2 >= thresholdWcm2
    info.verdict = 'unsafe';
    msg = sprintf(['%sestimated relay-pupil intensity %.2e W/cm^2 is at or ' ...
        'above the ~%.0e W/cm^2 air-breakdown threshold (%.1f uJ per pulse, ' ...
        'largest contiguous ON blob %.1f%% of the chip). Intensity goes as ' ...
        'the SQUARE of the blob fraction, so splitting the pattern helps ' ...
        'quadratically.'], ...
        prefix(label), pupilIntensityWcm2, thresholdWcm2, pulseEnergyUJ, ...
        100 * blobFraction);
    info.warnings{end+1} = msg;
    raise(mode, 'tfp:util:assertPulseEnergySafe:pupilIntensityExceeded', msg);
    return
end

if pupilIntensityWcm2 >= 0.5 * thresholdWcm2
    info.verdict = 'caution';
    msg = sprintf(['%sestimated relay-pupil intensity %.2e W/cm^2 is within ' ...
        '2x of the ~%.0e W/cm^2 air-breakdown threshold (%.1f uJ per pulse, ' ...
        'largest blob %.1f%%).'], ...
        prefix(label), pupilIntensityWcm2, thresholdWcm2, pulseEnergyUJ, ...
        100 * blobFraction);
    info.warnings{end+1} = msg;
    maybeWarn(mode, 'tfp:util:assertPulseEnergySafe:pupilIntensityNearThreshold', ...
        '%s', msg);
end

end

% ===========================================================================
% Local helpers
% ===========================================================================

function [onFraction, blobFraction, warnMsg] = patternFractions(patterns)
%patternFractions Worst-case ON fraction and largest contiguous blob fraction.
%   Empty patterns are treated as ALL-ON: an unknown pattern is not safe.
%   Without the Image Processing Toolbox the largest blob is bounded by the
%   total ON count, which is a sound conservative upper bound (a blob can
%   never contain more pixels than are ON).
warnMsg = '';
if isempty(patterns)
    onFraction   = 1;
    blobFraction = 1;
    return
end

pats = logical(patterns);
nPx  = size(pats, 1) * size(pats, 2);

onFraction   = 0;
blobFraction = 0;
haveIpt      = exist('bwconncomp', 'file') == 2;

for k = 1:size(pats, 3)
    frame = pats(:, :, k);
    nOn   = nnz(frame);
    if nOn == 0
        continue
    end
    onFraction = max(onFraction, nOn / nPx);
    if haveIpt
        cc      = bwconncomp(frame);
        biggest = max(cellfun(@numel, cc.PixelIdxList));
    else
        biggest = nOn;   % conservative upper bound
    end
    blobFraction = max(blobFraction, biggest / nPx);
end

if ~haveIpt && blobFraction > 0
    warnMsg = ['Image Processing Toolbox not available: the largest ' ...
        'contiguous ON blob was bounded by the total ON count, which is ' ...
        'conservative (the interlock may trip on a sparse pattern that is ' ...
        'in fact safe).'];
end
end

% ---------------------------------------------------------------------------
function v = handoffOr(caps, key, default)
%handoffOr Read a handoff constant if published, else the documented literal.
if isfield(caps, key) && isnumeric(caps.(key)) && isscalar(caps.(key)) ...
        && isfinite(caps.(key))
    v = caps.(key);
else
    v = default;
end
end

% ---------------------------------------------------------------------------
function raise(mode, id, msg)
%raise Throw, warn, or stay silent, per options.mode.
switch mode
    case 'error'
        error(id, '%s', msg);
    case 'warn'
        warning(id, '%s', msg);
    case 'report'
        % info-only: the confirmation dialog needs the numbers without the
        % interlock firing on the question it is asking.
end
end

% ---------------------------------------------------------------------------
function maybeWarn(mode, id, varargin)
%maybeWarn Warn unless the caller asked for a silent report.
if ~strcmp(mode, 'report')
    warning(id, varargin{:});
end
end

% ---------------------------------------------------------------------------
function p = prefix(label)
if isempty(label)
    p = '';
else
    p = sprintf('[%s] ', label);
end
end
