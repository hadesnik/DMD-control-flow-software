classdef test_opticalModel < matlab.unittest.TestCase
    %test_opticalModel Bring-up optical constants accessor (TASK-BU T-BU-0).
    %
    %   These constants are load-bearing: every sample<->DMD transform, the
    %   patch guard, the pupil interlock and the dwell correction read them.
    %   The tests pin the documented defaults against
    %   docs/dmd_control_handoff.md and check the validation that catches a
    %   mistyped rig config before it silently mis-places every target.

    methods (Test)

        % --- Defaults match the handoff document ------------------------

        function defaultsMatchHandoffSpec(tc)
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.clockingDeg, 45);
            tc.verifyEqual(m.umPerPixelGroove,     1.1250, 'AbsTol', 1e-6);
            tc.verifyEqual(m.umPerPixelDispersion, 1.4162, 'AbsTol', 1e-6);
            tc.verifyEqual(m.pitchUm, 10.8, 'AbsTol', 1e-9);
            tc.verifyEqual(m.patchRadiusPx, 278);
            tc.verifyEqual(m.patchMaxRadiusPx, 329);
            tc.verifyEqual(m.gaussianWaistPx, 555.6, 'AbsTol', 1e-6);
            tc.verifyEqual(m.depthGradientUmPerUm, 0.02174, 'AbsTol', 1e-9);
            tc.verifyEqual(m.binaryFrameRateHz, 12500);
            tc.verifyEqual(m.fieldExtentUm, [625 787]);
        end

        function anisotropyIsDerivedAndMatchesSpec(tc)
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.anisotropy, ...
                m.umPerPixelDispersion / m.umPerPixelGroove, 'AbsTol', 1e-12);
            % The handoff quotes 1.2588 for the dispersion/groove ratio.
            tc.verifyEqual(m.anisotropy, 1.2588, 'AbsTol', 1e-3);
        end

        function frameDurationIs80Microseconds(tc)
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.frameDurationS, 80e-6, 'AbsTol', 1e-12);
        end

        function patchRadiusMatchesSixMillimetreDisc(tc)
            % 6.0 mm design patch at 10.8 um pitch = 555.6 px diameter.
            m = tfp.util.opticalModel();
            tc.verifyEqual(2 * m.patchRadiusPx * m.pitchUm / 1000, 6.0, ...
                'AbsTol', 0.02, ...
                'patchRadiusPx should describe the 6.0 mm design patch.');
        end

        % --- Laser constants: the 40 W correction ------------------------

        function laserDefaultsUseFortyWattsNotEighty(tc)
            % docs/dmd_control_handoff.md §7 says 80 W; that is a generator
            % error (see the correction banner in that file). 40 W is correct.
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.maxPowerW, 40);
            tc.verifyEqual(m.repRateHz, 1e5);
        end

        function deliverablePulseEnergyIs400uJAt40W(tc)
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.maxDeliverablePulseEnergyUj, 400, 'AbsTol', 1e-9, ...
                '40 W at 100 kHz is 400 uJ per pulse, not the 800 uJ in §7.');
        end

        function pupilLimitIsUnaffectedByThePowerCorrection(tc)
            % The 68 uJ threshold is an air-ionisation limit set by the optics
            % and the 230 fs pulse, so halving the laser rating must not move
            % it. Full-field ON still exceeds it by ~5.9x.
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.maxPulseEnergyUjPupil, 68);
            tc.verifyGreaterThan( ...
                m.maxDeliverablePulseEnergyUj / m.maxPulseEnergyUjPupil, 5);
        end

        % --- Config overrides -------------------------------------------

        function acceptsFullConfigWithDmdSubstruct(tc)
            cfg.dmd.umPerPixelGroove     = 2.0;
            cfg.dmd.umPerPixelDispersion = 2.5;
            cfg.laser.max_power_w        = 20;
            m = tfp.util.opticalModel(cfg);
            tc.verifyEqual(m.umPerPixelGroove, 2.0);
            tc.verifyEqual(m.umPerPixelDispersion, 2.5);
            tc.verifyEqual(m.maxPowerW, 20);
        end

        function acceptsBareFieldStruct(tc)
            % Callers holding only the dmd sub-struct should not have to re-wrap.
            m = tfp.util.opticalModel(struct('patchRadiusPx', 200));
            tc.verifyEqual(m.patchRadiusPx, 200);
        end

        function roiHalfWidthPxIsHonouredAsLegacyAlias(tc)
            % Existing rig configs carry roiHalfWidthPx, not patchRadiusPx.
            m = tfp.util.opticalModel(struct('roiHalfWidthPx', 250));
            tc.verifyEqual(m.patchRadiusPx, 250);
        end

        function explicitPatchRadiusWinsOverLegacyAlias(tc)
            m = tfp.util.opticalModel( ...
                struct('roiHalfWidthPx', 250, 'patchRadiusPx', 260));
            tc.verifyEqual(m.patchRadiusPx, 260);
        end

        % --- Validation --------------------------------------------------

        function statedAnisotropyMustAgreeWithAxisScales(tc)
            % The config carries all three for readability; a disagreement means
            % someone edited one scale and forgot the other.
            cfg = struct('umPerPixelGroove', 1.1250, ...
                'umPerPixelDispersion', 1.4162, 'anisotropy', 1.9);
            tc.verifyError(@() tfp.util.opticalModel(cfg), ...
                'tfp:util:opticalModel:anisotropyMismatch');
        end

        function consistentStatedAnisotropyIsAccepted(tc)
            cfg = struct('umPerPixelGroove', 1.1250, ...
                'umPerPixelDispersion', 1.4162, 'anisotropy', 1.2588);
            m = tfp.util.opticalModel(cfg);
            tc.verifyEqual(m.anisotropy, 1.2588, 'AbsTol', 1e-3);
        end

        function patchRadiusAboveHardLimitIsRejected(tc)
            cfg = struct('patchRadiusPx', 400, 'patchMaxRadiusPx', 329);
            tc.verifyError(@() tfp.util.opticalModel(cfg), ...
                'tfp:util:opticalModel:patchExceedsMax');
        end

        function nonPositiveScaleIsRejected(tc)
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('umPerPixelGroove', 0)), ...
                'tfp:util:opticalModel:badValue');
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('umPerPixelDispersion', -1)), ...
                'tfp:util:opticalModel:badValue');
        end

        function unresolvedSignsMustBePlusOrMinusOne(tc)
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('dispersionAxisSign', 0)), ...
                'tfp:util:opticalModel:badSign');
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('depthGradientSign', 2)), ...
                'tfp:util:opticalModel:badSign');
            m = tfp.util.opticalModel(struct('dispersionAxisSign', -1));
            tc.verifyEqual(m.dispersionAxisSign, -1);
        end

        function malformedPatchCenterIsRejected(tc)
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('patchCenterPx', [1 2 3])), ...
                'tfp:util:opticalModel:badPatchCenter');
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('patchCenterPx', [NaN 400])), ...
                'tfp:util:opticalModel:badPatchCenter');
        end

        function malformedFieldExtentIsRejected(tc)
            tc.verifyError( ...
                @() tfp.util.opticalModel(struct('fieldExtentUm', [625 0])), ...
                'tfp:util:opticalModel:badFieldExtent');
        end

        function fillFractionOutOfRangeIsRejected(tc)
            cfg.laser.pupil_interlock_fill_fraction = 1.5;
            tc.verifyError(@() tfp.util.opticalModel(cfg), ...
                'tfp:util:opticalModel:badFillFraction');
        end

        function nonStructConfigIsRejected(tc)
            tc.verifyError(@() tfp.util.opticalModel(42), ...
                'tfp:util:opticalModel:badConfig');
        end

        % --- Derived helpers ---------------------------------------------

        function periscopeReversalFactorIsTheDocumentedRatio(tc)
            % §9: if the 200/150 periscope pair is installed in the reverse
            % order, every um/px figure scales by this. T-BU-3a uses it to
            % diagnose the case from a calibration grid.
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.periscopeReversalFactor, 1.7778, 'AbsTol', 1e-3);
        end

        function scalarUmPerPixelIsTheGeometricMean(tc)
            % Convenience only — never for placing a target.
            m = tfp.util.opticalModel();
            tc.verifyEqual(m.umPerPixel, ...
                sqrt(m.umPerPixelGroove * m.umPerPixelDispersion), ...
                'AbsTol', 1e-12);
            % Sanity: it is ~4x the retired isotropic 0.270 um/px guess.
            tc.verifyGreaterThan(m.umPerPixel / 0.270, 4);
        end

        % --- The rig config actually parses ------------------------------

        function realYamlProducesAValidModel(tc)
            % Guards against a typo in configs/real.yaml reaching the rig.
            here = fileparts(fileparts(mfilename('fullpath')));
            cfgPath = fullfile(here, 'configs', 'real.yaml');
            tc.assumeTrue(isfile(cfgPath), 'configs/real.yaml not found.');
            cfg = tfp.io.loadConfig(cfgPath);
            m   = tfp.util.opticalModel(cfg);
            tc.verifyEqual(m.umPerPixelGroove,     1.1250, 'AbsTol', 1e-4);
            tc.verifyEqual(m.umPerPixelDispersion, 1.4162, 'AbsTol', 1e-4);
            tc.verifyEqual(m.maxPowerW, 40);
            tc.verifyEqual(m.patchRadiusPx, 278);
        end

    end
end
