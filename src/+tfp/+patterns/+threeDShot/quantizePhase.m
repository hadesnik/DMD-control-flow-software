function mask = quantizePhase(phi, params, lut)
%quantizePhase Convert a continuous SLM phase map to an 8-bit drive mask.
%
%   mask = tfp.patterns.threeDShot.quantizePhase(phi, params, lut)
%
%   phi is an (Ny x Nx) double array of SLM phase values (radians, unwrapped).
%   params is the CGH parameter struct from defaultParams (used for Nx/Ny dims
%   but otherwise not needed by the pure linear path; included for API
%   consistency with other CGH functions).
%   lut is either empty/[] (linear mapping) or a 256-element column vector of
%   achieved phase (radians) per drive level 0..255 (a measured phase-LUT from
%   loadPhaseLUT). Returns mask as uint8 (Ny x Nx), values 0..255.
%
%   Linear path (lut empty): wraps phi to [0, 2*pi) then maps linearly to
%   drive levels 0..255.  Non-linear path (lut non-empty): for each pixel the
%   desired wrapped phase is mapped to the nearest achievable drive level via
%   the LUT, supporting devices with non-linear phase response. Pure: no I/O.

% Wrap to [0, 2*pi)
phiWrap = mod(phi, 2*pi);

if isempty(lut)
    % Linear 8-bit quantisation
    mask = uint8(min(round(phiWrap / (2*pi) * 255), 255));
else
    % LUT-based nearest-neighbour mapping
    lut = double(lut(:));           % ensure 256-element column
    drives_all = (0:255)';          % nominal drive values

    % Sort LUT phases so interp1 operates on a monotone table
    [lutSorted, sortIdx] = sort(mod(lut, 2*pi));
    drivesSorted = drives_all(sortIdx);

    % Collapse duplicate phase entries (e.g. drive 0 and 255 both wrap to 0)
    % so interp1's sample points are unique.
    [lutU, iu] = unique(lutSorted);
    drivesU    = drivesSorted(iu);

    if numel(lutU) == 1
        % Degenerate LUT (all drives achieve the same phase): emit that drive.
        mask = uint8(repmat(drivesU, size(phi)));
    else
        % Map each desired phase to the nearest drive via the unique sorted LUT
        mask = uint8(interp1(lutU, drivesU, phiWrap(:), 'nearest', 'extrap'));
        mask = reshape(mask, size(phi));
    end
end
end
