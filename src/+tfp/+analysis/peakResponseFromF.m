function r = peakResponseFromF(F)
%peakResponseFromF Peak dF/F from synthetic fluorescence (BASELINE=1000 encoding).
%
%   r = tfp.analysis.peakResponseFromF(F)
%
%   F is an nCells x T raw-fluorescence matrix produced by the tfp.sim synthetic
%   imaging path, encoded as F = BASELINE + dFF*BASELINE with BASELINE = 1000.
%   Returns the maximum dF/F over all elements.  Shared by the PPSF / axial
%   experiment scripts (which read per-cell synthetic fluorescence).

BASELINE = 1000;
dff = (double(F) - BASELINE) / BASELINE;
r   = max(dff(:));
end
