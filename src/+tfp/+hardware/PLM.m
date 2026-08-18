classdef PLM < handle
    %PLM Abstract interface for pupil phase modulators (remote focusing).
    %   Subclasses: MockPLM (TI-PLM simulator), DLPC900_PLM (real TI NIR
    %   PLM via DLPC900), MockSLM (Meadowlark simulator) and MeadowlarkSLM
    %   (DAQ-PC proxy to the SLM-PC Blink server). Experiment code talks to
    %   this interface, never to a concrete class — that is what keeps the
    %   Meadowlark <-> TI-PLM swap a config change.
    %
    %   computeDefocusPattern is implemented here on the base because it
    %   depends only on the abstract pixel-geometry and phase-spec properties
    %   (nRows, nCols, pitchX_um, pitchY_um, nPhaseStates, lambda_nm) that
    %   every subclass must define. The physics itself lives in
    %   tfp.slm.computeDefocusMask (shared with the SLM-PC server); this
    %   method is a thin adapter that applies the TI-PLM wrap convention.
    %
    %   Defocus-SEQUENCE interface (Meadowlark path): concrete methods with
    %   default tfp:hardware:PLM:notSupported errors, so legacy subclasses
    %   (MockPLM, DLPC900_PLM) compile unchanged. Sequence-capable
    %   subclasses (MockSLM, MeadowlarkSLM) override all of them.
    %   Sequence order is the contract: masks are preloaded in depth-group
    %   order and advanceToIndex steps through them (TTL pulse or network
    %   'ADV' depending on the armed trigger mode).

    properties (Abstract, SetAccess = protected)
        nRows           % pixel rows (y dimension), e.g. 800
        nCols           % pixel columns (x dimension), e.g. 904
        pitchX_um       % pixel pitch along x (columns), µm; e.g. 16.2
        pitchY_um       % pixel pitch along y (rows), µm; e.g. 10.8
        nPhaseStates    % quantized phase levels, e.g. 32 (5-bit)
        lambda_nm       % design wavelength, nm; e.g. 1038 (measured CARBIDE [CERT])
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
            %   (~6.09 rad for N=32, the TI-PLM double-pass piston full scale),
            %   then quantized into N uniform bins.
            %
            %   Delegates to tfp.slm.computeDefocusMask (the shared engine);
            %   output is byte-identical to the pre-refactor implementation,
            %   pinned by tests/test_slm_mask_engine.m.

            if nargin < 3 || isempty(sys)
                sys = struct();
            end

            engineSys = struct( ...
                'nRows',        obj.nRows, ...
                'nCols',        obj.nCols, ...
                'pitchXUm',     obj.pitchX_um, ...
                'pitchYUm',     obj.pitchY_um, ...
                'nStates',      obj.nPhaseStates, ...
                'lambdaNm',     obj.lambda_nm, ...
                'mRelay',       tfp.util.configField(sys, 'M_relay',  2.4), ...
                'nImm',         tfp.util.configField(sys, 'n',        1.33), ...
                'fObjUm',       tfp.util.configField(sys, 'f_obj_um', 16800), ...
                'NA',           tfp.util.configField(sys, 'NA',       0.6), ...
                'wrapPhaseRad', 2 * pi * (obj.nPhaseStates - 1) / obj.nPhaseStates);

            pattern = tfp.slm.computeDefocusMask(dz_um, engineSys);
        end

        % ============================================================
        % Defocus-sequence interface (Meadowlark / sequence-capable
        % devices override; legacy subclasses inherit the errors).
        % ============================================================

        function tf = supportsDefocusSequence(obj) %#ok<MANU>
            %supportsDefocusSequence True when prepare/advance sequencing works.
            %   Default false: legacy per-trial loadPattern devices.
            tf = false;
        end

        function prepareDefocusSequence(obj, dzListUm, sys) %#ok<INUSD>
            %prepareDefocusSequence Compute + upload masks in dzListUm order.
            %   Sequence order = depth-group order (the TTL contract).
            error('tfp:hardware:PLM:notSupported', ...
                '%s does not support defocus sequences.', class(obj));
        end

        function armSequenceTrigger(obj, mode) %#ok<INUSD>
            %armSequenceTrigger Arm advance mode: 'ttl' | 'software'.
            error('tfp:hardware:PLM:notSupported', ...
                '%s does not support defocus sequences.', class(obj));
        end

        function advanceToIndex(obj, idx) %#ok<INUSD>
            %advanceToIndex Step to sequence position idx (1-based) and settle.
            error('tfp:hardware:PLM:notSupported', ...
                '%s does not support defocus sequences.', class(obj));
        end

        function idx = getSequenceIndex(obj) %#ok<MANU>
            %getSequenceIndex Current 1-based sequence position (0 = none).
            error('tfp:hardware:PLM:notSupported', ...
                'getSequenceIndex requires a sequence-capable device.');
        end

        function t = settleTimeS(obj) %#ok<MANU>
            %settleTimeS Phase-settle budget after an advance, seconds.
            %   Meadowlark LC response is 3.4 ms (docs/optics_handoff.md §6);
            %   legacy devices default to 0.
            t = 0;
        end

        function [patterns, dz_um, sys] = generatePatternLibrary(obj, n_planes, dz_range_um, obj_name)
            %generatePatternLibrary Generate a defocus pattern stack for remote focusing.
            %   n_planes:    integer number of axial planes
            %   dz_range_um: total axial range in µm, symmetric about 0
            %   obj_name:    objective name resolved by tfp.optics.objectives
            %                ('nikon10x045', 'olympus20x', 'nikon16x',
            %                'avocado10x'; legacy aliases 'Avocado',
            %                'Nikon16x', 'Olympus20x' still accepted).
            %
            %   NOTE: the old in-method table assumed a 180 mm tube lens and
            %   quoted Nikon16x at 11.25 mm EFL; the registry carries the
            %   rig-correct 12.5 mm (Nikon 200 mm tube). See
            %   tfp.optics.objectives.
            %
            %   Returns:
            %     patterns    nRows × nCols × n_planes uint8 (states 0..nPhaseStates-1)
            %     dz_um       1 × n_planes double, linspace(-range/2, +range/2, n)
            %     sys         struct: r_PLM_um, N_radius, dz_nyquist_um,
            %                        dz_3px_um, memory_MB
            %
            %   Prints a system summary to the console on each call.

            objSpec = resolveObjective(obj_name);

            % Build sys struct for computeDefocusPattern. M_relay stays the
            % TI-PLM default here; the Meadowlark path builds its sys via
            % tfp.optics.buildDefocusSys instead.
            phySys.f_obj_um = objSpec.fObjUm;
            phySys.NA       = objSpec.NA;
            phySys.n        = objSpec.nImm;

            % Axial sample positions
            dz_um = linspace(-dz_range_um / 2, dz_range_um / 2, n_planes);

            % Allocate and fill pattern stack
            patterns = zeros(obj.nRows, obj.nCols, n_planes, 'uint8');
            for k = 1:n_planes
                patterns(:,:,k) = obj.computeDefocusPattern(dz_um(k), phySys);
            end

            % System summary metrics — use same defaults as computeDefocusPattern
            M_relay   = 2.4;
            n         = objSpec.nImm;
            lambda_um = obj.lambda_nm / 1000;
            f_um      = objSpec.fObjUm;
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
                    objSpec.label, NA, f_um / 1000);
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
            %   States are scaled to full 8-bit range:
            %     gray = round(255 * state / (nPhaseStates - 1))
            %   For an 8-bit device (nPhaseStates=256) this is the identity;
            %   the old hardwired ×8 scaling was 5-bit-only and wrong for
            %   the Meadowlark.
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
                gray  = uint8(round(255 * double(patterns(:,:,k)) ...
                                    / double(obj.nPhaseStates - 1)));
                fname = fullfile(outputDir, sprintf('pattern_%04d.png', k));
                imwrite(gray, fname);
                filePaths{k} = fname;
            end
            fprintf('Exported %d pattern image(s) to: %s\n', N, outputDir);
        end
    end
end

% --- Local helpers ---

function spec = resolveObjective(obj_name)
%resolveObjective Map legacy aliases onto the tfp.optics.objectives registry.
name = char(obj_name);
switch name
    case 'Avocado',    name = 'avocado10x';
    case 'Nikon16x',   name = 'nikon16x';
    case 'Olympus20x', name = 'olympus20x';
end
try
    spec = tfp.optics.objectives(name);
catch
    error('tfp:hardware:PLM:unknownObjective', ...
        ['Unknown objective "%s". Valid: nikon10x045, olympus20x, ' ...
         'nikon16x, avocado10x (legacy aliases Avocado/Nikon16x/' ...
         'Olympus20x).'], char(obj_name));
end
end
