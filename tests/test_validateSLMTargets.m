classdef test_validateSLMTargets < matlab.unittest.TestCase
%test_validateSLMTargets Unit tests for tfp.util.validateSLMTargets.
%
%   Covers:
%     - Valid central set returned unchanged (N×3)
%     - N×2 input coerced to N×3 with z=0
%     - Targets beyond addressableRadiusUm are dropped
%     - All-outside → :noTargetsInField error
%     - Pairs below minSpacingUm are greedily rejected (later dropped)
%     - Cap to maxCells
%     - Bad shape → :badTargets error
%     - Correct error namespace via callerId

    methods (Test)

        function testValidCentralSetReturnedUnchanged(tc)
            % All targets near origin, well within any reasonable radius.
            targets = [0 0 0; 5 5 0; -5 -5 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [3 3]);
            tc.verifyEqual(out, targets, 'AbsTol', 1e-10);
        end

        function testCoerce2DTo3D(tc)
            % N×2 input: z column must be appended as zeros.
            targets = [1 2; 3 4; -1 -2];
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [3 3]);
            tc.verifyEqual(out(:,1:2), targets, 'AbsTol', 1e-10);
            tc.verifyEqual(out(:,3), zeros(3,1), 'AbsTol', 1e-10);
        end

        function testDropBeyondRadius(tc)
            % Only the target at origin survives; the others are too far.
            targets = [0 0; 200 0; 0 200];  % N×2
            p = struct('maxCells', 20, 'addressableRadiusUm', 50, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [1 3]);
            tc.verifyEqual(out(1,1), 0, 'AbsTol', 1e-10);
            tc.verifyEqual(out(1,2), 0, 'AbsTol', 1e-10);
        end

        function testAllOutsideRadiusThrows(tc)
            targets = [300 0; 0 300; -300 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', 50, ...
                       'minSpacingUm', 0);
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets(targets, p, 'myExperiment'), ...
                'tfp:experiments:myExperiment:noTargetsInField');
        end

        function testCallerIdInErrorId(tc)
            % Confirm the callerId is correctly embedded in the error identifier.
            targets = [999 999];
            p = struct('maxCells', 20, 'addressableRadiusUm', 10, ...
                       'minSpacingUm', 0);
            try
                tfp.util.validateSLMTargets(targets, p, 'customCaller');
                tc.verifyFail('Expected an error to be thrown.');
            catch ME
                tc.verifyEqual(ME.identifier, ...
                    'tfp:experiments:customCaller:noTargetsInField');
            end
        end

        function testMinSpacingGreedyReject(tc)
            % Three collinear points at x = 0, 5, 10 µm, minSpacingUm = 8.
            % Greedy thinning keeps a point unless it is too close to an
            % already-ACCEPTED point: [0] is kept; [5] is 5 µm from [0] (<8)
            % so rejected; [10] is 10 µm from [0] (>=8) so kept. The rejected
            % [5] is not an anchor, so the survivors are [0] and [10].
            targets = [0 0; 5 0; 10 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 8);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [2 3]);
            tc.verifyEqual(out(:,1:2), [0 0; 10 0], 'AbsTol', 1e-10);
        end

        function testMinSpacingKeepsWellSeparated(tc)
            % Four targets, each separated by > 20 µm — all should survive.
            targets = [0 0; 30 0; 60 0; 90 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 20);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [4 3]);
        end

        function testMinSpacingExact(tc)
            % Targets exactly at minSpacingUm apart should be KEPT (strict <).
            targets = [0 0; 10 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 10);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            % distance == minSpacingUm (not strictly less), so both kept.
            tc.verifySize(out, [2 3]);
        end

        function testCapAtMaxCells(tc)
            % 10 targets, maxCells=4 → only first 4 returned.
            N = 10;
            targets = [(1:N)', zeros(N,1)];
            p = struct('maxCells', 4, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [4 3]);
            tc.verifyEqual(out(:,1), (1:4)', 'AbsTol', 1e-10);
        end

        function testDefaultParamsFallback(tc)
            % slmParams with no recognized fields → all defaults apply.
            % Default maxCells=20, radius=Inf, spacing=0.
            targets = rand(25, 2) * 10;  % 25 targets, all central
            out = tfp.util.validateSLMTargets(targets, struct(), 'testCaller');
            % Should be capped to 20.
            tc.verifySize(out, [20 3]);
        end

        function testBadShapeVector(tc)
            % 1-D input is not a valid target matrix.
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets([1 2 3 4], struct(), 'c'), ...
                'tfp:experiments:c:badTargets');
        end

        function testBadShapeNx1(tc)
            % N×1 is not valid (needs at least 2 columns).
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets([1;2;3], struct(), 'c'), ...
                'tfp:experiments:c:badTargets');
        end

        function testBadShapeNx4(tc)
            % N×4 is not valid.
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets([1 2 3 4; 5 6 7 8], struct(), 'c'), ...
                'tfp:experiments:c:badTargets');
        end

        function testBadShapeNonNumeric(tc)
            % Cell array should throw :badTargets.
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets({'a','b'}, struct(), 'c'), ...
                'tfp:experiments:c:badTargets');
        end

        function testOutputIsDouble(tc)
            targets = int16([0 0; 5 5]);  % integer input
            p = struct('maxCells', 20, 'addressableRadiusUm', Inf, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifyClass(out, 'double');
        end

        function testRadiusExactBoundary(tc)
            % Target at exactly the radius should be KEPT (≤ not <).
            targets = [50 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', 50, ...
                       'minSpacingUm', 0);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            tc.verifySize(out, [1 3]);
        end

        function testRadiusJustOutside(tc)
            % Target at radius+eps should be dropped → noTargetsInField.
            r = 50;
            targets = [r + 0.001, 0];
            p = struct('maxCells', 20, 'addressableRadiusUm', r, ...
                       'minSpacingUm', 0);
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets(targets, p, 'testCaller'), ...
                'tfp:experiments:testCaller:noTargetsInField');
        end

        function testBadTargetsIdForBadShape(tc)
            % Check the specific error id used for shape failures.
            tc.verifyError( ...
                @() tfp.util.validateSLMTargets([], struct(), 'myCaller'), ...
                'tfp:experiments:myCaller:badTargets');
        end

        function testCombinedRadiusAndSpacing(tc)
            % Mix: some targets outside radius, some too close to each other.
            % Keep only the ones that pass BOTH filters.
            targets = [0 0;     % keep
                       200 0;   % drop (radius=50)
                       3 0;     % drop (too close to row 1, spacing=5)
                       30 0];   % keep (radius OK, spaced from row 1)
            p = struct('maxCells', 20, 'addressableRadiusUm', 50, ...
                       'minSpacingUm', 5);
            out = tfp.util.validateSLMTargets(targets, p, 'testCaller');
            % After radius filter: rows 1,3,4 → [0 0], [3 0], [30 0]
            % After spacing (5 µm): [0 0] kept; [3 0] is 3 µm away → drop;
            %                       [30 0] is 30 µm from [0 0] → keep.
            tc.verifySize(out, [2 3]);
            tc.verifyEqual(out(1,1:2), [0 0], 'AbsTol', 1e-10);
            tc.verifyEqual(out(2,1:2), [30 0], 'AbsTol', 1e-10);
        end

    end % methods Test

end % classdef
