function curve = normalizePowerCurve(curve, options)
%normalizePowerCurve Migrate any power-curve shape to one versioned schema.
%
%   curve = tfp.calibration.normalizePowerCurve(curve)
%   curve = tfp.calibration.normalizePowerCurve(curve, options)
%
%   TWO CURVES, ONE FIELD NAME. tfp.calibration.powerMeterSweep and
%   tfp.patterns.powerLUT have always answered different questions with
%   colliding names, and nothing reconciled them:
%
%     * the SWEEP measures volts -> mW at ONE fixed ON pattern, and emits a
%       SCALAR .dmdActivePx alongside .voltageV / .powerMw;
%     * powerLUT wants ON-count -> mW at ONE fixed voltage, and expects a
%       VECTOR .dmdActivePx alongside .powerAtSample.
%
%   Feeding one to the other silently produces nonsense, which is why powerLUT
%   has only ever been called from tests. This function is the single place
%   that knows the difference.
%
%   Schema 2:
%     .kind                'power_curve'
%     .schema              2
%     .voltage.voltageV    AO volts, ascending          (volts -> mW branch)
%     .voltage.powerMw     sample-plane power (mW)
%     .voltage.powerStdMw  measurement std dev (mW)
%     .pattern.dmdActivePx ON-mirror counts             (ON-count -> mW branch)
%     .pattern.powerAtSample  sample-plane power (mW)
%     .dmdActivePxAtSweep  scalar ON count held during the volts sweep
%     .fovAreaUm2 .wavelengthNm .timestamp .notes
%     .laserState          operator-entered laser state, [] when unknown
%     ... plus every field of the input, preserved verbatim.
%
%   Disambiguation is structural, never positional: the ON-count branch is
%   recognised by .powerAtSample, the volts branch by .voltageV. A struct
%   carrying both is migrated on both branches. Already-schema-2 input is
%   returned unchanged (idempotent), so this is safe to call on every read.
%
%   options:
%     .laserState   stamp this laser state when the curve carries none
%     .requireBranch  '' (default) | 'voltage' | 'pattern' — throw
%                   :missingBranch when the named branch is absent, so callers
%                   that genuinely need one can fail loudly instead of
%                   interpolating an empty array.
%
%   Throws tfp:calibration:normalizePowerCurve:{badCurve,unrecognizedCurve,
%   missingBranch,inconsistentLengths}.
%
%   See also tfp.calibration.powerMeterSweep, tfp.calibration.powerMeterSweepSingle,
%   tfp.patterns.powerLUT.

if nargin < 2 || isempty(options)
    options = struct();
end
if ~isstruct(curve) || ~isscalar(curve)
    error('tfp:calibration:normalizePowerCurve:badCurve', ...
        'curve must be a scalar struct; got %s.', class(curve));
end

requireBranch = lower(char(tfp.util.configField(options, 'requireBranch', '')));

% --- already schema 2: idempotent ---
if isfield(curve, 'schema') && isnumeric(curve.schema) && curve.schema >= 2
    curve = stampLaserState(curve, options);
    assertBranch(curve, requireBranch);
    return
end

hasPattern = isfield(curve, 'powerAtSample') && ~isempty(curve.powerAtSample);
hasVoltage = isfield(curve, 'voltageV')      && ~isempty(curve.voltageV);

if ~hasPattern && ~hasVoltage
    error('tfp:calibration:normalizePowerCurve:unrecognizedCurve', ...
        ['curve has neither .voltageV (volts -> mW) nor .powerAtSample ' ...
         '(ON-count -> mW), so it cannot be identified as either kind of ' ...
         'power curve. Fields present: %s.'], strjoin(fieldnames(curve)', ', '));
end

% --- volts -> mW branch ---
voltage = struct('voltageV', [], 'powerMw', [], 'powerStdMw', []);
if hasVoltage
    voltage.voltageV = curve.voltageV(:)';
    voltage.powerMw  = getOr(curve, 'powerMw', []);
    voltage.powerMw  = voltage.powerMw(:)';
    voltage.powerStdMw = getOr(curve, 'powerStdMw', []);
    voltage.powerStdMw = voltage.powerStdMw(:)';
    checkLengths(voltage.voltageV, voltage.powerMw, 'voltageV', 'powerMw');
    if ~isempty(voltage.powerStdMw)
        checkLengths(voltage.voltageV, voltage.powerStdMw, 'voltageV', 'powerStdMw');
    end
end

% --- ON-count -> mW branch ---
pattern = struct('dmdActivePx', [], 'powerAtSample', []);
if hasPattern
    pattern.powerAtSample = curve.powerAtSample(:)';
    px = getOr(curve, 'dmdActivePx', []);
    pattern.dmdActivePx = px(:)';
    checkLengths(pattern.dmdActivePx, pattern.powerAtSample, ...
        'dmdActivePx', 'powerAtSample');
end

% --- the scalar ON count held during the volts sweep ---
% A legacy sweep emits .dmdActivePx as a SCALAR. Only claim it as such when the
% ON-count branch has not already claimed the same field as its vector.
dmdActivePxAtSweep = [];
if isfield(curve, 'dmdActivePx') && isscalar(curve.dmdActivePx) && ~hasPattern
    dmdActivePxAtSweep = double(curve.dmdActivePx);
end

curve.kind               = 'power_curve';
curve.schema             = 2;
curve.voltage            = voltage;
curve.pattern            = pattern;
curve.dmdActivePxAtSweep = dmdActivePxAtSweep;
curve                    = defaultField(curve, 'fovAreaUm2',   []);
curve                    = defaultField(curve, 'wavelengthNm', []);
curve                    = defaultField(curve, 'notes',        '');
if ~isfield(curve, 'timestamp'), curve.timestamp = datetime('now'); end

curve = stampLaserState(curve, options);
assertBranch(curve, requireBranch);

end

% ===========================================================================
function curve = stampLaserState(curve, options)
if ~isfield(curve, 'laserState') || isempty(curve.laserState)
    curve.laserState = tfp.util.configField(options, 'laserState', []);
end
end

% ---------------------------------------------------------------------------
function assertBranch(curve, requireBranch)
switch requireBranch
    case ''
        return
    case 'voltage'
        ok = ~isempty(curve.voltage.voltageV) && ~isempty(curve.voltage.powerMw);
    case 'pattern'
        ok = ~isempty(curve.pattern.dmdActivePx) && ~isempty(curve.pattern.powerAtSample);
    otherwise
        error('tfp:calibration:normalizePowerCurve:missingBranch', ...
            'options.requireBranch must be '''', ''voltage'' or ''pattern''.');
end
if ~ok
    error('tfp:calibration:normalizePowerCurve:missingBranch', ...
        ['this power curve has no ''%s'' branch. A volts->mW sweep cannot ' ...
         'answer an ON-count question (or vice versa) — measure the missing ' ...
         'branch rather than interpolating the one you have.'], requireBranch);
end
end

% ---------------------------------------------------------------------------
function checkLengths(a, b, nameA, nameB)
if numel(a) ~= numel(b)
    error('tfp:calibration:normalizePowerCurve:inconsistentLengths', ...
        '%s has %d elements but %s has %d.', nameA, numel(a), nameB, numel(b));
end
end

% ---------------------------------------------------------------------------
function v = getOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end

% ---------------------------------------------------------------------------
function s = defaultField(s, name, default)
if ~isfield(s, name)
    s.(name) = default;
end
end
