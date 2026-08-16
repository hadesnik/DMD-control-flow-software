function img = applyLUT(states, lut)
%applyLUT Map quantized phase states through a software lookup table.
%
%   img = tfp.slm.applyLUT(states, lut)
%
%   states: uint8 array of phase-state indices (0..N-1).
%   lut:    [] (identity) or a 1xN / Nx1 numeric vector where
%           lut(k+1) is the device gray value written for state k.
%           N must be >= double(max(states))+1.
%
%   The real wavelength LUT is expected to be loaded ON-DEVICE via the
%   Blink SDK (spec field lutPath); this software hook exists so masks
%   remain correct when the device LUT path is unavailable, and so tests
%   can pin the transform. Identity is the safe default: state == gray.

if isempty(lut)
    img = states;
    return
end
if ~isnumeric(lut) || ~isvector(lut)
    error('tfp:slm:applyLUT:badLut', 'lut must be [] or a numeric vector.');
end
maxState = double(max(states(:)));
if numel(lut) < maxState + 1
    error('tfp:slm:applyLUT:lutTooShort', ...
        'lut has %d entries but states reach %d.', numel(lut), maxState);
end
img = uint8(lut(double(states) + 1));
img = reshape(img, size(states));
end
