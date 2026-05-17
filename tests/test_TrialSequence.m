classdef test_TrialSequence < matlab.unittest.TestCase
    %test_TrialSequence Phase 1 Trial + TrialSequence tests.

    methods (Test)
        function trial_defaults(testCase)
            t = tfp.trial.Trial();
            testCase.verifyEqual(t.status, 'pending');
            testCase.verifyTrue(isnat(t.timestamp));
            testCase.verifyEmpty(t.data);
            testCase.verifyEqual(t.sessionId, '');
        end

        function generatePPSF_dimensions(testCase)
            targets     = [200, 200; 800, 400];
            distancesUm = [0, 5, 10, 20];
            nReps       = 3;
            powerMw     = 5.0;
            seq = tfp.trial.TrialSequence.generatePPSF( ...
                targets, distancesUm, nReps, powerMw);

            nExpected = size(targets, 1) * numel(distancesUm) * nReps;
            testCase.verifyEqual(numel(seq.trials), nExpected);

            % Every trial carries the requested power.
            for k = 1:numel(seq.trials)
                testCase.verifyEqual(seq.trials(k).powerMw, powerMw);
            end

            % Each input distance appears nTargets * nReps times.
            allDistances = arrayfun(@(t) t.metadata.distanceUm, seq.trials);
            for d = distancesUm
                count = sum(allDistances == d);
                testCase.verifyEqual(count, size(targets, 1) * nReps, ...
                    sprintf('distance %g count', d));
            end

            % Every trial's dmdCoords is one of the input targets.
            for k = 1:numel(seq.trials)
                tc = seq.trials(k).targetSpec.dmdCoords;
                testCase.verifyEqual(numel(tc), 2);
                hits = sum(targets(:,1) == tc(1) & targets(:,2) == tc(2));
                testCase.verifyGreaterThan(hits, 0, ...
                    sprintf('trial %d dmdCoords [%g %g] not in input targets', ...
                        k, tc(1), tc(2)));
            end

            % trialIdx is 1..nExpected before shuffling.
            indices = [seq.trials.trialIdx];
            testCase.verifyEqual(indices, 1:nExpected);
        end

        function generateRapidSequential_ordering(testCase)
            targets = [100, 100; 200, 200; 300, 300];
            isi_s   = 0.5;
            nReps   = 4;
            seq = tfp.trial.TrialSequence.generateRapidSequential( ...
                targets, isi_s, nReps);

            nExpected = size(targets, 1) * nReps;
            testCase.verifyEqual(numel(seq.trials), nExpected);

            % Each target appears exactly nReps times.
            for tIdx = 1:size(targets, 1)
                count = 0;
                for k = 1:numel(seq.trials)
                    if isequal(seq.trials(k).targetSpec.dmdCoords, targets(tIdx, :))
                        count = count + 1;
                    end
                end
                testCase.verifyEqual(count, nReps, ...
                    sprintf('target row %d count', tIdx));
            end

            % ISI propagated identically.
            for k = 1:numel(seq.trials)
                testCase.verifyEqual(seq.trials(k).metadata.isi_s, isi_s);
            end

            indices = [seq.trials.trialIdx];
            testCase.verifyEqual(indices, 1:nExpected);
        end

        function generatePowerCurve_powerVaries(testCase)
            target   = [500, 400];
            powersMw = [1, 2, 4, 8, 16];
            nReps    = 3;
            seq = tfp.trial.TrialSequence.generatePowerCurve( ...
                target, powersMw, nReps);

            nExpected = numel(powersMw) * nReps;
            testCase.verifyEqual(numel(seq.trials), nExpected);

            % Same target every trial.
            for k = 1:numel(seq.trials)
                testCase.verifyEqual(seq.trials(k).targetSpec.dmdCoords, target, ...
                    sprintf('trial %d target', k));
            end

            % Each input power appears nReps times.
            allPowers = arrayfun(@(t) t.powerMw, seq.trials);
            for p = powersMw
                count = sum(allPowers == p);
                testCase.verifyEqual(count, nReps);
            end
        end

        function shuffle_reproducible(testCase)
            targets     = [100, 100; 200, 200; 300, 300];
            distancesUm = [0, 5, 10];

            seq1 = tfp.trial.TrialSequence.generatePPSF(targets, distancesUm, 2, 5.0);
            seq1.shuffle(42);
            order1 = [seq1.trials.trialIdx];

            seq2 = tfp.trial.TrialSequence.generatePPSF(targets, distancesUm, 2, 5.0);
            seq2.shuffle(42);
            order2 = [seq2.trials.trialIdx];

            testCase.verifyEqual(order1, order2, ...
                'Same seed must produce same permutation.');

            seq3 = tfp.trial.TrialSequence.generatePPSF(targets, distancesUm, 2, 5.0);
            seq3.shuffle(99);
            order3 = [seq3.trials.trialIdx];

            testCase.verifyNotEqual(order3, order1, ...
                'Different seed should produce different permutation (collision astronomically unlikely with 18 trials).');

            testCase.verifyEqual(seq1.randSeed, 42);
            testCase.verifyEqual(seq3.randSeed, 99);

            % Length preserved by shuffle.
            testCase.verifyEqual(numel(seq1.trials), numel(seq2.trials));
        end
    end
end
