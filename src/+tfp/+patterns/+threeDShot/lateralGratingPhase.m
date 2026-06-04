function phiLat = lateralGratingPhase(dx_um, dy_um, params)
%lateralGratingPhase Blazed (linear) SLM phase that shifts the focal spot.
%
%   phiLat = tfp.patterns.threeDShot.lateralGratingPhase(dx_um, dy_um, params)
%
%   A focal-plane shift of (dx_um, dy_um) requires the SLM phase ramp
%       phi(x,y) = 2*pi*( fx*x_slm + fy*y_slm ),
%   with spatial frequencies (cycles/µm at the SLM plane)
%       fx = dx_um / (lambda_um * f_ft_um),  fy = dy_um / (lambda_um * f_ft_um)
%   (Fourier shift theorem; tied to params.dx_focal_um). x_slm/y_slm are the
%   centred physical SLM coordinates in µm.
%
%   Returns phiLat (Ny x Nx double, radians), unwrapped. Pure math.

cx = (params.Nx + 1) / 2;
cy = (params.Ny + 1) / 2;
[jj, ii] = meshgrid(1:params.Nx, 1:params.Ny);
x = (jj - cx) * params.pitch_um;
y = (ii - cy) * params.pitch_um;

fx = dx_um / (params.lambda_um * params.f_ft_um);
fy = dy_um / (params.lambda_um * params.f_ft_um);

phiLat = 2 * pi * (fx .* x + fy .* y);
end
