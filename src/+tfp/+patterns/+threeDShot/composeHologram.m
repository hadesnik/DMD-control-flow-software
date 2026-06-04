function [mask, phi, info] = composeHologram(targets_xyz_um, params, opts)
%composeHologram Full CGH pipeline: GSW optimisation → phase quantisation.
%
%   [mask, phi, info] = tfp.patterns.threeDShot.composeHologram(targets_xyz_um, params)
%   [mask, phi, info] = tfp.patterns.threeDShot.composeHologram(targets_xyz_um, params, opts)
%
%   Computes an 8-bit SLM drive mask for simultaneously addressing N target
%   foci.  Combines gerchbergSaxton (GSW phase optimisation) and quantizePhase
%   (continuous-phase → uint8 drive level) in one call.
%
%   targets_xyz_um: N x 3 (or N x 2) target coordinates [x y z] in sample
%     micrometres.  N >= 1.
%   params: CGH parameter struct from defaultParams.
%   opts (optional struct):
%     .efficiency   N x 1 relative efficiency weights (see gerchbergSaxton).
%     .phaseInit    Ny x Nx initial phase (see gerchbergSaxton).
%     .lut          256-element phase-LUT vector or [] (see quantizePhase /
%                   loadPhaseLUT).  If absent, treated as [].
%
%   Returns:
%     mask  (Ny x Nx uint8) — 8-bit SLM drive mask, values 0..255.
%     phi   (Ny x Nx double) — optimised continuous phase (radians) before
%           quantisation.
%     info  struct from gerchbergSaxton (see that function for fields).
%
%   Pure: no hardware, no file I/O.

if nargin < 3 || isempty(opts)
    opts = struct();
end

% Run weighted GS
[phi, info] = tfp.patterns.threeDShot.gerchbergSaxton(targets_xyz_um, params, opts);

% Retrieve LUT (may be absent from opts)
if isfield(opts, 'lut')
    lut = opts.lut;
else
    lut = [];
end

% Quantise continuous phase to uint8 drive mask
mask = tfp.patterns.threeDShot.quantizePhase(phi, params, lut);
end
