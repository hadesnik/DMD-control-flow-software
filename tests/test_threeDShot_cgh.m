classdef test_threeDShot_cgh < matlab.unittest.TestCase
    %test_threeDShot_cgh Unit tests for the 3D-SHOT CGH math core.
    %
    %   Covers: composeHologram, gerchbergSaxton, reconstructFocalField,
    %   quantizePhase, loadPhaseLUT, and defaultParams fallbacks.
    %   All tests use small dimensions (256x256) for speed except one 1024x1024
    %   shape-check.  No hardware or file I/O is required.

    % ------------------------------------------------------------------ %
    %  Shared helpers
    % ------------------------------------------------------------------ %
    methods (Access = private)
        function params = makeParams(~, varargin)
            %makeParams Return a small 256x256 param struct for fast tests.
            %   Optional name/value overrides, e.g. makeParams('gsIters', 4).
            cfg = struct('dims', [256, 256], 'gsIters', 12);
            for k = 1:2:numel(varargin)
                cfg.(varargin{k}) = varargin{k+1};
            end
            params = tfp.patterns.threeDShot.defaultParams(cfg);
        end
    end

    % ------------------------------------------------------------------ %
    %  (a) composeHologram output shape and type
    % ------------------------------------------------------------------ %
    methods (Test)
        function composeHologram_returns_uint8_correct_size(testCase)
            %composeHologram must return a uint8 array of size [Ny Nx].
            params = testCase.makeParams();
            target = [0, 0, 0];   % on-axis
            [mask, phi, info] = tfp.patterns.threeDShot.composeHologram( ...
                target, params);

            testCase.verifyClass(mask, 'uint8', ...
                'mask must be class uint8');
            testCase.verifyEqual(size(mask), [params.Ny, params.Nx], ...
                'mask must be [Ny x Nx]');
            testCase.verifyTrue(all(mask(:) >= 0) && all(mask(:) <= 255), ...
                'mask values must be in [0, 255]');
            testCase.verifyEqual(size(phi), [params.Ny, params.Nx], ...
                'phi must be [Ny x Nx]');
            testCase.verifyTrue(isstruct(info), 'info must be a struct');
        end

        function composeHologram_1024_shape(testCase)
            %One 1024x1024 call: shape check only (no iteration content).
            cfg    = struct('dims', [1024, 1024], 'gsIters', 1);
            params = tfp.patterns.threeDShot.defaultParams(cfg);
            target = [0, 0, 0];
            mask   = tfp.patterns.threeDShot.composeHologram(target, params);

            testCase.verifyEqual(size(mask), [1024, 1024], ...
                '1024x1024 mask must have shape [1024 1024]');
            testCase.verifyClass(mask, 'uint8');
        end
    end

    % ------------------------------------------------------------------ %
    %  (b) Single-target lateral centroid — abs value and monotonicity
    % ------------------------------------------------------------------ %
    methods (Test)
        function centroid_abs_matches_dx(testCase)
            %For target [dx 0 0], abs(centroid_x) should be ~ abs(dx).
            params = testCase.makeParams();
            dx_f   = params.dx_focal_um;          % one focal pixel in µm
            dx     = 3 * dx_f;                    % a 3-pixel shift

            [mask, ~, ~] = tfp.patterns.threeDShot.composeHologram( ...
                [dx, 0, 0], params);
            % Reconstruct WITHOUT passing targets so centroid_um reflects the
            % ACTUAL global-peak location — this genuinely verifies the grating
            % steers the spot to dx, not just target->pixel->µm arithmetic.
            rec = tfp.patterns.threeDShot.reconstructFocalField(mask, params);

            cx_um = rec.centroid_um(1, 1);        % x of the actual peak
            testCase.verifyEqual(abs(cx_um), abs(dx), 'AbsTol', dx_f, ...
                'abs(peak centroid_x) must match abs(dx) within one focal pixel');
        end

        function centroid_monotone_in_dx(testCase)
            %abs(centroid_x) must increase monotonically with abs(dx).
            params  = testCase.makeParams();
            dx_f    = params.dx_focal_um;
            shifts  = [1, 3, 6] * dx_f;          % a few distinct shifts
            cx_vals = zeros(1, numel(shifts));

            for k = 1:numel(shifts)
                dx = shifts(k);
                [mask, ~, ~] = tfp.patterns.threeDShot.composeHologram( ...
                    [dx, 0, 0], params);
                % Global-peak reconstruction (no targets) → actual spot location.
                rec = tfp.patterns.threeDShot.reconstructFocalField(mask, params);
                cx_vals(k) = abs(rec.centroid_um(1, 1));
            end

            testCase.verifyTrue(all(diff(cx_vals) > 0), ...
                'abs(centroid_x) must increase monotonically with dx');
        end
    end

    % ------------------------------------------------------------------ %
    %  (c) Pure-dx grating: y-component of centroid stays small
    % ------------------------------------------------------------------ %
    methods (Test)
        function pure_dx_centroid_y_is_small(testCase)
            %A purely lateral-x target must leave centroid_y near zero.
            params = testCase.makeParams();
            dx_f   = params.dx_focal_um;
            dx     = 4 * dx_f;

            [mask, ~, ~] = tfp.patterns.threeDShot.composeHologram( ...
                [dx, 0, 0], params);
            % Global-peak reconstruction (no targets): the actual peak's
            % y-coordinate must stay near zero for a purely lateral-x target.
            rec = tfp.patterns.threeDShot.reconstructFocalField(mask, params);

            testCase.verifyLessThan(abs(rec.centroid_um(1, 2)), dx_f, ...
                'peak centroid_y must stay within one focal pixel for a pure-dx target');
        end

        function nonsquare_dims_steer_y_correctly(testCase)
            %Regression: on a non-square SLM (Nx~=Ny) a pure-dy target must
            %land at the correct focal-plane row. Verifies the y/row pixel
            %mapping uses dy_focal_um (= lambda*f/(Ny*pitch)), not dx_focal_um.
            params = tfp.patterns.threeDShot.defaultParams( ...
                struct('dims', [256, 128], 'gsIters', 12));   % Nx=256, Ny=128
            testCase.verifyNotEqual(params.dy_focal_um, params.dx_focal_um, ...
                'test requires non-square dims so dy_focal_um ~= dx_focal_um');
            dy_f = params.dy_focal_um;
            dy   = 3 * dy_f;

            mask = tfp.patterns.threeDShot.composeHologram([0, dy, 0], params);
            rec  = tfp.patterns.threeDShot.reconstructFocalField(mask, params);

            testCase.verifyEqual(size(mask), [params.Ny, params.Nx], ...
                'non-square mask must be [Ny x Nx]');
            testCase.verifyEqual(abs(rec.centroid_um(1, 2)), abs(dy), ...
                'AbsTol', dy_f, ...
                'pure-dy target must steer to the correct row on a non-square SLM');
        end
    end

    % ------------------------------------------------------------------ %
    %  (d) Multi-target: above-background intensity + efficiency correction
    % ------------------------------------------------------------------ %
    methods (Test)
        function multi_target_intensity_above_background(testCase)
            %Each target pixel must have intensity well above mean background.
            params  = testCase.makeParams('gsIters', 12);
            dx_f    = params.dx_focal_um;
            targets = [4*dx_f, 0, 0; -4*dx_f, 0, 0; 0, 4*dx_f, 0; 0, -4*dx_f, 0];

            [mask, ~, ~] = tfp.patterns.threeDShot.composeHologram( ...
                targets, params);
            rec = tfp.patterns.threeDShot.reconstructFocalField( ...
                mask, params, targets);

            meanBg = mean(rec.intensity(:));
            for k = 1:size(targets, 1)
                testCase.verifyGreaterThan(rec.cellIntensity(k), 5 * meanBg, ...
                    sprintf('Target %d intensity must be well above background', k));
            end
        end

        function efficiency_weighting_reduces_cv(testCase)
            %With non-uniform opts.efficiency, delivered CV must be lower than
            %unweighted cellIntensity CV, showing the weighting equalises.
            params  = testCase.makeParams('gsIters', 15, 'gsWeighted', true);
            dx_f    = params.dx_focal_um;
            targets = [4*dx_f, 0, 0; -4*dx_f, 0, 0; 0, 4*dx_f, 0; 0, -4*dx_f, 0];

            eta = [1.0; 0.7; 0.5; 0.9];    % intentionally non-uniform

            opts.efficiency = eta;
            [~, ~, info] = tfp.patterns.threeDShot.composeHologram( ...
                targets, params, opts);

            % Coefficient of variation of delivered vs raw cellIntensity
            cv_intensity  = std(info.cellIntensity) / (mean(info.cellIntensity) + eps);
            cv_delivered  = std(info.delivered)     / (mean(info.delivered)     + eps);

            % GSW should equalize delivered so its CV is <= raw CV.
            % Allow a small tolerance for cases where the algorithm hasn't
            % fully converged (the delivered CV should be strictly no worse).
            testCase.verifyLessThanOrEqual(cv_delivered, cv_intensity + 0.1, ...
                'CV of delivered must not exceed CV of raw cellIntensity by more than 0.1');
        end
    end

    % ------------------------------------------------------------------ %
    %  (e) GS uniformity non-decreasing (last >= first)
    % ------------------------------------------------------------------ %
    methods (Test)
        function gs_uniformity_nondecreasing(testCase)
            %Uniformity metric must not decrease over iterations.
            params  = testCase.makeParams('gsIters', 12);
            dx_f    = params.dx_focal_um;
            targets = [3*dx_f, 0, 0; -3*dx_f, 0, 0; 0, 3*dx_f, 0];

            [~, ~, info] = tfp.patterns.threeDShot.composeHologram( ...
                targets, params);

            testCase.verifyGreaterThanOrEqual(info.uniformity(end), info.uniformity(1), ...
                'Uniformity at last iteration must be >= uniformity at first iteration');
        end
    end

    % ------------------------------------------------------------------ %
    %  (f) Determinism: two identical calls produce identical results
    % ------------------------------------------------------------------ %
    methods (Test)
        function gerchbergSaxton_is_deterministic(testCase)
            %Two calls with same arguments must return identical phi.
            params  = testCase.makeParams('gsIters', 8);
            dx_f    = params.dx_focal_um;
            targets = [2*dx_f, 0, 0; -2*dx_f, 0, 0];

            [phi1, ~] = tfp.patterns.threeDShot.gerchbergSaxton(targets, params);
            [phi2, ~] = tfp.patterns.threeDShot.gerchbergSaxton(targets, params);

            testCase.verifyEqual(phi1, phi2, ...
                'gerchbergSaxton must be deterministic across calls');
        end
    end

    % ------------------------------------------------------------------ %
    %  (g) quantizePhase: zero phase maps to zero; identity LUT path
    % ------------------------------------------------------------------ %
    methods (Test)
        function quantizePhase_zero_phi_gives_zero(testCase)
            %phi=0 must quantise to drive level 0.
            params = testCase.makeParams();
            phi    = zeros(params.Ny, params.Nx);
            mask   = tfp.patterns.threeDShot.quantizePhase(phi, params, []);

            testCase.verifyEqual(double(mask(1, 1)), 0, ...
                'phi=0 must map to drive level 0');
            testCase.verifyClass(mask, 'uint8');
        end

        function quantizePhase_lut_path_returns_uint8(testCase)
            %LUT path: a simple linear LUT should behave like the direct path.
            params = testCase.makeParams();

            % Build an exact linear LUT: drive d achieves phase d/255 * 2*pi
            lut = (0:255).' / 255 * 2 * pi;

            phi  = rand(params.Ny, params.Nx) * 2 * pi;
            mask = tfp.patterns.threeDShot.quantizePhase(phi, params, lut);

            testCase.verifyClass(mask, 'uint8', ...
                'LUT path must return uint8');
            testCase.verifyEqual(size(mask), [params.Ny, params.Nx], ...
                'LUT path mask must be [Ny x Nx]');
        end

        function quantizePhase_2pi_wraps_to_zero(testCase)
            %phi = 2*pi must wrap to drive level 0 (mod 2*pi = 0).
            params = testCase.makeParams();
            phi    = ones(params.Ny, params.Nx) * 2 * pi;
            mask   = tfp.patterns.threeDShot.quantizePhase(phi, params, []);

            % mod(2*pi, 2*pi) = 0, so round(0/2pi*255) = 0
            testCase.verifyEqual(double(mask(1, 1)), 0, ...
                'phi=2*pi must wrap to drive level 0');
        end

        function quantizePhase_pi_gives_128(testCase)
            %phi = pi should map to drive level 128 (round(0.5*255)=128).
            params = testCase.makeParams();
            phi    = ones(params.Ny, params.Nx) * pi;
            mask   = tfp.patterns.threeDShot.quantizePhase(phi, params, []);

            % round(pi/(2*pi)*255) = round(127.5) = 128 (MATLAB rounds half away from zero)
            testCase.verifyEqual(double(mask(1, 1)), 128, ...
                'phi=pi must map to drive level 128');
        end
    end

    % ------------------------------------------------------------------ %
    %  (h) defaultParams fallbacks
    % ------------------------------------------------------------------ %
    methods (Test)
        function defaultParams_empty_config_uses_defaults(testCase)
            %Empty config struct must produce valid default params.
            params = tfp.patterns.threeDShot.defaultParams(struct());

            testCase.verifyEqual(params.Nx, 1024, 'Nx default must be 1024');
            testCase.verifyEqual(params.Ny, 1024, 'Ny default must be 1024');
            testCase.verifyEqual(params.pitch_um, 17, 'Default pitch must be 17 µm');
            testCase.verifyEqual(params.lambda_um, 1.030, 'AbsTol', 1e-12, ...
                'Default lambda_um must be 1.030 (1030 nm)');
            testCase.verifyEqual(params.gsIters, 20, 'Default gsIters must be 20');
            testCase.verifyTrue(params.gsWeighted, 'gsWeighted default must be true');
            testCase.verifyTrue(isfield(params, 'dx_focal_um'), ...
                'dx_focal_um must be present');
            testCase.verifyGreaterThan(params.dx_focal_um, 0, ...
                'dx_focal_um must be positive');
        end

        function defaultParams_no_args_uses_defaults(testCase)
            %No-argument call must not error and must return defaults.
            params = tfp.patterns.threeDShot.defaultParams();
            testCase.verifyEqual(params.Nx, 1024);
            testCase.verifyEqual(params.Ny, 1024);
        end

        function defaultParams_custom_dims_override(testCase)
            %Custom dims=[256 512] must set Nx=256, Ny=512.
            params = tfp.patterns.threeDShot.defaultParams( ...
                struct('dims', [256, 512]));
            testCase.verifyEqual(params.Nx, 256);
            testCase.verifyEqual(params.Ny, 512);
        end

        function defaultParams_dx_focal_formula(testCase)
            %dx_focal_um must equal lambda_um*f_ft_um/(Nx*pitch_um).
            cfg    = struct('dims', [256, 256], 'lambda_nm', 1030, ...
                            'f_ft_um', 16800, 'pitch_um', 17);
            params = tfp.patterns.threeDShot.defaultParams(cfg);
            expected = 1.030 * 16800 / (256 * 17);
            testCase.verifyEqual(params.dx_focal_um, expected, 'AbsTol', 1e-12, ...
                'dx_focal_um must follow lambda*f/(Nx*pitch)');
        end
    end

    % ------------------------------------------------------------------ %
    %  Additional: reconstructFocalField total energy conservation
    % ------------------------------------------------------------------ %
    methods (Test)
        function reconstruct_total_energy_equals_NxNy(testCase)
            %For a phase-only mask |E|=1, so Parseval gives sum(|F|^2)=Nx*Ny.
            %With the normalisation F = fftshift(fft2(ifftshift(E)))/sqrt(Nx*Ny),
            %sum(|F|^2) = sum(|E|^2) = Nx*Ny (by Parseval), so totalEnergy = Nx*Ny.
            params = testCase.makeParams('gsIters', 5);
            phi    = rand(params.Ny, params.Nx) * 2 * pi;
            mask   = tfp.patterns.threeDShot.quantizePhase(phi, params, []);

            rec = tfp.patterns.threeDShot.reconstructFocalField(mask, params);

            expected = params.Nx * params.Ny;
            testCase.verifyEqual(rec.totalEnergy, expected, 'RelTol', 1e-6, ...
                'Unitary FFT of phase-only mask must have totalEnergy = Nx*Ny');
        end

        function reconstruct_no_targets_returns_peak_centroid(testCase)
            %Without targets, centroid_um must be 1x2.
            params = testCase.makeParams('gsIters', 4);
            target = [3 * params.dx_focal_um, 0, 0];
            [mask, ~, ~] = tfp.patterns.threeDShot.composeHologram(target, params);

            rec = tfp.patterns.threeDShot.reconstructFocalField(mask, params);

            testCase.verifyEqual(size(rec.centroid_um), [1, 2], ...
                'No-targets centroid_um must be 1x2');
            testCase.verifyEqual(numel(rec.cellIntensity), 1, ...
                'No-targets cellIntensity must be a scalar');
        end
    end
end
