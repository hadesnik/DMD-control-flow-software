function assertLaserPowerSafe(varargin)
%assertLaserPowerSafe Enforce the laser-power safety policy on an ao3 request.
%
%   CHECK form:
%     tfp.util.assertLaserPowerSafe(peakVoltageV, onDurationS, cfg)
%       Evaluates one laser-power request. Returns silently if allowed; throws
%       if denied. peakVoltageV is the peak commanded voltage on the FS-50
%       modulation channel (ao3); onDurationS is the laser-ON duration in
%       seconds (use Inf for a sustained/constant hold). cfg carries the policy.
%
%   OVERRIDE forms (for the supervised power-meter calibration only):
%     tfp.util.assertLaserPowerSafe('overrideOn', reason)  - bypass all checks
%     tfp.util.assertLaserPowerSafe('overrideOff')         - restore checks
%       The override is a session-persistent flag; 'overrideOn' emits a logged
%       warning naming the reason. Use ONLY for powerMeterSweep after the
%       operator has set the FS-50 to a low rep rate (real power stays low).
%
%   POLICY (voltage-based, conservative). %power = 100*(V-off)/(full-off),
%   where full = cfg.fullPowerVoltage (5 V = 100% = 50 W) is the full-rep-rate
%   worst case; at lower FS-50 rep rates the pulse-picker lowers real power, so
%   this voltage map never under-estimates power.
%     - %power <= confirmPct (10%): allowed silently.
%     - %power  > confirmPct: requires confirmation. Interactive -> dialog;
%       non-interactive (matlab -batch, tests) -> ERROR unless
%       cfg.autoConfirmPower is true (then allowed up to the hard cap).
%     - %power  > maxSustainedPct (20%) AND onDurationS >= sustainedDurationS
%       (1 s): HARD BLOCK, even after confirm/autoConfirm. Only an active
%       override bypasses (calibration).
%     - %power  > maxSustainedPct AND onDurationS < sustainedDurationS: a brief
%       burst; allowed after confirmation (it is > confirmPct).
%
%   cfg fields (defaults via the local configField helper):
%     fullPowerVoltage   (5)      offVoltage         (0)
%     confirmPct         (10)     maxSustainedPct    (20)
%     sustainedDurationS (1)      autoConfirmPower   (false)
%
%   Error identifiers:
%     tfp:util:assertLaserPowerSafe:sustainedOverCap  - sustained > hard cap
%     tfp:util:assertLaserPowerSafe:confirmRequired   - headless, >confirm, no opt-in
%     tfp:util:assertLaserPowerSafe:userDenied        - operator declined the dialog
%     tfp:util:assertLaserPowerSafe:badCommand/:badConfig
%
%   See also tfp.util.safetyChecks, tfp.hardware.DAQ.

persistent overrideActive
if isempty(overrideActive)
    overrideActive = false;
end

if nargin < 1
    error('tfp:util:assertLaserPowerSafe:badCommand', ...
        'usage: assertLaserPowerSafe(peakV, onDurationS, cfg) or (''overrideOn''/''overrideOff'').');
end

% --- Override command forms ---------------------------------------------
arg1 = varargin{1};
if ischar(arg1) || (isstring(arg1) && isscalar(arg1))
    switch lower(char(arg1))
        case 'overrideon'
            overrideActive = true;
            if nargin >= 2 && ~isempty(varargin{2})
                reason = char(varargin{2});
            else
                reason = '(no reason given)';
            end
            warning('tfp:util:assertLaserPowerSafe:overrideOn', ...
                'LASER POWER SAFETY OVERRIDE ENABLED: %s', reason);
            return
        case 'overrideoff'
            overrideActive = false;
            return
        otherwise
            error('tfp:util:assertLaserPowerSafe:badCommand', ...
                'unknown command ''%s''; expected ''overrideOn'' or ''overrideOff''.', ...
                char(arg1));
    end
end

% --- Check form ----------------------------------------------------------
if nargin < 2
    error('tfp:util:assertLaserPowerSafe:badCommand', ...
        'check form requires (peakVoltageV, onDurationS, cfg).');
end
peakV       = double(arg1);
onDurationS = double(varargin{2});
if nargin >= 3 && ~isempty(varargin{3})
    cfg = varargin{3};
else
    cfg = struct();
end
if isnan(onDurationS)
    onDurationS = Inf;   % unknown duration -> treat as sustained (conservative)
end

fullV       = double(configField(cfg, 'fullPowerVoltage',   5));
offV        = double(configField(cfg, 'offVoltage',         0));
confirmPct  = double(configField(cfg, 'confirmPct',         10));
maxSustPct  = double(configField(cfg, 'maxSustainedPct',    20));
sustainSec  = double(configField(cfg, 'sustainedDurationS', 1));
autoConfirm = logical(configField(cfg, 'autoConfirmPower',  false));
% Interactive => prompt; non-interactive => block-unless-autoConfirm. Defaults to
% the runtime mode but is overridable (e.g. tests force false to avoid a dialog).
interactive = logical(configField(cfg, 'interactive', ~batchStartupOptionUsed));

% Off (or below the off floor) requests are always safe.
if ~isfinite(peakV) || peakV <= offV
    return
end

% Supervised calibration override bypasses every check.
if overrideActive
    return
end

if ~(fullV > offV)
    error('tfp:util:assertLaserPowerSafe:badConfig', ...
        'fullPowerVoltage (%.4g) must exceed offVoltage (%.4g).', fullV, offV);
end

pct = 100 * (peakV - offV) / (fullV - offV);   % %% of max power (linear)

% --- Hard block: sustained over the cap (no override, no autoConfirm) ---
if pct > maxSustPct && onDurationS >= sustainSec
    error('tfp:util:assertLaserPowerSafe:sustainedOverCap', ...
        ['LASER POWER DENIED: %.1f%% of max (%.4g V on ao3) for %.4g s on-time ' ...
         '(>= %.4g s) exceeds the %.0f%% sustained hard cap. Reduce the power, or ' ...
         'keep the illumination shorter than %.4g s.'], ...
        pct, peakV, onDurationS, sustainSec, maxSustPct, sustainSec);
end

% --- Below the confirm threshold: silent OK ---
if pct <= confirmPct
    return
end

% --- Needs confirmation (pct > confirmPct, not a sustained hard block) ---
msg = sprintf(['Laser power request: %.1f%% of max (%.4g V on ao3), on-time %.4g s. ' ...
    'This exceeds the %.0f%% confirmation threshold.'], ...
    pct, peakV, onDurationS, confirmPct);

if ~interactive   % non-interactive (matlab -batch, tests, or forced)
    if autoConfirm
        warning('tfp:util:assertLaserPowerSafe:autoConfirmed', ...
            '%s (auto-confirmed via autoConfirmPower).', msg);
        return
    end
    error('tfp:util:assertLaserPowerSafe:confirmRequired', ...
        ['%s\nNon-interactive run: set laser.autoConfirmPower=true to permit, ' ...
         'or reduce the request below %.0f%%.'], msg, confirmPct);
end

if ~promptConfirm(msg)
    error('tfp:util:assertLaserPowerSafe:userDenied', ...
        'Laser power request declined by operator (%.1f%% of max).', pct);
end
end

% =========================================================================
function ok = promptConfirm(msg)
%promptConfirm Modal y/n confirmation; GUI dialog if available, else terminal.
question = sprintf('%s\n\nProceed with this laser power?', msg);
if usejava('desktop')
    btn = questdlg(question, 'Confirm laser power', 'Proceed', 'Cancel', 'Cancel');
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
function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
