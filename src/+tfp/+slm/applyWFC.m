function phiOut = applyWFC(phi, wfcMap)
%applyWFC Add a per-device wavefront-correction map to a phase field.
%
%   phiOut = tfp.slm.applyWFC(phi, wfcMap)
%
%   phi:    double(nRows, nCols) phase in RADIANS, pre-wrap.
%   wfcMap: [] (flat, identity) or double(nRows, nCols) phase in radians.
%           Meadowlark ships a WFC image per device; load it with
%           tfp.slm.loadWFC and pass the radians map here. Until the
%           device file is located, [] keeps the correction flat — the
%           mask engine is correct either way, just uncorrected.
%
%   The correction is ADDITIVE and must be applied before wrapping and
%   quantization (tfp.slm.computeDefocusStack does this in the right order).

if isempty(wfcMap)
    phiOut = phi;
    return
end
if ~isnumeric(wfcMap) || ~isequal(size(wfcMap), size(phi))
    error('tfp:slm:applyWFC:badMap', ...
        'wfcMap must be [] or a numeric array matching phi (size [%s]).', ...
        num2str(size(phi)));
end
phiOut = phi + double(wfcMap);
end
