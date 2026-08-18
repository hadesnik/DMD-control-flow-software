classdef test_objectives_registry < matlab.unittest.TestCase
    %test_objectives_registry tfp.optics.objectives + buildDefocusSys +
    %   dmdToDispersionUm.

    methods (Test)

        function fourObjectivesWithBindingEFLs(testCase)
            % EFLs are binding design values (tube-lens-correct):
            % 20 mm (Nikon 10x/200), 9 mm (Olympus 20x/180),
            % 12.5 mm (Nikon 16x/200 — NOT the old 180-tube 11.25),
            % 16.8 mm (Avocado vendor spec).
            o = tfp.optics.objectives('nikon10x045');
            testCase.verifyEqual(o.fObjUm, 20000);
            testCase.verifyEqual(o.NA, 0.45);
            testCase.verifyEqual(o.nImm, 1.00);   % dry

            o = tfp.optics.objectives('olympus20x');
            testCase.verifyEqual(o.fObjUm, 9000);
            testCase.verifyEqual(o.NA, 1.00);

            o = tfp.optics.objectives('nikon16x');
            testCase.verifyEqual(o.fObjUm, 12500);
            testCase.verifyEqual(o.NA, 0.80);

            o = tfp.optics.objectives('avocado10x');
            testCase.verifyEqual(o.fObjUm, 16800);
            testCase.verifyEqual(o.NA, 0.60);

            testCase.verifyError(@() tfp.optics.objectives('leica5x'), ...
                'tfp:optics:objectives:unknownObjective');
        end

        function plmLegacyAliasesResolve(testCase)
            plm = tfp.hardware.MockPLM();
            plm.initialize(struct('nRows', 64, 'nCols', 64));
            % Legacy alias resolves through the registry; Nikon16x now
            % carries the 200-mm-tube EFL. evalc swallows the summary print.
            [~, ~, dz] = evalc('plm.generatePatternLibrary(3, 20, ''Nikon16x'')');
            testCase.verifyEqual(dz, linspace(-10, 10, 3));
            testCase.verifyError( ...
                @() doGenerate(plm), ...
                'tfp:hardware:PLM:unknownObjective');
        end

        function buildDefocusSysMergesWithPrecedence(testCase)
            config.objective = struct('name', 'nikon10x045');
            config.slm = struct('m_relay', 1.2, 'nStates', 256, ...
                'pitch_um', 17.0, 'lambda_nm', 1038);
            sys = tfp.optics.buildDefocusSys(config);
            testCase.verifyEqual(sys.fObjUm, 20000);
            testCase.verifyEqual(sys.NA, 0.45);
            testCase.verifyEqual(sys.nImm, 1.00);
            testCase.verifyEqual(sys.mRelay, 1.2);
            testCase.verifyEqual(sys.wrapPhaseRad, 2 * pi);   % LC default
            testCase.verifyEqual(sys.nRows, 1024);

            % Explicit objective override beats the registry.
            config.objective.NA = 0.40;
            sys = tfp.optics.buildDefocusSys(config);
            testCase.verifyEqual(sys.NA, 0.40);
        end

        function buildDefocusSysRequiresMRelay(testCase)
            config.objective = struct('name', 'nikon10x045');
            config.slm = struct('nStates', 256);   % no m_relay
            testCase.verifyError(@() tfp.optics.buildDefocusSys(config), ...
                'tfp:optics:buildDefocusSys:missingMRelay');
        end

        function dispersionMappingIsDiagonal(testCase)
            c = tfp.util.readHandoffConstants();
            dmdSize = [800, 1280];
            centre  = [(1280 + 1) / 2, (800 + 1) / 2];

            % Chip centre maps to the origin.
            [xd, yg] = tfp.optics.dmdToDispersionUm(centre, dmdSize);
            testCase.verifyEqual(xd, 0, 'AbsTol', 1e-12);
            testCase.verifyEqual(yg, 0, 'AbsTol', 1e-12);

            % A pure (+1,+1) px step is pure dispersion: sqrt(2) diagonal px.
            [xd, yg] = tfp.optics.dmdToDispersionUm(centre + [1, 1], dmdSize);
            testCase.verifyEqual(xd, sqrt(2) * c.um_per_px_disp, 'AbsTol', 1e-9);
            testCase.verifyEqual(yg, 0, 'AbsTol', 1e-9);

            % A (+1,-1) px step is pure groove.
            [xd, yg] = tfp.optics.dmdToDispersionUm(centre + [1, -1], dmdSize);
            testCase.verifyEqual(xd, 0, 'AbsTol', 1e-9);
            testCase.verifyEqual(yg, sqrt(2) * c.um_per_px_groove, 'AbsTol', 1e-9);
        end
    end
end

% --- Local helper ---

function doGenerate(plm)
[~] = evalc('plm.generatePatternLibrary(2, 10, ''NotAnObjective'')');
end
