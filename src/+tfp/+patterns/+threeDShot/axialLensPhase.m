function phiAx = axialLensPhase(dz_um, params)
%axialLensPhase Quadratic (Fresnel-lens) SLM phase that defocuses the spot.
%
%   phiAx = tfp.patterns.threeDShot.axialLensPhase(dz_um, params)
%
%   dz_um: axial shift at the sample (µm); +dz pushes the focus deeper.
%   Reuses the paraxial defocus family of tfp.hardware.PLM.computeDefocusPattern:
%       phi(r) = (pi * n * dz * mag^2) / (lambda_um * f_ft_um^2) * r2,
%   with r2 = x_slm^2 + y_slm^2 (µm^2). dz_um == 0 -> flat (zeros).
%
%   The sign convention is %VERIFY on the rig (depends on relay orientation).
%   Returns phiAx (Ny x Nx double, radians), unwrapped. Pure math.

if dz_um == 0
    phiAx = zeros(params.Ny, params.Nx);
    return
end

cx = (params.Nx + 1) / 2;
cy = (params.Ny + 1) / 2;
[jj, ii] = meshgrid(1:params.Nx, 1:params.Ny);
x = (jj - cx) * params.pitch_um;
y = (ii - cy) * params.pitch_um;
r2 = x.^2 + y.^2;

phiAx = (pi * params.n * dz_um * params.mag^2) / ...
        (params.lambda_um * params.f_ft_um^2) .* r2;
end
