classdef test_slm_mask_engine < matlab.unittest.TestCase
    %test_slm_mask_engine tfp.slm mask engine: physics, hooks, and the
    %   byte-parity guarantee with the pre-refactor
    %   tfp.hardware.PLM.computeDefocusPattern output.

    methods (Access = private)
        function sys = plmSys(~)
            % TI-PLM geometry + the PLM wrap convention — the config under
            % which byte parity with computeDefocusPattern must hold.
            sys = struct('nRows', 800, 'nCols', 904, ...
                'pitchXUm', 16.2, 'pitchYUm', 10.8, ...
                'nStates', 32, 'lambdaNm', 1038, ...
                'mRelay', 2.4, 'nImm', 1.33, 'fObjUm', 16800, 'NA', 0.6, ...
                'wrapPhaseRad', 2 * pi * 31 / 32);
        end

        function sys = slmSys(~)
            % Meadowlark geometry, LC 2*pi wrap.
            sys = struct('nRows', 1024, 'nCols', 1024, ...
                'pitchXUm', 17.0, 'pitchYUm', 17.0, ...
                'nStates', 256, 'lambdaNm', 1038, ...
                'mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, 'NA', 0.45, ...
                'wrapPhaseRad', 2 * pi);
        end

        function plm = makePlm(~)
            plm = tfp.hardware.MockPLM();
            cfg = struct('nRows', 800, 'nCols', 904, 'pitchX_um', 16.2, ...
                'pitchY_um', 10.8, 'nPhaseStates', 32, 'lambda_nm', 1038, ...
                'loadLatencyMs', 0);
            plm.initialize(cfg);
        end
    end

    methods (Test)

        function byteParityWithPLMComputeDefocusPattern(testCase)
            % The PLM base delegates to the engine; both paths must agree
            % bit-for-bit at the TI-PLM config across representative dz.
            plm = testCase.makePlm();
            sys = testCase.plmSys();
            for dz = [-150, -30, 0, 5, 50, 200]
                viaPlm    = plm.computeDefocusPattern(dz, struct());
                viaEngine = tfp.slm.computeDefocusMask(dz, sys);
                testCase.verifyEqual(viaEngine, viaPlm, ...
                    sprintf('parity broken at dz=%g', dz));
            end
        end

        function dzZeroIsFlat(testCase)
            sys  = testCase.slmSys();
            mask = tfp.slm.computeDefocusMask(0, sys);
            testCase.verifyEqual(mask, zeros(1024, 1024, 'uint8'));
        end

        function valuesInRange8bit(testCase)
            sys  = testCase.slmSys();
            mask = tfp.slm.computeDefocusMask(300, sys);
            testCase.verifyClass(mask, 'uint8');
            testCase.verifyLessThanOrEqual(double(max(mask(:))), 255);
        end

        function pupilMaskZeroOutside(testCase)
            sys  = testCase.slmSys();
            [mask, info] = tfp.slm.computeDefocusMask(200, sys);
            % rPupil = 20000*0.45/(1.0*1.2) = 7500 um; corners at
            % r ~ 512*17*sqrt(2) ~ 12300 um are outside.
            testCase.verifyEqual(info.rPupilUm, 20000 * 0.45 / 1.2, ...
                'AbsTol', 1e-9);
            testCase.verifyEqual(mask(1, 1),     uint8(0));
            testCase.verifyEqual(mask(end, end), uint8(0));
            % Centre region is inside the pupil and wrapped -> some nonzero.
            testCase.verifyTrue(any(any(mask(400:600, 400:600) > 0)));
        end

        function wfcMapShiftsStates(testCase)
            sys   = testCase.slmSys();
            base  = tfp.slm.computeDefocusMask(50, sys);
            sys.wfcMap = ones(1024, 1024) * (2 * pi / 256) * 10;  % +10 states
            corr  = tfp.slm.computeDefocusMask(50, sys);
            % Inside the pupil the correction shifts the quantized state.
            testCase.verifyNotEqual(corr(512, 512), base(512, 512));
            % Outside the pupil stays clamped to 0 regardless of WFC.
            testCase.verifyEqual(corr(1, 1), uint8(0));
        end

        function applyWfcValidatesShape(testCase)
            testCase.verifyError( ...
                @() tfp.slm.applyWFC(zeros(4, 4), zeros(3, 3)), ...
                'tfp:slm:applyWFC:badMap');
        end

        function applyLutIdentityAndMapping(testCase)
            states = uint8([0 1 2; 3 4 5]);
            testCase.verifyEqual(tfp.slm.applyLUT(states, []), states);
            lut = 255:-1:0;   % inverting LUT
            out = tfp.slm.applyLUT(states, lut);
            testCase.verifyEqual(out, uint8(255 - double(states)));
            testCase.verifyError(@() tfp.slm.applyLUT(states, [0 1 2]), ...
                'tfp:slm:applyLUT:lutTooShort');
        end

        function missingGeometryFieldThrows(testCase)
            sys = testCase.slmSys();
            sys = rmfield(sys, 'pitchXUm');
            testCase.verifyError( ...
                @() tfp.slm.computeDefocusMask(10, sys), ...
                'tfp:slm:computeDefocusMask:missingField');
        end

        function stackPreservesOrder(testCase)
            sys    = testCase.slmSys();
            dzList = [17, -5, 0, 42];
            stack  = tfp.slm.computeDefocusStack(dzList, sys);
            testCase.verifySize(stack, [1024, 1024, 4]);
            for k = 1:4
                expected = tfp.slm.computeDefocusMask(dzList(k), sys);
                testCase.verifyEqual(stack(:, :, k), expected, ...
                    sprintf('stack order broken at position %d', k));
            end
        end

        function specRoundTrip(testCase)
            sys  = testCase.slmSys();
            spec = tfp.slm.buildMaskSpec([0 10 20], sys, ...
                struct('triggerMode', 'ttl'));
            sys2 = tfp.slm.specToSys(spec);
            % Rebuilt sys computes identical masks (both-ends guarantee).
            m1 = tfp.slm.computeDefocusMask(10, sys);
            m2 = tfp.slm.computeDefocusMask(10, sys2);
            testCase.verifyEqual(m2, m1);
        end

        function specValidation(testCase)
            sys  = testCase.slmSys();
            spec = tfp.slm.buildMaskSpec([0 10], sys, struct());
            testCase.verifyEqual(spec.triggerMode, 'software');

            bad = rmfield(spec, 'lambdaNm');
            testCase.verifyError(@() tfp.slm.validateSpec(bad), ...
                'tfp:slm:validateSpec:missingField');

            bad = spec; bad.nested = struct('x', 1);
            testCase.verifyError(@() tfp.slm.validateSpec(bad), ...
                'tfp:slm:validateSpec:nestedStruct');

            bad = spec; bad.triggerMode = 'hardware';
            testCase.verifyError(@() tfp.slm.validateSpec(bad), ...
                'tfp:slm:validateSpec:badTriggerMode');

            bad = spec; bad.dzListUm = [];
            testCase.verifyError(@() tfp.slm.validateSpec(bad), ...
                'tfp:slm:validateSpec:badDzList');
        end
    end
end
