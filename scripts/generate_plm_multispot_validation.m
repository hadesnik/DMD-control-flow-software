function generate_plm_multispot_validation()
%generate_plm_multispot_validation Generate 50-spot CGH validation patterns.
%
%   Produces three NIR-PLM phase patterns containing 50 diffraction-limited
%   spots each, computed by the Random Superposition (RS) algorithm. For
%   each spot k with target (X_k, Y_k, Z_k) at the sample and a uniform
%   random global phase alpha_k in [0, 2*pi), the per-spot complex field
%   at the PLM plane is
%       E_k(x, y) = exp(1j * (phi_tilt_k + phi_defocus_k + alpha_k))
%   where (x, y) are PLM pixel coordinates in micrometres, centred on the
%   array. The composite continuous phase is angle(sum_k E_k), wrapped and
%   quantized into nPhaseStates levels using the same convention as
%   tfp.hardware.PLM.computeDefocusPattern. Pixels outside the pupil
%   radius are forced to state 0.
%
%   Per-spot phase contributions (paraxial; PLM conjugate to BFP via the
%   M_relay magnification):
%       phi_tilt_k    = (2*pi*n*M_relay / (lambda*f_obj)) * (X_k*x + Y_k*y)
%       phi_defocus_k = pi*n*Z_k*M_relay^2 * (x^2+y^2) / (lambda*f_obj^2)
%
%   Three z-conditions are written:
%       plm_multispot_neg.mat   z_k drawn uniformly from {-150, 0} um
%       plm_multispot_zero.mat  z_k = 0 for all spots
%       plm_multispot_pos.mat   z_k drawn uniformly from {0, +150} um
%
%   Spot xy targets are uniformly distributed in a 200x200 um FOV at the
%   sample with a 30 um exclusion radius around the optical axis (avoids
%   the zero-order block in the relay).
%
%   Outputs (written to data/plm_patterns/validation/):
%       plm_multispot_<cond>.mat    pattern (uint8), targets struct, params
%       plm_multispot_preview.png   per-condition phase + |FFT|^2 montage

    addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

    % ----- PLM geometry & physics constants -----
    % Pulled from MockPLM defaults so the script tracks the device spec
    % in one place.
    plm = tfp.hardware.MockPLM();
    plm.initialize(struct());

    nRows        = plm.nRows;          % 800
    nCols        = plm.nCols;          % 904
    pitchX_um    = plm.pitchX_um;      % 16.2
    pitchY_um    = plm.pitchY_um;      % 10.8
    nPhaseStates = plm.nPhaseStates;   % 32
    lambda_nm    = plm.lambda_nm;      % 1030
    plm.cleanup();
    lambda_um    = lambda_nm / 1000;

    % Optical system (Avocado 10x, 0.6 NA; matches PLM defaults in
    % tfp.hardware.PLM.computeDefocusPattern).
    M_relay  = 2.4;
    n_imm    = 1.33;
    f_obj_um = 16800;
    NA       = 0.6;

    r_PLM_um = (f_obj_um * NA / n_imm) / M_relay;

    % ----- Spot-set parameters -----
    nSpots  = 50;
    fov_um  = 200;     % full width of square xy target region at sample
    excl_um = 30;      % radius around optical axis to exclude
    seed    = 20260521;

    rng(seed, 'twister');

    conds = struct( ...
        'name', {'neg',     'zero', 'pos'    }, ...
        'zSet', {[-150, 0], 0,      [0, 150] });

    % ----- PLM pixel coordinate grid (um, centred) -----
    cx = (nCols + 1) / 2;
    cy = (nRows + 1) / 2;
    [jj, ii] = meshgrid(1:nCols, 1:nRows);
    x_um = (jj - cx) * pitchX_um;
    y_um = (ii - cy) * pitchY_um;
    r2   = x_um.^2 + y_um.^2;
    pupil_mask = r2 <= r_PLM_um^2;

    % Quantization (matches tfp.hardware.PLM.computeDefocusPattern)
    max_phase = 2 * pi * (nPhaseStates - 1) / nPhaseStates;

    % Phase-coefficient prefactors
    K_tilt   = 2*pi * n_imm * M_relay / (lambda_um * f_obj_um);
    K_def    = pi * n_imm * M_relay^2 / (lambda_um * f_obj_um^2);

    % ----- Output directory -----
    repoRoot = fileparts(fileparts(mfilename('fullpath')));
    outDir = fullfile(repoRoot, 'data', 'plm_patterns', 'validation');
    if ~isfolder(outDir)
        mkdir(outDir);
    end

    nConds   = numel(conds);
    patterns = cell(1, nConds);

    for c = 1:nConds
        cond = conds(c);

        % Sample xy uniformly in [-fov/2, fov/2]^2 \ disk(excl_um)
        XY = zeros(nSpots, 2);
        k = 0;
        while k < nSpots
            cand = (rand(1, 2) - 0.5) * fov_um;
            if hypot(cand(1), cand(2)) >= excl_um
                k = k + 1;
                XY(k, :) = cand;
            end
        end

        if isscalar(cond.zSet)
            Z = repmat(cond.zSet, nSpots, 1);
        else
            zIdx = randi(numel(cond.zSet), nSpots, 1);
            Z = cond.zSet(zIdx).';
        end

        alpha = 2*pi * rand(nSpots, 1);

        % Random Superposition: sum per-spot complex fields
        E = complex(zeros(nRows, nCols));
        for k = 1:nSpots
            phi_tilt = K_tilt * (XY(k, 1) * x_um + XY(k, 2) * y_um);
            phi_def  = K_def  * Z(k) * r2;
            E = E + exp(1j * (phi_tilt + phi_def + alpha(k)));
        end

        % Composite phase: wrap to [0, max_phase), mask pupil, quantize
        phi_continuous = angle(E);                        % (-pi, pi]
        phi_wrap = mod(phi_continuous, max_phase);        % [0, max_phase)
        phi_wrap(~pupil_mask) = 0;
        state   = uint8(floor(phi_wrap * nPhaseStates / max_phase));
        pattern = min(state, uint8(nPhaseStates - 1));

        patterns{c} = pattern;

        targets = struct( ...
            'XY_um',     XY, ...
            'Z_um',      Z, ...
            'alpha_rad', alpha);

        params = struct( ...
            'M_relay',      M_relay, ...
            'n_immersion',  n_imm, ...
            'f_obj_um',     f_obj_um, ...
            'NA',           NA, ...
            'lambda_nm',    lambda_nm, ...
            'nPhaseStates', nPhaseStates, ...
            'nRows',        nRows, ...
            'nCols',        nCols, ...
            'pitchX_um',    pitchX_um, ...
            'pitchY_um',    pitchY_um, ...
            'r_PLM_um',     r_PLM_um, ...
            'fov_um',       fov_um, ...
            'excl_um',      excl_um, ...
            'nSpots',       nSpots, ...
            'condition',    cond.name, ...
            'zSet_um',      cond.zSet, ...
            'seed',         seed); %#ok<NASGU>

        outFile = fullfile(outDir, sprintf('plm_multispot_%s.mat', cond.name));
        save(outFile, 'pattern', 'targets', 'params', '-v7');
        fprintf('Saved %s (%d spots, z in %s)\n', ...
                outFile, nSpots, mat2str(cond.zSet));
    end

    % ----- Preview montage: phase + far-field |FFT|^2 per condition -----
    fig = figure('Visible', 'off', 'Position', [100, 100, 1200, 700]);
    for c = 1:nConds
        phi_disp = double(patterns{c}) * (max_phase / nPhaseStates);

        ax1 = subplot(2, nConds, c);
        imagesc(ax1, phi_disp);
        axis(ax1, 'image', 'off');
        colormap(ax1, hsv(256));
        clim(ax1, [0, max_phase]);
        title(ax1, sprintf('Phase (%s)', conds(c).name));

        ax2 = subplot(2, nConds, c + nConds);
        E_pupil = exp(1j * phi_disp);
        E_pupil(~pupil_mask) = 0;
        F = fftshift(fft2(E_pupil));
        I = abs(F).^2;
        floor_I = max(I(:)) * 1e-4;
        imagesc(ax2, log10(I + floor_I));
        axis(ax2, 'image', 'off');
        colormap(ax2, gray(256));
        title(ax2, sprintf('|FFT|^2 log (%s)', conds(c).name));
    end

    previewFile = fullfile(outDir, 'plm_multispot_preview.png');
    exportgraphics(fig, previewFile, 'Resolution', 150);
    close(fig);
    fprintf('Saved preview: %s\n', previewFile);
end
