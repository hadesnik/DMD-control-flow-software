function params = defaultParams(slmConfig)
%defaultParams Build the 3D-SHOT optical/CGH parameter struct from config.slm.
%
%   params = tfp.patterns.threeDShot.defaultParams(slmConfig)
%
%   slmConfig is the (flat) config.slm struct. Missing fields fall back to
%   documented defaults via the local configField helper, mirroring the
%   convention used by tfp.hardware.PLM.computeDefocusPattern.
%
%   Returned fields (all SI-derived to micrometres / radians):
%     Nx, Ny        SLM dims in pixels (Nx = #cols, Ny = #rows)
%     pitch_um      SLM pixel pitch (µm), assumed square
%     lambda_um     design wavelength (µm), from lambda_nm/1000
%     f_ft_um       effective Fourier/focal length SLM->sample (µm)  %VERIFY
%     mag           SLM-plane -> BFP/sample magnification             %VERIFY
%     n             immersion refractive index
%     diskRadius_um physical TF-disk radius (reconstruction sanity only)
%     gsIters       weighted-GS iteration count
%     gsWeighted    logical, use weighted GS (GSW)
%     gsSeed        RNG seed for reproducibility (unused by the
%                   superposition init, reserved for random init)
%     dx_focal_um   focal-plane sample size = lambda_um*f_ft_um/(Nx*pitch_um);
%                   the single source of truth for µm <-> grating-period.
%
%   Pure: no hardware, no file I/O.

if nargin < 1 || isempty(slmConfig)
    slmConfig = struct();
end

dims          = configField(slmConfig, 'dims', [1024, 1024]);
params.Nx     = double(dims(1));
params.Ny     = double(dims(2));
params.pitch_um = double(configField(slmConfig, 'pitch_um', 17));

lambda_nm        = double(configField(slmConfig, 'lambda_nm', 1030));
params.lambda_um = lambda_nm / 1000;

params.f_ft_um  = double(configField(slmConfig, 'f_ft_um', 16800));
params.mag      = double(configField(slmConfig, 'mag', 1.0));
params.n        = double(configField(slmConfig, 'n', 1.33));

params.diskRadius_um = double(configField(slmConfig, 'diskRadius_um', 5));
params.gsIters       = double(configField(slmConfig, 'gsIters', 20));
params.gsWeighted    = logical(configField(slmConfig, 'gsWeighted', true));
params.gsSeed        = double(configField(slmConfig, 'gsSeed', 0));

params.dx_focal_um = params.lambda_um * params.f_ft_um / (params.Nx * params.pitch_um);
% Row (y) focal-plane sample size. Equals dx_focal_um for a square SLM, but
% differs when Nx ~= Ny; the per-axis values must be used for x/y pixel
% indexing so non-square dims map targets to the correct focal-plane row.
params.dy_focal_um = params.lambda_um * params.f_ft_um / (params.Ny * params.pitch_um);
end

% --- Local helper ---
function value = configField(config, name, default)
if isstruct(config) && isfield(config, name) && ~isempty(config.(name))
    value = config.(name);
else
    value = default;
end
end
