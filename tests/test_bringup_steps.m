classdef test_bringup_steps < matlab.unittest.TestCase
    %test_bringup_steps The guided bringup's procedure, criteria and verdicts.
    %
    %   The wizard's whole behaviour is data (tfp.gui.bringupSteps) plus two
    %   pure functions (tfp.gui.stepMetrics, tfp.gui.stepVerdict). None of it
    %   touches graphics or hardware, so all of it is testable under
    %   matlab -nodisplay — which is the point of having built it that way.
    %
    %   Methods:
    %     everyStepIsWellFormed          — the registry is internally consistent
    %     everyMethodExistsOnTheSession  — no step names a method that is not there
    %     prerequisitesComeEarlierAndResolve
    %     passWhenEveryCriterionIsMet
    %     unknownCriterionNeverSilentlyPasses
    %     failSeverityStopsOnAnUnknown
    %     warnAdvancesButAdjustDoesNot
    %     checklistNeedsEveryBox
    %     zeroVoltsNotOffIsAHardStop     — the CLAUDE.md open safety question
    %     nonMonotonicPowerCurveIsAdjust
    %     scaleCheckUsesSingularValuesNotTheDiagonal
    %     grooveFractionIsDiagnosticNotCosmetic
    %     tiltSignDisagreementOnlyWarns

    properties (Constant)
        KnownPlots = {'none', 'preflight', 'powerCurve', 'residuals', ...
                      'scanRect', 'tilt', 'zfit', 'planes', 'zcompose', 'marks'}
        KnownTests = {'lt', 'le', 'gt', 'ge', 'eq', 'isTrue', 'isFalse'}
        KnownSeverities = {'info', 'warn', 'adjust', 'fail'}
        KnownNeeds = {'dmd', 'camera', 'daq', 'zstage', 'slm', 'laser', 'laserState'}
    end

    methods (Test)

        function everyStepIsWellFormed(testCase)
            steps = tfp.gui.bringupSteps();
            testCase.verifyGreaterThan(numel(steps), 10);
            ids = {steps.id};
            testCase.verifyEqual(numel(unique(ids)), numel(ids), ...
                'step ids must be unique — results and report sections key on them');

            for k = 1:numel(steps)
                s = steps(k);
                ctx = sprintf('step ''%s''', s.id);
                testCase.verifyNotEmpty(s.title,   ctx);
                testCase.verifyNotEmpty(s.section, ctx);
                testCase.verifyNotEmpty(s.purpose, ctx);
                testCase.verifyNotEmpty(s.setup, sprintf( ...
                    ['%s has no setup text. Every step must tell the operator ' ...
                     'what to do physically before it runs — that is the whole ' ...
                     'point of the guided path.'], ctx));
                testCase.verifyTrue(ismember(s.kind, {'checklist', 'measure'}), ctx);
                testCase.verifyTrue(ismember(s.plot, testCase.KnownPlots), ...
                    sprintf('%s: plot recipe ''%s'' has no renderer', ctx, s.plot));

                if strcmp(s.kind, 'checklist')
                    testCase.verifyNotEmpty(s.checks, ctx);
                else
                    testCase.verifyNotEmpty(s.method, ctx);
                    testCase.verifyNotEmpty(s.willDo, sprintf( ...
                        '%s must say what the software is about to do', ctx));
                    testCase.verifyNotEmpty(s.criteria, sprintf( ...
                        ['%s declares no acceptance criteria, so it can never ' ...
                         'return anything but pass — a step that cannot fail ' ...
                         'is not a check.'], ctx));
                end

                for j = 1:numel(s.criteria)
                    c = s.criteria(j);
                    cctx = sprintf('%s criterion ''%s''', ctx, c.label);
                    testCase.verifyTrue(ismember(c.test, testCase.KnownTests), cctx);
                    testCase.verifyTrue(ismember(c.severity, testCase.KnownSeverities), cctx);
                    testCase.verifyNotEmpty(c.field, cctx);
                    testCase.verifyNotEmpty(c.why, sprintf( ...
                        ['%s has no explanation. The number alone does not tell ' ...
                         'an operator whether it matters.'], cctx));
                end

                for j = 1:numel(s.needs)
                    testCase.verifyTrue(ismember(s.needs{j}, testCase.KnownNeeds), ...
                        sprintf('%s needs unknown device key ''%s''', ctx, s.needs{j}));
                end

                if ~isempty(s.criteria) || strcmp(s.kind, 'checklist')
                    testCase.verifyNotEmpty(s.remedy, sprintf( ...
                        ['%s can fail but says nothing about what to change. ' ...
                         'A verdict without a remedy leaves the operator stuck.'], ctx));
                end
            end
        end

        function everyMethodExistsOnTheSession(testCase)
            % A typo here would only surface on the rig, halfway through a
            % session, as "unrecognized method".
            steps = tfp.gui.bringupSteps();
            available = methods('tfp.gui.CalibrationSession');
            for k = 1:numel(steps)
                if isempty(steps(k).method), continue; end
                testCase.verifyTrue(ismember(steps(k).method, available), sprintf( ...
                    'step ''%s'' names method ''%s'', which CalibrationSession does not have', ...
                    steps(k).id, steps(k).method));
            end
        end

        function prerequisitesComeEarlierAndResolve(testCase)
            steps = tfp.gui.bringupSteps();
            ids = {steps.id};
            for k = 1:numel(steps)
                for j = 1:numel(steps(k).requires)
                    need = steps(k).requires{j};
                    idx = find(strcmp(ids, need), 1);
                    testCase.verifyNotEmpty(idx, sprintf( ...
                        'step ''%s'' requires unknown step ''%s''', steps(k).id, need));
                    testCase.verifyLessThan(idx, k, sprintf( ...
                        ['step ''%s'' requires ''%s'', which comes AFTER it. ' ...
                         'The rail is walked top to bottom; a backwards ' ...
                         'dependency can never be satisfied.'], steps(k).id, need));
                end
            end
        end

        % --- verdict logic -------------------------------------------------

        function passWhenEveryCriterionIsMet(testCase)
            step = testCase.stepFor('field_tilt');
            v = tfp.gui.stepVerdict(step, testCase.goodTilt());
            testCase.verifyEqual(v.verdict, 'pass');
            testCase.verifyTrue(v.canAdvance);
            testCase.verifyFalse(v.mustRetake);
            testCase.verifyEmpty(v.remedy);
        end

        function unknownCriterionNeverSilentlyPasses(testCase)
            % A result missing the field a criterion reads must not be
            % reported as if the check had been made.
            step = testCase.stepFor('field_tilt');
            v = tfp.gui.stepVerdict(step, struct());
            testCase.verifyNotEqual(v.verdict, 'pass');
            unknowns = arrayfun(@(r) isnan(r.ok), v.rows);
            testCase.verifyTrue(any(unknowns));
            testCase.verifyTrue(any(strcmp({v.rows.valueText}, 'not measured')));
        end

        function failSeverityStopsOnAnUnknown(testCase)
            % The rule that keeps "power at 0 V is off" from being skipped by
            % a result struct that happens to lack the field.
            step = testCase.stepFor('power_curve');
            v = tfp.gui.stepVerdict(step, struct());
            testCase.verifyEqual(v.verdict, 'fail');
            testCase.verifyFalse(v.canAdvance);
        end

        function warnAdvancesButAdjustDoesNot(testCase)
            step = testCase.stepFor('field_tilt');

            % Out of the handoff band: a note, not a problem. The measurement
            % is the truth and the handoff is design intent.
            outOfBand = testCase.goodTilt();
            outOfBand.sanity.gradientInBand = false;
            v = tfp.gui.stepVerdict(step, outOfBand);
            testCase.verifyEqual(v.verdict, 'warn');
            testCase.verifyTrue(v.canAdvance);
            testCase.verifyNotEmpty(v.remedy);

            % A large groove component means the chip clocking is wrong.
            % That is a bench change, and it blocks.
            miscloked = testCase.goodTilt();
            miscloked.fit.bUmPerUm = 0.02;
            v = tfp.gui.stepVerdict(step, miscloked);
            testCase.verifyEqual(v.verdict, 'adjust');
            testCase.verifyFalse(v.canAdvance);
            testCase.verifyTrue(v.mustRetake);
        end

        function checklistNeedsEveryBox(testCase)
            step = testCase.stepFor('prereq_bench');
            n = numel(step.checks);

            v = tfp.gui.stepVerdict(step, struct('checked', true(1, n)));
            testCase.verifyEqual(v.verdict, 'pass');

            partial = true(1, n);
            partial(2) = false;
            v = tfp.gui.stepVerdict(step, struct('checked', partial));
            testCase.verifyEqual(v.verdict, 'adjust');
            testCase.verifyFalse(v.canAdvance);
            testCase.verifySubstring(v.headline, '1 of');
        end

        % --- metrics -------------------------------------------------------

        function zeroVoltsNotOffIsAHardStop(testCase)
            % CLAUDE.md's open question, answered by measurement: if 0 V is
            % not off, every zero-on-error path drives the laser the wrong
            % way, and nothing else may run.
            step = testCase.stepFor('power_curve');

            inverted = testCase.powerCurveResult([0 1 2 3 4 5], [50 40 30 20 10 0]);
            v = tfp.gui.stepVerdict(step, inverted);
            testCase.verifyEqual(v.verdict, 'fail');
            row = testCase.rowNamed(v, 'Power at 0 V is off');
            testCase.verifyEqual(row.ok, 0);

            normal = testCase.powerCurveResult([0 1 2 3 4 5], [0 10 20 30 40 50]);
            v = tfp.gui.stepVerdict(step, normal);
            testCase.verifyEqual(testCase.rowNamed(v, 'Power at 0 V is off').ok, 1);
        end

        function nonMonotonicPowerCurveIsAdjust(testCase)
            step = testCase.stepFor('power_curve');
            folded = testCase.powerCurveResult([0 1 2 3 4 5], [0 20 40 30 45 50]);
            v = tfp.gui.stepVerdict(step, folded);
            testCase.verifyEqual(v.verdict, 'adjust');
            testCase.verifyEqual(testCase.rowNamed(v, 'Curve is monotonic').ok, 0);
        end

        function scaleCheckUsesSingularValuesNotTheDiagonal(testCase)
            % The chip is clocked 45 degrees, so the two sample-plane scales
            % lie along its DIAGONALS. Reading them off the affine's diagonal
            % would report the wrong numbers for a correct bench; the
            % singular values are rotation-independent.
            h = tfp.util.readHandoffConstants();
            umPerCamPx = 1.0;
            R = [cosd(45) -sind(45); sind(45) cosd(45)];
            S = diag([h.um_per_px_groove, h.um_per_px_disp]) / umPerCamPx;
            A = eye(3);
            A(1:2, 1:2) = R * S;

            m = tfp.gui.stepMetrics('lateral_dmd_camera', ...
                struct('dmdToSample_affine', A, 'umPerPixel', umPerCamPx), ...
                struct('handoff', h));

            testCase.verifyEqual(m.umPerPxFittedMin, h.um_per_px_groove, 'AbsTol', 1e-9);
            testCase.verifyEqual(m.umPerPxFittedMax, h.um_per_px_disp,   'AbsTol', 1e-9);
            % The handoff publishes the two scales and their ratio each
            % rounded to four decimals, so the ratio recomputed from the
            % scales differs from the published one in the fifth.
            testCase.verifyEqual(m.anamorphicFitted, h.anamorphic,       'RelTol', 1e-4);
            testCase.verifyTrue(m.scaleAgreesWithHandoff);

            % And the same affine with a 20% scale error must be caught.
            A(1:2, 1:2) = R * S * 1.2;
            m = tfp.gui.stepMetrics('lateral_dmd_camera', ...
                struct('dmdToSample_affine', A, 'umPerPixel', umPerCamPx), ...
                struct('handoff', h));
            testCase.verifyFalse(m.scaleAgreesWithHandoff);
        end

        function grooveFractionIsDiagnosticNotCosmetic(testCase)
            m = tfp.gui.stepMetrics('field_tilt', struct('fit', ...
                struct('aUmPerUm', 0.028, 'bUmPerUm', 0.014)));
            testCase.verifyEqual(m.grooveFraction, 0.5, 'RelTol', 1e-9);
        end

        function tiltSignDisagreementOnlyWarns(testCase)
            % Section 7.4 wins when the two disagree — the field-tilt sign was
            % always a proposal — so the disagreement is recorded, not fatal.
            step = testCase.stepFor('verify_tilt_sign');
            ctx = struct('results', struct('field_tilt', ...
                struct('depthGradientSign', 1)));
            result = struct('planeIdx', [1 2 2 3 3], 'depthGradientSign', -1);
            v = tfp.gui.stepVerdict(step, result, ctx);
            testCase.verifyEqual(v.verdict, 'warn');
            testCase.verifyTrue(v.canAdvance);

            % A row that never crosses a plane is not a sign measurement.
            flat = struct('planeIdx', [2 2 2 2 2], 'depthGradientSign', 1);
            v = tfp.gui.stepVerdict(step, flat, ctx);
            testCase.verifyEqual(v.verdict, 'fail');
        end
    end

    % =======================================================================
    methods (Access = private)

        function step = stepFor(testCase, id)
            steps = tfp.gui.bringupSteps();
            idx = find(strcmp({steps.id}, id), 1);
            testCase.assertNotEmpty(idx, sprintf('no step ''%s''', id));
            step = steps(idx);
        end

        function row = rowNamed(testCase, v, label)
            idx = find(strcmp({v.rows.label}, label), 1);
            testCase.assertNotEmpty(idx, sprintf('no check called ''%s''', label));
            row = v.rows(idx);
        end

        function r = goodTilt(~)
            r = struct();
            r.fit = struct('aUmPerUm', 0.02843, 'bUmPerUm', 0.0001, ...
                'cUm', 0, 'r2', 0.995);
            r.focusAtWindowEdge = false(1, 9);
            r.sanity = struct('gradientInBand', true, 'walkInBand', true, 'band', 0.5);
        end

        function c = powerCurveResult(~, volts, mw)
            c = struct('voltage', struct('voltageV', volts, 'powerMw', mw, ...
                'powerStdMw', 0.01 * max(mw) * ones(size(mw))));
        end
    end
end
