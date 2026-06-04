function info = reconstructFocalField(mask, params, targets_xyz_um)
%reconstructFocalField Simulate the focal-plane intensity from an SLM mask.
%
%   info = tfp.patterns.threeDShot.reconstructFocalField(mask, params)
%   info = tfp.patterns.threeDShot.reconstructFocalField(mask, params, targets_xyz_um)
%
%   Given an 8-bit SLM drive mask (uint8, Ny x Nx), reconstructs the
%   simulated focal-plane intensity using the same unitary FFT convention
%   as gerchbergSaxton:
%       phi = double(mask)/255 * 2*pi
%       E   = exp(1i * phi)
%       F   = fftshift(fft2(ifftshift(E))) / sqrt(Nx*Ny)
%       I   = |F|^2
%
%   If targets_xyz_um is supplied (N x 2 or N x 3), the per-target pixel
%   intensities and focal-plane centroids are computed at the corresponding
%   focal-plane pixels.  If omitted, the global intensity peak is used as
%   a single "target" for centroid and peak-intensity reporting.
%
%   mask: uint8 (Ny x Nx) SLM drive mask from composeHologram / quantizePhase.
%   params: CGH parameter struct from defaultParams.
%   targets_xyz_um (optional): N x 2 or N x 3 target coordinates [x y z] in
%     sample micrometres.
%
%   Returns info struct with fields:
%     .intensity     (Ny x Nx double) — focal-plane intensity |F|^2.
%     .totalEnergy   scalar — sum(intensity(:)).
%     .cellIntensity N x 1 double — intensity at each target pixel (or peak
%                    value when no targets given).
%     .centroid_um   N x 2 double — [x_um, y_um] computed centroid offset
%                    from field centre for each target (or global peak when
%                    no targets given).  Units: params.dx_focal_um per pixel.
%
%   Pure: no hardware, no file I/O.

Nx   = params.Nx;
Ny   = params.Ny;
dx_f = params.dx_focal_um;
dy_f = params.dy_focal_um;   % equals dx_f for square SLMs; differs if Nx~=Ny
cx   = (Nx + 1) / 2;
cy   = (Ny + 1) / 2;

% Decode mask to phase and compute focal field
phi = double(mask) / 255 * 2 * pi;
E   = exp(1i * phi);
F   = fftshift(fft2(ifftshift(E))) / sqrt(Nx * Ny);
I   = abs(F) .^ 2;

info.intensity   = I;
info.totalEnergy = sum(I(:));

if nargin >= 3 && ~isempty(targets_xyz_um)
    % Per-target reporting
    N = size(targets_xyz_um, 1);
    li         = zeros(N, 1);
    mcol_all   = zeros(N, 1);
    nrow_all   = zeros(N, 1);

    for k = 1:N
        x_k  = targets_xyz_um(k, 1);
        y_k  = targets_xyz_um(k, 2);
        mcol = round(cx + x_k / dx_f);
        nrow = round(cy + y_k / dy_f);
        mcol = max(1, min(Nx, mcol));
        nrow = max(1, min(Ny, nrow));
        li(k)       = sub2ind([Ny, Nx], nrow, mcol);
        mcol_all(k) = mcol;
        nrow_all(k) = nrow;
    end

    info.cellIntensity = I(li);
    info.centroid_um   = [(mcol_all - cx) * dx_f, (nrow_all - cy) * dy_f];
else
    % Global peak
    [~, peakIdx]  = max(I(:));
    [pr, pc]      = ind2sub([Ny, Nx], peakIdx);
    info.cellIntensity = I(peakIdx);
    info.centroid_um   = [(pc - cx) * dx_f, (pr - cy) * dy_f];
end
end
