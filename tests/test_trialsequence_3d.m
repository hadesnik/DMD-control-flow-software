classdef test_trialsequence_3d < matlab.unittest.TestCase
    %test_trialsequence_3d generate3DEnsemble depth-group math + the
    %   group-preserving shuffle.

    methods (Access = private)
        function [seq, groups, targets, consts] = makeSeq(~, varargin)
            consts = tfp.util.readHandoffConstants();
            % Three targets spread laterally, each in a DIFFERENT plane
            % than its tilt-native depth — so required defocus values
            % genuinely differ (a cell sitting exactly on the tilted
            % excitation plane needs ~zero correction and would collapse
            % the grouping).
            targets = [400, 400, 3, 15; 640, 400, 2, 0; 900, 400, 1, -15];
            opts = struct('dmdSize', [800, 1280], 'dzBinUm', 10, ...
                'nReps', 2, 'powerMw', 5, 'gradientSign', 1);
            for k = 1:2:numel(varargin)
                opts.(varargin{k}) = varargin{k+1};
            end
            [seq, groups] = tfp.trial.TrialSequence.generate3DEnsemble( ...
                targets, opts);
        end
    end

    methods (Test)

        function dzComputationUsesTiltAtRuntime(testCase)
            [seq, groups, targets, consts] = testCase.makeSeq();
            % Recompute the expected per-target dz by hand.
            xDisp = tfp.optics.dmdToDispersionUm(targets(:, 1:2), [800, 1280]);
            dzExp = targets(:, 4) - consts.depth_gradient_um_per_um * xDisp;

            % Every trial's group defocus == mean of its members' dz, and
            % member residuals are consistent.
            for k = 1:numel(seq.trials)
                md   = seq.trials(k).metadata;
                rows = md.targetRows;
                testCase.verifyEqual(md.slmDefocusUm, mean(dzExp(rows)), ...
                    'AbsTol', 1e-9);
                testCase.verifyEqual(md.dzResidualUm, ...
                    (dzExp(rows) - md.slmDefocusUm)', 'AbsTol', 1e-9);
                % Residuals bounded by the bin width.
                testCase.verifyLessThanOrEqual(max(abs(md.dzResidualUm)), 10);
            end
            % Groups cover all targets exactly once.
            allRows = sort([groups.targetRows]);
            testCase.verifyEqual(allRows, 1:size(targets, 1));
        end

        function orderingIsRepOuterGroupInner(testCase)
            [seq, groups] = testCase.makeSeq();
            G = numel(groups);
            ids = arrayfun(@(t) t.metadata.slmGroupIdx, seq.trials)';
            testCase.verifyEqual(ids, repmat(1:G, 1, 2), ...
                'trials must walk groups in SLM sequence order, rep-outer');
            % groups.dzUm ascend (sorted bins) — the SLM preload order.
            testCase.verifyTrue(issorted([groups.dzUm]));
        end

        function binWidthControlsGroupCount(testCase)
            % A huge bin folds everything into one group.
            [~, groupsWide] = testCase.makeSeq('dzBinUm', 1000);
            testCase.verifyEqual(numel(groupsWide), 1);
            % A tiny bin gives one group per distinct dz.
            [~, groupsFine] = testCase.makeSeq('dzBinUm', 0.5);
            testCase.verifyEqual(numel(groupsFine), 3);
        end

        function planeZLookupFillsNaN(testCase)
            targets = [400, 400, 1, NaN; 900, 400, 3, NaN];
            opts = struct('dmdSize', [800, 1280], ...
                'planeZUm', [-17, 0, 18], 'nReps', 1);
            [seq, ~] = tfp.trial.TrialSequence.generate3DEnsemble(targets, opts);
            z = [seq.trials.metadata];
            zAll = sort([z.zTargetUm]);
            testCase.verifyEqual(zAll, [-17, 18]);

            % Without the lookup, NaN depths must error.
            testCase.verifyError(@() tfp.trial.TrialSequence.generate3DEnsemble( ...
                targets, struct('dmdSize', [800, 1280])), ...
                'tfp:trial:TrialSequence:missingZ');
        end

        function shuffleWithinGroupsPreservesBlocks(testCase)
            % Build a sequence with 3 trials per group so blocks are real:
            % duplicate each target 3x at the same depth.
            base = [400, 400, 1, -15; 640, 400, 2, 0; 900, 400, 3, 15];
            [seq, ~] = tfp.trial.TrialSequence.generate3DEnsemble(base, ...
                struct('dmdSize', [800, 1280], 'nReps', 4));

            idsBefore = arrayfun(@(t) t.metadata.slmGroupIdx, seq.trials)';
            seq.shuffleWithinGroups(42);
            idsAfter  = arrayfun(@(t) t.metadata.slmGroupIdx, seq.trials)';
            % Group order at each position is untouched (blocks of size 1
            % here — rep-outer means groups alternate — so idsAfter must
            % EQUAL idsBefore).
            testCase.verifyEqual(idsAfter, idsBefore);
            testCase.verifyEqual(seq.randSeed, 42);

            % Reproducibility.
            [seq2, ~] = tfp.trial.TrialSequence.generate3DEnsemble(base, ...
                struct('dmdSize', [800, 1280], 'nReps', 4));
            seq2.shuffleWithinGroups(42);
            t1 = arrayfun(@(t) t.trialIdx, seq.trials);
            t2 = arrayfun(@(t) t.trialIdx, seq2.trials);
            testCase.verifyEqual(t1, t2);

            % Block shuffling keeps runs contiguous.
            seq3 = tfp.trial.TrialSequence.generate3DEnsemble(base, ...
                struct('dmdSize', [800, 1280], 'nReps', 1));
            seq3.shuffleWithinGroups(7, struct('shuffleBlocks', true));
            ids3 = arrayfun(@(t) t.metadata.slmGroupIdx, seq3.trials)';
            % Every group appears exactly once (blocks intact, order free).
            testCase.verifyEqual(sort(ids3), 1:numel(unique(ids3)));

            % Plain shuffle-within on a non-grouped sequence errors.
            plain = tfp.trial.TrialSequence.generatePowerCurve([640 400], ...
                [1 2], 1);
            testCase.verifyError(@() plain.shuffleWithinGroups(1), ...
                'tfp:trial:TrialSequence:noGroups');
        end

        function inputValidation(testCase)
            testCase.verifyError(@() tfp.trial.TrialSequence.generate3DEnsemble( ...
                [1 2 3], struct('dmdSize', [800 1280])), ...
                'tfp:trial:TrialSequence:badTargets');
            testCase.verifyError(@() tfp.trial.TrialSequence.generate3DEnsemble( ...
                [1 2 3 4], struct()), ...
                'tfp:trial:TrialSequence:badOpts');
        end
    end
end
