classdef PLM < handle
    %PLM Abstract interface for PLM remote-focusing phase modulators.
    %   Subclasses include MockPLM (simulator) and DLPC900_PLM (real TI NIR
    %   PLM via DLPC900 Pre-stored Pattern Mode + I2C trigger). Experiment
    %   code talks to this interface, never to a concrete class.
    %
    %   computeDefocusPattern is implemented here on the base because it
    %   depends only on the abstract pixel-geometry and phase-spec properties
    %   (nRows, nCols, pitchX_um, pitchY_um, nPhaseStates, lambda_nm) that
    %   every subclass must define. Both MockPLM and DLPC900_PLM inherit it
    %   without re-implementing the physics.

    properties (Abstract, SetAccess = protected)
        nRows           % pixel rows (y dimension), e.g. 800
        nCols           % pixel columns (x dimension), e.g. 904
        pitchX_um       % pixel pitch along x (columns), µm; e.g. 16.2
        pitchY_um       % pixel pitch along y (rows), µm; e.g. 10.8
        nPhaseStates    % quantized phase levels, e.g. 32 (5-bit)
        lambda_nm       % design wavelength, nm; e.g. 1030
        isInitialized
    end

    methods (Abstract)
        initialize(obj, config)

        % pattern: uint8(nRows, nCols) with values in 0..nPhaseStates-1
        loadPattern(obj, pattern)

        % Arm DLPC900 TRIG_IN_2 hardware trigger mode via I2C (DLPU018 §2.4)
        configureTrigger(obj)

        % Software-step one pattern (diagnostic only; hardware uses TRIG_IN_2)
        advancePattern(obj)

        status = getStatus(obj)
        cleanup(obj)
    end

    methods
        function pattern = computeDefocusPattern(obj, dz_um, sys)
            %computeDefocusPattern Paraxial defocus phase pattern for remote focusing.
            %   dz_um: axial displacement in µm (positive = focus deeper into sample).
            %   sys:   optional struct; fields and defaults:
            %            .M_relay   = 2.4    relay magnification (PLM plane → BFP)
            %            .n         = 1.33   immersion refractive index (water)
            %            .f_obj_um  = 16800  objective focal length, µm (Avocado 10×)
            %            .NA        = 0.6    objective numerical aperture (Avocado 10×)
            %   Returns uint8(nRows, nCols) with values 0..nPhaseStates-1.
            %
            %   Phase formula (paraxial):
            %     phi(r) = pi * n * dz * M_relay^2 * r^2 / (lambda_um * f_obj_um^2)
            %   where r is the physical radial coordinate at the PLM aperture (µm).
            %
            %   Pupil mask: pixels outside r_PLM = f_obj_um * NA / (n * M_relay) are
            %   set to state 0. Phase is wrapped modulo max_phase = 2*pi*(N-1)/N
            %   (~6.09 rad for N=32), then quantized into N uniform bins.

            if nargin < 3 || isempty(sys)
                sys = struct();
            end

            M_relay   = configField(sys, 'M_relay',  2.4);
            n         = configField(sys, 'n',         1.33);
            f_um      = configField(sys, 'f_obj_um',  16800);
            NA        = configField(sys, 'NA',        0.6);
            lambda_um = obj.lambda_nm / 1000;

            % Pupil radius at the PLM plane (µm); paraxial BFP radius / relay mag
            r_BFP_um = f_um * NA / n;
            r_PLM_um = r_BFP_um / M_relay;

            % Physical pixel coordinates centred on the array (µm)
            cx = (obj.nCols + 1) / 2;
            cy = (obj.nRows + 1) / 2;
            [jj, ii] = meshgrid(1:obj.nCols, 1:obj.nRows);
            x_um = (jj - cx) * obj.pitchX_um;
            y_um = (ii - cy) * obj.pitchY_um;
            r2   = x_um.^2 + y_um.^2;          % squared radial distance, µm^2

            % Paraxial defocus phase (radians)
            phi = (pi * n * dz_um * M_relay^2) / (lambda_um * f_um^2) * r2;

            % max_phase: full-scale phase for nPhaseStates states
            %   max piston = lambda/2 * (nPhaseStates-1)/nPhaseStates
            %   max OPD    = 2 * max_piston = lambda * (nPhaseStates-1)/nPhaseStates
            %   max_phase  = 2*pi * max_OPD / lambda = 2*pi*(N-1)/N
            max_phase = 2 * pi * (obj.nPhaseStates - 1) / obj.nPhaseStates;

            phi_wrap = mod(phi, max_phase);

            % Pixels outside the pupil are set to flat (state 0)
            phi_wrap(r2 > r_PLM_um^2) = 0;

            state   = uint8(floor(phi_wrap * obj.nPhaseStates / max_phase));
            pattern = min(state, uint8(obj.nPhaseStates - 1));  % clamp numerical edge
        end

        function [patterns, dz_um, sys] = generatePatternLibrary(obj, n_planes, dz_range_um, obj_name)
            %generatePatternLibrary Generate a defocus pattern stack for PLM remote focusing.
            %   n_planes:    integer number of axial planes
            %   dz_range_um: total axial range in µm, symmetric about 0
            %   obj_name:    string key into objective table:
            %                  'Avocado'    (f=16.8 mm, NA=0.6)
            %                  'Nikon16x'   (f=11.25 mm, NA=0.8)
            %                  'Olympus20x' (f=9.0 mm, NA=1.0)
            %                All entries assume a 180 mm tube lens.
            %
            %   Returns:
            %     patterns    nRows × nCols × n_planes uint8 (states 0..nPhaseStates-1)
            %     dz_um       1 × n_planes double, linspace(-range/2, +range/2, n)
            %     sys         struct: r_PLM_um, N_radius, dz_nyquist_um,
            %                        dz_3px_um, memory_MB
            %
            %   Prints a system summary to the console on each call.

            % Objective lookup table (tube lens = 180 mm for all entries)
            OBJ = struct();
            OBJ.Avocado    = struct('f_obj_um', 16800, 'NA', 0.6);
            OBJ.Nikon16x   = struct('f_obj_um', 11250, 'NA', 0.8);
            OBJ.Olympus20x = struct('f_obj_um',  9000, 'NA', 1.0);

            if ~isfield(OBJ, obj_name)
                error('tfp:hardware:PLM:unknownObjective', ...
                    'Unknown objective "%s". Valid keys: Avocado, Nikon16x, Olympus20x.', ...
                    obj_name);
            end
            objSpec = OBJ.(obj_name);

            % Build sys struct for computeDefocusPattern (uses its own defaults for
            % M_relay and n when not supplied, so pass explicit values to match here)
            phySys.f_obj_um = objSpec.f_obj_um;
            phySys.NA       = objSpec.NA;

            % Axial sample positions
            dz_um = linspace(-dz_range_um / 2, dz_range_um / 2, n_planes);

            % Allocate and fill pattern stack
            patterns = zeros(obj.nRows, obj.nCols, n_planes, 'uint8');
            for k = 1:n_planes
                patterns(:,:,k) = obj.computeDefocusPattern(dz_um(k), phySys);
            end

            % System summary metrics — use same defaults as computeDefocusPattern
            M_relay   = 2.4;
            n         = 1.33;
            lambda_um = obj.lambda_nm / 1000;
            f_um      = objSpec.f_obj_um;
            NA        = objSpec.NA;

            r_PLM_um  = (f_um * NA / n) / M_relay;
            % Use largest pixel pitch for the conservative (worst-case) Nyquist bound
            p_um      = max(obj.pitchX_um, obj.pitchY_um);
            N_radius  = round(r_PLM_um / p_um);

            % dz_nyquist: maximum dz before adjacent-pixel phase diff at pupil edge > pi
            dz_nyquist_um = lambda_um * f_um^2 / ...
                            (2 * n * M_relay^2 * r_PLM_um * p_um);

            % dz_3px: smallest dz producing ≥3 phase-state variation per pixel at edge
            dz_3px_um = 3 * lambda_um * f_um^2 / ...
                        (obj.nPhaseStates * n * M_relay^2 * r_PLM_um * p_um);

            % uint8 = 1 byte per element
            memory_MB = double(obj.nRows) * double(obj.nCols) * n_planes / 1024^2;

            sys.r_PLM_um      = r_PLM_um;
            sys.N_radius      = N_radius;
            sys.dz_nyquist_um = dz_nyquist_um;
            sys.dz_3px_um     = dz_3px_um;
            sys.memory_MB     = memory_MB;

            fprintf('\nPLM pattern library: %d planes, %.1f µm range\n', ...
                    n_planes, dz_range_um);
            fprintf('Objective:           %s  NA=%.2f  f_obj=%.1f mm\n', ...
                    obj_name, NA, f_um / 1000);
            fprintf('PLM aperture radius: %.1f µm  (%d px)\n', r_PLM_um, N_radius);
            fprintf('Axial Nyquist step:  %.2f µm\n', dz_nyquist_um);
            fprintf('3-px quantization:   %.2f µm\n', dz_3px_um);
            fprintf('Pattern stack:       %.1f MB\n\n', memory_MB);
        end

        function filePaths = exportPatternImages(obj, patterns, outputDir)
            %exportPatternImages Export a uint8 pattern stack as grayscale PNG files.
            %   patterns:  nRows × nCols × N uint8 (states 0..nPhaseStates-1)
            %   outputDir: char or string; created if absent
            %   filePaths: 1×N cell array of written absolute file paths
            %
            %   Each state is scaled: gray = uint8(state × 8), clamped to 255.
            %   Files are named pattern_0001.png, pattern_0002.png, ...
            %   Import into TI LightCrafter GUI → Firmware tab to flash Pre-stored
            %   Pattern Mode sequences to the DLPC900.
            %
            % TODO: verify linear grayscale encoding against DLPU018 §3 before
            % first hardware use. Grayscale intensity may map directly to phase-
            % state index; if DLPC900 uses binary-plane packing instead, update
            % this encoding and re-export.

            if ~isa(patterns, 'uint8')
                error('tfp:hardware:PLM:badPatterns', ...
                    'patterns must be uint8; got %s.', class(patterns));
            end
            if size(patterns, 1) ~= obj.nRows || size(patterns, 2) ~= obj.nCols
                error('tfp:hardware:PLM:badPatternShape', ...
                    'patterns must be [%d × %d × N]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(patterns)));
            end
            if any(patterns(:) >= obj.nPhaseStates)
                error('tfp:hardware:PLM:badPatternValues', ...
                    'pattern values must be in 0..%d; got max %d.', ...
                    obj.nPhaseStates - 1, max(patterns(:)));
            end

            outputDir = char(outputDir);
            if ~isfolder(outputDir)
                mkdir(outputDir);
            end

            N = size(patterns, 3);
            filePaths = cell(1, N);
            for k = 1:N
                gray  = min(uint8(255), patterns(:,:,k) .* uint8(8));
                fname = fullfile(outputDir, sprintf('pattern_%04d.png', k));
                imwrite(gray, fname);
                filePaths{k} = fname;
            end
            fprintf('Exported %d pattern image(s) to: %s\n', N, outputDir);
        end
    end
end

% --- Local helper ---

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
