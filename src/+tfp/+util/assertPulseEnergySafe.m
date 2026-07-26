function info = assertPulseEnergySafe(patternOrFill, commandedVoltageV, cfg)
%assertPulseEnergySafe Pupil pulse-energy interlock for high-fill DMD patterns.
%
%   tfp.util.assertPulseEnergySafe(patternOrFill, commandedVoltageV)
%   tfp.util.assertPulseEnergySafe(patternOrFill, commandedVoltageV, cfg)
%   info = tfp.util.assertPulseEnergySafe(...)
%
%   Returns silently (or with `info`) if the request is allowed; throws if it
%   is denied. Pure function — it touches no hardware and holds no state.
%
%   ======================================================================
%   READ THIS BEFORE "SIMPLIFYING" ANYTHING: THE REP-RATE INVERSION
%   ======================================================================
%   This is the SECOND, INDEPENDENT laser guard. It does NOT replace
%   tfp.util.assertLaserPowerSafe, and assertLaserPowerSafe does not replace
%   it. BOTH MUST RUN. They are conservative in OPPOSITE DIRECTIONS.
%
%     * assertLaserPowerSafe guards AVERAGE POWER on ao3. It justifies its
%       voltage-only model with: "at lower rep rates the pulse-picker lowers
%       real power, so a voltage-based check never UNDER-estimates power."
%       That reasoning is correct — FOR AVERAGE POWER.
%
%     * It is EXACTLY BACKWARDS for this hazard. Pulse energy is
%       E = P_avg / f_rep. At a FIXED average power (fixed ao3 voltage),
%       LOWERING the rep rate RAISES the pulse energy — linearly. The very
%       action that makes the average-power guard more conservative makes
%       this hazard WORSE. A "safe" 0.4 V hold that is 32 uJ/pulse at
%       100 kHz is 320 uJ/pulse at 10 kHz and destroys the relay pupil.
%
%     * Therefore the mitigation here is ALWAYS "RAISE THE REP RATE" (or
%       reduce the fill), and NEVER "raise the pulse energy". There is no
%       voltage you can pick that makes a low rep rate safe for a high-fill
%       pattern without also throwing away the average power you need.
%
%     * The average-power guard is also structurally BLIND to this hazard:
%       it sees only a voltage and a duration. It cannot tell a 2%-fill stim
%       frame from the all-ON alignment frame — and the all-ON alignment
%       frame is precisely the dangerous case. That blindness is why this
%       function exists and why merging the two guards into one
%       reintroduces the hazard.
%
%   ======================================================================
%   THE HAZARD (docs/dmd_control_handoff.md section 7)
%   ======================================================================
%   Every 4f relay of a collimated DMD forms a REAL FOCUS IN AIR at its
%   pupil. With a high-fill ON pattern the whole pulse lands in one ~27 um
%   spot there. At the CARBIDE's full pulse energy that is ~5.9e14 W/cm^2,
%   above where air ionises for a 230 fs pulse.
%
%   Quadratic scaling. The pupil focus is the DC (zero-order) component of
%   the Fourier transform of the DMD field, so its amplitude is proportional
%   to the pattern's spatial MEAN and its PEAK INTENSITY scales with the
%   SQUARE OF THE MEAN:
%
%       I_pupil(fill) / I_pupil(1.0)  ~=  fill^2
%
%   This is why sparse patterns pass easily and why the check is written in
%   terms of fill fraction: a 2% fill is 2500x below a full-field frame, a
%   5% fill is 400x below. Only patterns AT OR ABOVE
%   `pupil_interlock_fill_fraction` (0.2, i.e. >= 25x below full field) are
%   subject to the energy check at all; everything sparser is exempt.
%
%   NOTE the check deliberately does NOT divide the measured pulse energy by
%   fill^2 above the gate. fill^2 is the documented RATIONALE for the gate,
%   not a licence to discount energy. The 68 uJ number is quoted for the
%   dangerous (near-uniform) case, so applying it undiscounted above the
%   gate is the conservative reading. Do not "improve" this by scaling the
%   limit up with 1/fill^2.
%
%   ======================================================================
%   POLICY
%   ======================================================================
%   Average power from the SAME linear voltage map the average-power guard
%   uses (%power = 100*(V-off)/(full-off)):
%
%       P_avg = maxPowerW * (V_peak - offV) / (fullV - offV)
%       E_pulse_uJ = 1e6 * P_avg / repRateHz
%
%   Let `fill` be the governing fill fraction (see below) and
%   `limit` = maxPulseEnergyUjPupil (68 uJ):
%
%     - V_peak <= offV                       : laser off, always safe.
%     - fill < pupilInterlockFillFraction    : exempt (sparse), silent OK.
%     - fill >= gate, E <= confirmFrac*limit : silent OK.
%     - fill >= gate, confirmFrac*limit < E <= limit : requires confirmation.
%       Interactive -> dialog; non-interactive (matlab -batch, tests) ->
%       ERROR unless cfg.autoConfirmPulseEnergy is true (then warns).
%     - fill >= gate, E > limit              : HARD BLOCK. No override, no
%       autoConfirm, no bypass. Unlike assertLaserPowerSafe there is
%       deliberately NO calibration override form here: the powerMeterSweep
%       exception is safe because a low rep rate lowers average power, which
%       is the inversion above — it makes THIS hazard worse, not better.
%
%   ======================================================================
%   GOVERNING FILL FRACTION
%   ======================================================================
%   Only the illuminated patch carries light, so the fill that matters is
%   the fill OF THE PATCH, not of the whole 1280x800 chip: an all-ON design
%   patch is only ~24% of the chip area and would read as fill 0.237 if
%   averaged over the array. This function therefore computes BOTH and takes
%   the LARGER:
%
%       fillArray = mean(pattern(:) ~= 0)                  over the whole array
%       fillPatch = mean over pixels within patchRadiusPx  of patchCenterPx
%       fill      = max(fillArray, fillPatch)
%
%   fillPatch is skipped (and fillArray governs) when the patch disc does not
%   land on the supplied array — e.g. a small cropped test pattern. Patch
%   geometry comes from tfp.util.opticalModel; nothing is hardcoded here.
%
%   ======================================================================
%   INPUTS
%   ======================================================================
%     patternOrFill - EITHER a numeric SCALAR fill fraction in [0, 1],
%                     OR a logical (or 0/1 numeric) pattern H x W,
%                     OR a stack H x W x N. For a stack every slice is
%                     evaluated and the WORST (highest fill) governs; the
%                     error names the offending slice index.
%     commandedVoltageV - commanded voltage on the photostim-laser AO channel
%                     (ao3). A waveform vector is accepted; its PEAK is used.
%     cfg           - config struct. Either a full loaded config (with a
%                     .laser sub-struct) or a bare laser struct. Constants are
%                     read via tfp.util.opticalModel (the single source of
%                     truth) and may be overridden per-call with camelCase
%                     keys. Recognised (snake_case from configs/real.yaml,
%                     camelCase from the DAQ-style struct):
%                       rep_rate_hz                   / repRateHz          (1e5)
%                       max_power_w                   / maxPowerW          (40)
%                       max_pulse_energy_uj_pupil     / maxPulseEnergyUjPupil (68)
%                       pupil_interlock_fill_fraction / pupilInterlockFillFraction (0.2)
%                       modulation_voltage_max        / fullPowerVoltage   (5)
%                       modulation_voltage_min        / offVoltage         (0)
%                       pupil_confirm_fraction        / pupilConfirmFraction (0.5)
%                       autoConfirmPulseEnergy                             (false)
%                       interactive                        (~batchStartupOptionUsed)
%
%   OUTPUT (optional)
%     info - struct describing what was evaluated:
%       .fillFraction        governing fill (the worst slice)
%       .worstIndex          index of the governing slice (1 for a scalar fill)
%       .fillArray/.fillPatch  per-slice fills (.fillPatch NaN if not applied)
%       .patchFillApplied    logical, whether the patch disc was usable
%       .nPatterns           number of slices evaluated
%       .peakVoltageV        peak commanded voltage actually used
%       .avgPowerW           average power implied by that voltage
%       .pulseEnergyUj       E = 1e6 * avgPowerW / repRateHz
%       .limitUj             maxPulseEnergyUjPupil
%       .gateFillFraction    pupilInterlockFillFraction
%       .gated               true if the fill gate engaged the energy check
%       .pupilPeakScale      fill^2 (relative pupil peak vs a full-field frame)
%       .headroomFactor      limitUj / pulseEnergyUj (Inf when laser off)
%       .minSafeRepRateHz    rep rate at which this power lands on the limit
%       .maxSafeVoltageV     voltage at which this rep rate lands on the limit
%
%   ERROR IDENTIFIERS
%     tfp:util:assertPulseEnergySafe:overPupilLimit  - hard block, E > limit
%     tfp:util:assertPulseEnergySafe:confirmRequired - headless, in confirm band
%     tfp:util:assertPulseEnergySafe:userDenied      - operator declined
%     tfp:util:assertPulseEnergySafe:badPattern
%     tfp:util:assertPulseEnergySafe:badFill
%     tfp:util:assertPulseEnergySafe:badCommand
%     tfp:util:assertPulseEnergySafe:badConfig
%
%   See also tfp.util.assertLaserPowerSafe (average power — MUST ALSO RUN),
%            tfp.util.opticalModel, tfp.util.assertPatternInPatch.

if nargin < 2
    error('tfp:util:assertPulseEnergySafe:badCommand', ...
        ['usage: assertPulseEnergySafe(patternOrFill, commandedVoltageV, cfg). ' ...
         'Both a pattern (or fill fraction) AND the commanded ao3 voltage are ' ...
         'required — the hazard is the pairing of the two.']);
end
if nargin < 3 || isempty(cfg)
    cfg = struct();
end
if ~isstruct(cfg)
    error('tfp:util:assertPulseEnergySafe:badConfig', ...
        'cfg must be a struct or empty; got %s.', class(cfg));
end

% --- Constants ----------------------------------------------------------
% opticalModel is the single source of truth for 40 W / 68 uJ / 0.2 / the
% patch geometry. Per-call camelCase overrides sit on top of it so a
% DAQ-style struct or a test can vary one number without a YAML edit.
model    = tfp.util.opticalModel(cfg);
laserCfg = subStruct(cfg, 'laser');

repRateHz = double(configField(laserCfg, 'repRateHz',            model.repRateHz));
maxPowerW = double(configField(laserCfg, 'maxPowerW',            model.maxPowerW));
limitUj   = double(configField(laserCfg, 'maxPulseEnergyUjPupil', model.maxPulseEnergyUjPupil));
gateFill  = double(configField(laserCfg, 'pupilInterlockFillFraction', ...
                                                    model.pupilInterlockFillFraction));

% Voltage map: identical to assertLaserPowerSafe's, deliberately. Accept both
% the YAML snake_case names and the DAQ struct's camelCase names.
fullV = double(configField(laserCfg, 'fullPowerVoltage', ...
                configField(laserCfg, 'modulation_voltage_max', 5)));
offV  = double(configField(laserCfg, 'offVoltage', ...
                configField(laserCfg, 'modulation_voltage_min', 0)));

confirmFrac = double(configField(laserCfg, 'pupilConfirmFraction', ...
                       configField(laserCfg, 'pupil_confirm_fraction', 0.5)));
autoConfirm = logical(configField(laserCfg, 'autoConfirmPulseEnergy', false));
% Interactive => prompt; non-interactive => block-unless-autoConfirm. Defaults
% to the runtime mode but is overridable so tests never open a dialog.
interactive = logical(configField(laserCfg, 'interactive', ~batchStartupOptionUsed));

if ~(fullV > offV)
    error('tfp:util:assertPulseEnergySafe:badConfig', ...
        'fullPowerVoltage (%.4g) must exceed offVoltage (%.4g).', fullV, offV);
end
if ~isfinite(confirmFrac) || confirmFrac < 0 || confirmFrac > 1
    error('tfp:util:assertPulseEnergySafe:badConfig', ...
        'pupilConfirmFraction must be in [0, 1]; got %g.', confirmFrac);
end

% --- Fill fraction(s) ---------------------------------------------------
fills = computeFills(patternOrFill, model);

[govFill, worstIdx] = max(fills.governing);

% --- Peak commanded voltage --------------------------------------------
if ~isnumeric(commandedVoltageV) || isempty(commandedVoltageV) ...
        || ~isreal(commandedVoltageV)
    error('tfp:util:assertPulseEnergySafe:badCommand', ...
        'commandedVoltageV must be a non-empty real numeric scalar or waveform.');
end
v = double(commandedVoltageV(:));
if any(~isfinite(v))
    error('tfp:util:assertPulseEnergySafe:badCommand', ...
        ['commandedVoltageV contains non-finite values. Refusing to guess a ' ...
         'power for a NaN/Inf command — fix the caller.']);
end
peakV = max(v);

% --- Energy -------------------------------------------------------------
avgPowerW     = maxPowerW * (peakV - offV) / (fullV - offV);
avgPowerW     = max(avgPowerW, 0);              % below the off floor = off
pulseEnergyUj = 1e6 * avgPowerW / repRateHz;

info = struct( ...
    'fillFraction',     govFill, ...
    'worstIndex',       worstIdx, ...
    'fillArray',        fills.array, ...
    'fillPatch',        fills.patch, ...
    'patchFillApplied', fills.patchApplied, ...
    'nPatterns',        numel(fills.governing), ...
    'peakVoltageV',     peakV, ...
    'avgPowerW',        avgPowerW, ...
    'pulseEnergyUj',    pulseEnergyUj, ...
    'limitUj',          limitUj, ...
    'gateFillFraction', gateFill, ...
    'gated',            false, ...
    'pupilPeakScale',   govFill^2, ...
    'headroomFactor',   Inf, ...
    'minSafeRepRateHz', 0, ...
    'maxSafeVoltageV',  fullV);

if pulseEnergyUj > 0
    info.headroomFactor   = limitUj / pulseEnergyUj;
    % Rep rate at which this same average power sits exactly on the limit.
    % THIS IS THE REMEDY: raise the rep rate to at least this.
    info.minSafeRepRateHz = 1e6 * avgPowerW / limitUj;
end
% Voltage that, at the CURRENT rep rate, sits exactly on the limit.
info.maxSafeVoltageV = min(fullV, ...
    offV + (fullV - offV) * (limitUj * repRateHz) / (1e6 * maxPowerW));

% --- Laser off is always safe ------------------------------------------
if peakV <= offV
    return
end

% --- Sparse patterns are exempt (fill^2 puts them orders of magnitude down)
if govFill < gateFill
    return
end
info.gated = true;

% --- HARD BLOCK ---------------------------------------------------------
if pulseEnergyUj > limitUj
    error('tfp:util:assertPulseEnergySafe:overPupilLimit', ...
        ['PUPIL PULSE-ENERGY DENIED: pattern %d has fill fraction %.3f ' ...
         '(>= the %.3f interlock fill), and %.4g V on ao3 at %.4g Hz rep rate ' ...
         'gives %.4g W average = %.4g uJ per pulse, which exceeds the %.4g uJ ' ...
         'pupil limit by %.2fx.\n' ...
         'Every 4f relay focuses this pulse into a ~27 um spot in AIR; above ' ...
         'the limit that focus ionises air and damages the relay.\n' ...
         'REMEDY, in order of preference:\n' ...
         '  (1) RAISE THE REP RATE to at least %.4g Hz (pulse energy = ' ...
         'average power / rep rate, so a higher rep rate lowers it at the ' ...
         'same average power). NEVER lower the rep rate to "save power" — ' ...
         'that RAISES pulse energy and makes this worse.\n' ...
         '  (2) Reduce the pattern fill below %.3f (the pupil peak scales as ' ...
         'fill^2, so this drops fast).\n' ...
         '  (3) Reduce the commanded voltage below %.4g V at this rep rate.\n' ...
         'Do NOT raise the pulse-energy limit: %.4g uJ is an air-ionisation ' ...
         'threshold set by the optics and the 230 fs pulse, not a laser spec.'], ...
        worstIdx, govFill, gateFill, peakV, repRateHz, avgPowerW, ...
        pulseEnergyUj, limitUj, pulseEnergyUj / limitUj, ...
        info.minSafeRepRateHz, gateFill, info.maxSafeVoltageV, limitUj);
end

% --- Below the confirmation band: silent OK -----------------------------
if pulseEnergyUj <= confirmFrac * limitUj
    return
end

% --- Confirmation band (within the limit, but close to it) --------------
msg = sprintf(['Pupil pulse-energy request: pattern %d fill %.3f (>= the %.3f ' ...
    'interlock fill), %.4g V on ao3 at %.4g Hz = %.4g uJ per pulse. That is ' ...
    '%.0f%% of the %.4g uJ pupil air-ionisation limit (headroom %.2fx). ' ...
    'Raising the rep rate is the safe direction; lowering it is not.'], ...
    worstIdx, govFill, gateFill, peakV, repRateHz, pulseEnergyUj, ...
    100 * pulseEnergyUj / limitUj, limitUj, info.headroomFactor);

if ~interactive     % matlab -batch, tests, or explicitly forced
    if autoConfirm
        warning('tfp:util:assertPulseEnergySafe:autoConfirmed', ...
            '%s (auto-confirmed via autoConfirmPulseEnergy).', msg);
        return
    end
    error('tfp:util:assertPulseEnergySafe:confirmRequired', ...
        ['%s\nNon-interactive run: set laser.autoConfirmPulseEnergy=true to ' ...
         'permit, or bring the pulse energy below %.4g uJ (raise the rep rate ' ...
         'above %.4g Hz, or reduce the fill below %.3f).'], ...
        msg, confirmFrac * limitUj, ...
        1e6 * avgPowerW / (confirmFrac * limitUj), gateFill);
end

if ~promptConfirm(msg)
    error('tfp:util:assertPulseEnergySafe:userDenied', ...
        ['Pupil pulse-energy request declined by operator ' ...
         '(fill %.3f, %.4g uJ per pulse).'], govFill, pulseEnergyUj);
end
end

% =========================================================================

function fills = computeFills(patternOrFill, model)
%computeFills Governing fill fraction per slice.
%   Returns .array, .patch, .governing (all 1xN) and .patchApplied (logical).
%   A numeric SCALAR is a fill fraction; anything else must be a binary
%   (logical or 0/1 numeric) H x W [x N] pattern.

if isnumeric(patternOrFill) && isscalar(patternOrFill)
    f = double(patternOrFill);
    if ~isfinite(f) || f < 0 || f > 1
        error('tfp:util:assertPulseEnergySafe:badFill', ...
            ['A scalar first argument is a FILL FRACTION and must lie in ' ...
             '[0, 1]; got %g. To pass a pattern, pass a logical H x W [x N] ' ...
             'array.'], f);
    end
    fills = struct('array', f, 'patch', NaN, 'governing', f, ...
        'patchApplied', false);
    return
end

if ~(islogical(patternOrFill) || isnumeric(patternOrFill))
    error('tfp:util:assertPulseEnergySafe:badPattern', ...
        ['patternOrFill must be a scalar fill fraction or a logical/binary ' ...
         'pattern array; got %s.'], class(patternOrFill));
end
if isempty(patternOrFill)
    error('tfp:util:assertPulseEnergySafe:badPattern', ...
        'patternOrFill is empty — nothing to check. Refusing to pass silently.');
end
if ndims(patternOrFill) > 3
    error('tfp:util:assertPulseEnergySafe:badPattern', ...
        'patternOrFill must be H x W or H x W x N; got a %d-D array.', ...
        ndims(patternOrFill));
end
if isnumeric(patternOrFill)
    % A grey-scale array is not a DMD pattern (the chip is binary) and its
    % mean would silently mean something else. Refuse rather than guess.
    vals = double(patternOrFill(:));
    if any(~isfinite(vals)) || any(vals ~= 0 & vals ~= 1)
        error('tfp:util:assertPulseEnergySafe:badPattern', ...
            ['a numeric pattern must be binary (all values 0 or 1) — the DMD ' ...
             'is a binary device. Pass a logical array, or a scalar fill ' ...
             'fraction in [0, 1].']);
    end
end

on = (patternOrFill ~= 0);
[H, W, N] = size(on, 1, 2, 3);
flat = double(reshape(on, H * W, N));

fillArray = mean(flat, 1);

% Patch-restricted fill: only the illuminated patch carries light, so an
% all-ON patch (fill 1 of what is lit) must not be diluted to ~0.237 by the
% dark chip area around it. Uses the same patch geometry as the patch guard.
c = model.patchCenterPx;            % [col row]
r = model.patchRadiusPx;
[cc, rr] = meshgrid(1:W, 1:H);
mask = ((cc - c(1)).^2 + (rr - c(2)).^2) <= r^2;
idx  = find(mask);

if isempty(idx)
    % The patch disc does not land on this array (e.g. a small cropped test
    % pattern). Fall back to the whole-array fill.
    fillPatch    = nan(1, N);
    patchApplied = false;
    governing    = fillArray;
else
    fillPatch    = mean(flat(idx, :), 1);
    patchApplied = true;
    governing    = max(fillArray, fillPatch);
end

fills = struct('array', fillArray, 'patch', fillPatch, ...
    'governing', governing, 'patchApplied', patchApplied);
end

% =========================================================================

function ok = promptConfirm(msg)
%promptConfirm Modal y/n confirmation; GUI dialog if available, else terminal.
question = sprintf('%s\n\nProceed with this pattern at this pulse energy?', msg);
if usejava('desktop')
    btn = questdlg(question, 'Confirm pupil pulse energy', ...
        'Proceed', 'Cancel', 'Cancel');
    ok  = strcmp(btn, 'Proceed');
else
    resp = '';
    while ~any(strcmp(resp, {'y', 'n'}))
        resp = strtrim(lower(input([question ' [y/n]: '], 's')));
    end
    ok = strcmp(resp, 'y');
end
end

% =========================================================================

function s = subStruct(config, name)
%subStruct Return config.(name) if present, else config itself.
%   Lets callers pass either a full loaded config or a bare laser struct.
if isstruct(config) && isfield(config, name) && isstruct(config.(name))
    s = config.(name);
else
    s = config;
end
end

% =========================================================================

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
