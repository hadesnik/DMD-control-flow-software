function spec = validateSpec(spec)
%validateSpec Validate a mask-spec struct (both ends of the msocket link).
%
%   spec = tfp.slm.validateSpec(spec)
%
%   Throws tfp:slm:validateSpec:* on any malformed field so bad specs are
%   rejected before any mask is computed or uploaded. Testable without
%   sockets. Returns the spec unchanged on success.

if ~isstruct(spec)
    error('tfp:slm:validateSpec:notStruct', 'spec must be a struct.');
end

required = {'version', 'dzListUm', 'nRows', 'nCols', 'pitchXUm', ...
            'pitchYUm', 'nStates', 'lambdaNm', 'mRelay', 'nImm', ...
            'fObjUm', 'NA', 'wrapPhaseRad', 'lutPath', 'wfcPath', ...
            'triggerMode'};
for k = 1:numel(required)
    if ~isfield(spec, required{k})
        error('tfp:slm:validateSpec:missingField', ...
            'spec.%s is required.', required{k});
    end
end

% Flat-struct constraint (msocket safety): no field may itself be a struct.
fn = fieldnames(spec);
for k = 1:numel(fn)
    if isstruct(spec.(fn{k}))
        error('tfp:slm:validateSpec:nestedStruct', ...
            'spec.%s is a struct; the wire format must be flat.', fn{k});
    end
end

if ~isnumeric(spec.dzListUm) || ~isvector(spec.dzListUm) || ...
        isempty(spec.dzListUm) || any(~isfinite(spec.dzListUm))
    error('tfp:slm:validateSpec:badDzList', ...
        'spec.dzListUm must be a non-empty finite numeric vector.');
end

scalarPos = {'nRows', 'nCols', 'pitchXUm', 'pitchYUm', 'nStates', ...
             'lambdaNm', 'mRelay', 'nImm', 'fObjUm', 'NA', 'wrapPhaseRad'};
for k = 1:numel(scalarPos)
    v = spec.(scalarPos{k});
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
        error('tfp:slm:validateSpec:badScalar', ...
            'spec.%s must be a positive finite scalar.', scalarPos{k});
    end
end
if spec.nStates ~= round(spec.nStates) || spec.nStates < 2 || spec.nStates > 256
    error('tfp:slm:validateSpec:badNStates', ...
        'spec.nStates must be an integer in 2..256 (got %g).', spec.nStates);
end

if ~ischar(spec.lutPath) || ~ischar(spec.wfcPath)
    error('tfp:slm:validateSpec:badPath', ...
        'spec.lutPath and spec.wfcPath must be char (may be '''').');
end
if ~ischar(spec.triggerMode) || ...
        ~any(strcmp(spec.triggerMode, {'ttl', 'software'}))
    error('tfp:slm:validateSpec:badTriggerMode', ...
        'spec.triggerMode must be ''ttl'' or ''software'' (got ''%s'').', ...
        char(spec.triggerMode));
end
end
