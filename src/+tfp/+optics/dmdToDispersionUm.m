function [xDispUm, yGrooveUm] = dmdToDispersionUm(dmdCoords, dmdSize, constants)
%dmdToDispersionUm Map DMD pixel coords to sample-plane optical-axis um.
%
%   [xDispUm, yGrooveUm] = tfp.optics.dmdToDispersionUm(dmdCoords, dmdSize)
%   [...] = tfp.optics.dmdToDispersionUm(dmdCoords, dmdSize, constants)
%
%   The DMD chip is clocked 45 degrees: the optical dispersion and groove
%   axes are the chip DIAGONALS (docs/optics_handoff.md §5). This is the
%   ONE place that 45-degree mapping lives:
%     d_disp   = (dc + dr) / sqrt(2)
%     d_groove = (dc - dr) / sqrt(2)
%     x_disp   = d_disp   * um_per_px_disp
%     y_groove = d_groove * um_per_px_groove
%   where dc, dr are pixel offsets from the chip centre.
%
%   dmdCoords: Nx2 [col row], 1-indexed, origin top-left.
%   dmdSize:   [nRows nCols] of the chip (e.g. [800 1280]).
%   constants: optional struct from tfp.util.readHandoffConstants()
%              (read fresh when omitted). um_per_px_* are DESIGN INTENT —
%              a fitted calibration supersedes them; this helper is for
%              depth-group assignment where a few-percent scale error is
%              far below the 32.6 um axial FWHM.
%
%   The tilt-induced native excitation depth at a target is then
%     z_native = sign * depth_gradient_um_per_um * x_disp
%   (sign from config.threeD.depth_gradient_sign, resolved on the rig).
%
%   Signs of x_disp/y_groove follow the handoff's unspecified-sign caveat:
%   magnitudes are trustworthy, signs come from bench calibration.

if nargin < 3 || isempty(constants)
    constants = tfp.util.readHandoffConstants();
end
if ~isnumeric(dmdCoords) || size(dmdCoords, 2) ~= 2
    error('tfp:optics:dmdToDispersionUm:badCoords', ...
        'dmdCoords must be Nx2 [col row].');
end
if ~isnumeric(dmdSize) || numel(dmdSize) ~= 2
    error('tfp:optics:dmdToDispersionUm:badSize', ...
        'dmdSize must be [nRows nCols].');
end

umPerPxDisp   = constants.um_per_px_disp;
umPerPxGroove = constants.um_per_px_groove;

cCol = (double(dmdSize(2)) + 1) / 2;
cRow = (double(dmdSize(1)) + 1) / 2;

dc = double(dmdCoords(:, 1)) - cCol;
dr = double(dmdCoords(:, 2)) - cRow;

dDisp   = (dc + dr) / sqrt(2);
dGroove = (dc - dr) / sqrt(2);

xDispUm   = dDisp   * umPerPxDisp;
yGrooveUm = dGroove * umPerPxGroove;
end
