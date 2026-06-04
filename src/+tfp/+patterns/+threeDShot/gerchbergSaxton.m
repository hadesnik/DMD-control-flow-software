function [phi, info] = gerchbergSaxton(targets_xyz_um, params, opts)
%gerchbergSaxton Weighted Gerchberg-Saxton (GSW) hologram optimisation.
%
%   [phi, info] = tfp.patterns.threeDShot.gerchbergSaxton(targets_xyz_um, params)
%   [phi, info] = tfp.patterns.threeDShot.gerchbergSaxton(targets_xyz_um, params, opts)
%
%   Computes an SLM phase mask (Ny x Nx, radians) that simultaneously
%   illuminates all N target foci in the focal plane.  The algorithm is the
%   Weighted Gerchberg-Saxton (GSW) method: per-target amplitude weights are
%   updated each iteration so that each focus receives the amplitude requested
%   via opts.efficiency (equal by default), equalising the delivered intensity
%   distribution across targets.
%
%   targets_xyz_um: N x 2 [x y] or N x 3 [x y z] target coordinates in
%     sample-plane micrometres (z is the axial offset from the focal plane).
%   params: CGH parameter struct from defaultParams.
%   opts (optional struct):
%     .efficiency   N x 1 double in (0,1]; default ones(N,1).  Desired
%                   relative photon-delivery efficiency per target.
%     .phaseInit    Ny x Nx double; initial SLM phase (radians).  If empty
%                   or absent the phase is initialised as the angle of the
%                   coherent superposition of single-target steering phases.
%
%   Returns:
%     phi  (Ny x Nx double, radians) — optimised SLM phase.
%     info struct:
%       .weights                  N x 1 final GSW weights
%       .cellIntensity            N x 1 intensity at each target pixel
%       .delivered                N x 1 eta .* cellIntensity
%       .perCellDeliveredFraction scalar, mean(delivered)/(Nx*Ny)
%       .etaEffective             sum(delivered)/sum(|F|^2)
%       .uniformity               nIters x 1, 1 - std(a)/mean(a) per iter
%       .rms                      nIters x 1, std(a./d) per iter
%       .nIters                   actual iteration count
%       .targetLinIdx             N x 1 linear focal-plane indices
%
%   FFT convention (unitary, centred):
%     F = fftshift(fft2(ifftshift(E))) / sqrt(Nx*Ny)
%   Focal-plane pixel size: params.dx_focal_um; centre at ((Nx+1)/2, (Ny+1)/2).
%
%   Pure: no hardware, no file I/O.

if nargin < 3 || isempty(opts)
    opts = struct();
end

N  = size(targets_xyz_um, 1);
Nx = params.Nx;
Ny = params.Ny;

% --- Desired per-cell amplitude -----------------------------------------
if isfield(opts, 'efficiency') && ~isempty(opts.efficiency)
    eta = double(opts.efficiency(:));
else
    eta = ones(N, 1);
end
d = sqrt(1 ./ eta);
d = d / max(d);   % normalise so max desired amplitude = 1

% --- Focal-plane pixel indices for each target --------------------------
cx = (Nx + 1) / 2;
cy = (Ny + 1) / 2;
dx_f = params.dx_focal_um;

li = zeros(N, 1);
for k = 1:N
    x_k  = targets_xyz_um(k, 1);
    y_k  = targets_xyz_um(k, 2);
    mcol = round(cx + x_k / dx_f);
    nrow = round(cy + y_k / dx_f);
    mcol = max(1, min(Nx, mcol));
    nrow = max(1, min(Ny, nrow));
    li(k) = sub2ind([Ny, Nx], nrow, mcol);
end

% --- Phase initialisation -----------------------------------------------
if isfield(opts, 'phaseInit') && ~isempty(opts.phaseInit)
    phi = double(opts.phaseInit);
else
    % Coherent superposition of analytic single-target steering phases
    accF = complex(zeros(Ny, Nx));
    for k = 1:N
        accF = accF + exp(1i * tfp.patterns.threeDShot.steeringPhase( ...
            targets_xyz_um(k, :), params));
    end
    phi = angle(accF);
end

% --- GSW iterations -----------------------------------------------------
weighted  = params.gsWeighted;
w         = ones(N, 1);
nIter     = max(1, round(params.gsIters));

uniformity_vec = zeros(nIter, 1);
rms_vec        = zeros(nIter, 1);

for it = 1:nIter
    E = exp(1i * phi);
    F = fftshift(fft2(ifftshift(E))) / sqrt(Nx * Ny);

    V = F(li);
    a = abs(V);

    if weighted
        ad  = a ./ d;
        w   = w .* (mean(ad) ./ max(ad, eps));
    end

    % Reconstruct focal plane: keep phase at targets, zero elsewhere
    Ftar        = complex(zeros(Ny, Nx));
    Ftar(li)    = w .* d .* exp(1i * angle(V));

    Enew = fftshift(ifft2(ifftshift(Ftar))) * sqrt(Nx * Ny);
    phi  = angle(Enew);

    uniformity_vec(it) = 1 - std(a) / mean(a);
    rms_vec(it)        = std(a ./ d);
end

% --- Final metrics -------------------------------------------------------
E  = exp(1i * phi);
F  = fftshift(fft2(ifftshift(E))) / sqrt(Nx * Ny);
V  = F(li);

cellIntensity           = abs(V) .^ 2;
delivered               = eta .* cellIntensity;
perCellDeliveredFraction = mean(delivered) / (Nx * Ny);
etaEffective            = sum(delivered) / sum(abs(F(:)) .^ 2);

info = struct( ...
    'weights',                w, ...
    'cellIntensity',          cellIntensity, ...
    'delivered',              delivered, ...
    'perCellDeliveredFraction', perCellDeliveredFraction, ...
    'etaEffective',           etaEffective, ...
    'uniformity',             uniformity_vec(:), ...
    'rms',                    rms_vec(:), ...
    'nIters',                 it, ...
    'targetLinIdx',           li);
end
