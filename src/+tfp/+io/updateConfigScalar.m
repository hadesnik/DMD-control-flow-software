function updateConfigScalar(configPath, section, key, value)
%updateConfigScalar Write a scalar value into a one-level YAML config section.
%
%   tfp.io.updateConfigScalar(configPath, section, key, value)
%
%   The unquoted-scalar sibling of tfp.io.updateConfigCalibrationPath, which
%   only ever wrote single-quoted paths. Needed to close TODO C8: the axis
%   signs resolved by tfp.calibration.verifyScanFieldComposition are +1/-1 and
%   must land in the YAML as numbers, not as the string '+1'.
%
%   value may be numeric, logical or char. Numerics are written with %g,
%   logicals as true/false, char verbatim (so a caller can pass an already
%   formatted scalar). Paths still belong in updateConfigCalibrationPath,
%   which quotes them.
%
%   Both functions delegate to the same private regex machinery, so there is
%   one implementation of "find key inside section" and two value formatters
%   rather than two implementations that drift apart.
%
%   Errors if the section or key is absent: a silent no-op would leave the rig
%   believing it had persisted a calibration result that it had not.
%
%   Throws tfp:io:updateConfigScalar:{fileNotFound,sectionNotFound,keyNotFound,
%   writeFailed,badValue}.
%
%   See also tfp.io.updateConfigCalibrationPath, tfp.io.loadConfig.

if isnumeric(value) && isscalar(value) && isfinite(value)
    formatted = sprintf('%g', value);
elseif islogical(value) && isscalar(value)
    formatted = ternary(value, 'true', 'false');
elseif ischar(value) || isstring(value)
    formatted = char(value);
else
    error('tfp:io:updateConfigScalar:badValue', ...
        ['value must be a finite numeric scalar, a logical scalar, or char; ' ...
         'got %s. Use tfp.io.updateConfigCalibrationPath for file paths.'], ...
        class(value));
end

writeConfigValue(configPath, section, key, formatted, 'updateConfigScalar');
end

% ---------------------------------------------------------------------------
function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end
