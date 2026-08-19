classdef test_power_curve_schema < matlab.unittest.TestCase
    %test_power_curve_schema tfp.calibration.normalizePowerCurve — the one
    %   place that knows powerMeterSweep and powerLUT were answering different
    %   questions with the same field name.
    %
    %   Methods:
    %     migratesLegacySweepCurve   — volts branch filled, scalar dmdActivePx
    %                                  captured as dmdActivePxAtSweep.
    %     migratesLegacyPatternCurve — ON-count branch filled from the VECTOR
    %                                  dmdActivePx + powerAtSample.
    %     scalarVsVectorDisambiguation — the scalar is never mistaken for the
    %                                  vector, which is the whole bug.
    %     isIdempotent               — safe to call on every read.
    %     preservesLegacyFields      — nothing is dropped in migration.
    %     requireBranchThrows        — a volts sweep cannot answer an ON-count
    %                                  question; say so instead of guessing.
    %     rejectsUnrecognisedAndRagged
    %     powerLutRegressionPin      — legacy input still yields the identical
    %                                  duty cycle it did before the migration.
    %     powerLutAcceptsSchema2
    %     powerLutUsesHandoffChipSize / powerLutHonoursDmdSizeOverride

    methods (Access = private)
        function c = legacySweep(~)
            % What tfp.calibration.powerMeterSweep emits today.
            v = linspace(0, 5, 6);
            c = struct('voltageV', v, 'powerMw', v * 8, ...
                'powerStdMw', 0.01 * ones(size(v)), ...
                'scaleFactor', 87.3, 'fitDeg1Coeff', 87.3, ...
                'fovAreaUm2', pi * 400^2, 'wavelengthNm', 1040, ...
                'dmdActivePx', 768 * 1024, ...
                'notes', 'PM100D+S350C', 'timestamp', datetime(2026, 8, 19));
        end

        function c = legacyPattern(~)
            % What tfp.patterns.powerLUT has always expected.
            c = struct('dmdActivePx', [0, 512000, 1024000], ...
                'powerAtSample', [0, 0.512, 1.024], ...
                'fovAreaUm2', 1000);
        end
    end

    methods (Test)

        function migratesLegacySweepCurve(testCase)
            c = tfp.calibration.normalizePowerCurve(testCase.legacySweep());
            testCase.verifyEqual(c.schema, 2);
            testCase.verifyEqual(c.kind, 'power_curve');
            testCase.verifyEqual(c.voltage.voltageV, linspace(0, 5, 6));
            testCase.verifyEqual(c.voltage.powerMw,  linspace(0, 5, 6) * 8);
            testCase.verifyEqual(c.dmdActivePxAtSweep, 768 * 1024);
            testCase.verifyEmpty(c.pattern.dmdActivePx);
        end

        function migratesLegacyPatternCurve(testCase)
            c = tfp.calibration.normalizePowerCurve(testCase.legacyPattern());
            testCase.verifyEqual(c.pattern.dmdActivePx,   [0, 512000, 1024000]);
            testCase.verifyEqual(c.pattern.powerAtSample, [0, 0.512, 1.024]);
            testCase.verifyEmpty(c.voltage.voltageV);
        end

        function scalarVsVectorDisambiguation(testCase)
            % The bug this function exists to prevent: a SCALAR dmdActivePx is
            % the ON count held during a volts sweep; a VECTOR dmdActivePx is
            % an ON-count axis. They must never be confused.
            sweep = tfp.calibration.normalizePowerCurve(testCase.legacySweep());
            patt  = tfp.calibration.normalizePowerCurve(testCase.legacyPattern());
            testCase.verifyTrue(isscalar(sweep.dmdActivePxAtSweep));
            testCase.verifyEmpty(patt.dmdActivePxAtSweep, ...
                'a vector dmdActivePx must not be claimed as the sweep scalar');
            testCase.verifyEqual(numel(patt.pattern.dmdActivePx), 3);
        end

        function isIdempotent(testCase)
            once  = tfp.calibration.normalizePowerCurve(testCase.legacySweep());
            twice = tfp.calibration.normalizePowerCurve(once);
            testCase.verifyEqual(twice.voltage,            once.voltage);
            testCase.verifyEqual(twice.pattern,            once.pattern);
            testCase.verifyEqual(twice.dmdActivePxAtSweep, once.dmdActivePxAtSweep);
            testCase.verifyEqual(twice.schema,             2);
        end

        function preservesLegacyFields(testCase)
            c = tfp.calibration.normalizePowerCurve(testCase.legacySweep());
            testCase.verifyEqual(c.scaleFactor,  87.3);
            testCase.verifyEqual(c.fitDeg1Coeff, 87.3);
            testCase.verifyEqual(c.notes,        'PM100D+S350C');
            testCase.verifyEqual(c.wavelengthNm, 1040);
        end

        function requireBranchThrows(testCase)
            testCase.verifyError(@() tfp.calibration.normalizePowerCurve( ...
                testCase.legacySweep(), struct('requireBranch', 'pattern')), ...
                'tfp:calibration:normalizePowerCurve:missingBranch');
            testCase.verifyError(@() tfp.calibration.normalizePowerCurve( ...
                testCase.legacyPattern(), struct('requireBranch', 'voltage')), ...
                'tfp:calibration:normalizePowerCurve:missingBranch');
            % and the matching branch passes
            tfp.calibration.normalizePowerCurve(testCase.legacySweep(), ...
                struct('requireBranch', 'voltage'));
        end

        function rejectsUnrecognisedAndRagged(testCase)
            testCase.verifyError(@() tfp.calibration.normalizePowerCurve( ...
                struct('somethingElse', 1)), ...
                'tfp:calibration:normalizePowerCurve:unrecognizedCurve');
            testCase.verifyError(@() tfp.calibration.normalizePowerCurve(42), ...
                'tfp:calibration:normalizePowerCurve:badCurve');
            ragged = struct('voltageV', [0 1 2], 'powerMw', [0 1]);
            testCase.verifyError(@() tfp.calibration.normalizePowerCurve(ragged), ...
                'tfp:calibration:normalizePowerCurve:inconsistentLengths');
        end

        function stampsLaserState(testCase)
            ls = tfp.util.validateLaserState(struct('repRateKhz', 100));
            c  = tfp.calibration.normalizePowerCurve(testCase.legacySweep(), ...
                struct('laserState', ls));
            testCase.verifyEqual(c.laserState.repRateKhz, 100);
        end

        % --- powerLUT interop ---------------------------------------------
        function powerLutRegressionPin(testCase)
            % Pinned against the pre-migration behaviour: 256000 lit mirrors of
            % 800*1280 is a duty cycle of 0.25.
            cal.powerCurve = testCase.legacyPattern();
            dc = tfp.patterns.powerLUT(0.256 / 1000, cal);
            testCase.verifyEqual(dc, 0.25, 'AbsTol', 1e-9);
        end

        function powerLutAcceptsSchema2(testCase)
            cal.powerCurve = tfp.calibration.normalizePowerCurve(testCase.legacyPattern());
            dc = tfp.patterns.powerLUT(0.256 / 1000, cal);
            testCase.verifyEqual(dc, 0.25, 'AbsTol', 1e-9, ...
                'a schema-2 curve must give the same answer as its legacy form');
        end

        function powerLutRejectsAVoltsCurve(testCase)
            % The original bug, now loud: handing powerLUT a volts sweep used
            % to interpolate nonsense.
            cal.powerCurve = testCase.legacySweep();
            testCase.verifyError(@() tfp.patterns.powerLUT(1e-4, cal), ...
                'tfp:calibration:normalizePowerCurve:missingBranch');
        end

        function powerLutUsesHandoffChipSize(testCase)
            hc  = tfp.util.readHandoffConstants();
            cal.powerCurve = testCase.legacyPattern();
            % Ask for exactly the full-chip power and confirm duty cycle 1.
            fullPx  = hc.dmd_rows * hc.dmd_cols;
            fullMw  = interp1(cal.powerCurve.dmdActivePx, ...
                cal.powerCurve.powerAtSample, fullPx, 'linear', 'extrap');
            dc = tfp.patterns.powerLUT(fullMw / 1000, cal);
            testCase.verifyEqual(dc, 1, 'AbsTol', 1e-9);
        end

        function powerLutHonoursDmdSizeOverride(testCase)
            % The borrowed DLP7000 is 768x1024, not 800x1280. Same curve, same
            % target, different chip -> different duty cycle.
            cal.powerCurve = testCase.legacyPattern();
            calSmall = cal;
            calSmall.dmdSize = [768 1024];
            target = 0.256 / 1000;
            dcBig   = tfp.patterns.powerLUT(target, cal);
            dcSmall = tfp.patterns.powerLUT(target, calSmall);
            testCase.verifyEqual(dcSmall, 256000 / (768 * 1024), 'AbsTol', 1e-9);
            testCase.verifyGreaterThan(dcSmall, dcBig);
        end
    end
end
