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

        function trial_stateTransitions(testCase)
            % pending -> running
            t = tfp.trial.Trial();
            testCase.verifyEqual(t.status, 'pending');
            t.markRunning();
            testCase.verifyEqual(t.status, 'running');

            % running -> complete with data payload
            t2 = tfp.trial.Trial();
            t2.markRunning();
            t2.markComplete(struct('foo', 1));
            testCase.verifyEqual(t2.status, 'complete');
            testCase.verifyEqual(t2.data.foo, 1);

            % pending -> failed via MException
            t3 = tfp.trial.Trial();
            me = MException('my:err', 'oops');
            t3.markFailed(me);
            testCase.verifyEqual(t3.status, 'failed');
            testCase.verifyEqual(t3.data.error.identifier, 'my:err');
            testCase.verifyEqual(t3.data.error.message, 'oops');

            % pending -> failed via string
            t4 = tfp.trial.Trial();
            t4.markFailed('boom');
            testCase.verifyEqual(t4.status, 'failed');
            testCase.verifyEqual(t4.data.error.message, 'boom');

            % invalid: complete -> running
            t5 = tfp.trial.Trial();
            t5.markComplete([]);
            testCase.verifyError(@() t5.markRunning(), ...
                'tfp:trial:Trial:badTransition');

            % invalid: failed -> complete
            t6 = tfp.trial.Trial();
            t6.markFailed('e');
            testCase.verifyError(@() t6.markComplete([]), ...
                'tfp:trial:Trial:badTransition');
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

        function generatePPSF_2d(testCase)
            target  = [400, 400];
            offsets = [-5 -5; -5 0; -5 5; 0 -5; 0 0; 0 5; 5 -5; 5 0; 5 5];
            nReps   = 2;
            seq = tfp.trial.TrialSequence.generatePPSF( ...
                target, offsets, nReps, 5.0);

            nExpected = size(offsets, 1) * nReps;
            testCase.verifyEqual(numel(seq.trials), nExpected);

            % Every trial has offsetUm (1x2) and distanceUm = norm(offsetUm).
            for k = 1:numel(seq.trials)
                off  = seq.trials(k).metadata.offsetUm;
                testCase.verifySize(off, [1 2]);
                dist = seq.trials(k).metadata.distanceUm;
                testCase.verifyEqual(dist, norm(off), 'AbsTol', 1e-10);
            end

            % Each offset appears exactly nReps times.
            for o = 1:size(offsets, 1)
                count = 0;
                for k = 1:numel(seq.trials)
                    off = seq.trials(k).metadata.offsetUm;
                    if abs(off(1) - offsets(o,1)) < 1e-9 && ...
                            abs(off(2) - offsets(o,2)) < 1e-9
                        count = count + 1;
                    end
                end
                testCase.verifyEqual(count, nReps, ...
                    sprintf('offset [%g %g] count', offsets(o,1), offsets(o,2)));
            end
        end

        function gaussianGrid2D_properties(testCase)
            grid = tfp.trial.TrialSequence.gaussianGrid2D(20, 2, 8);

            % Nx2 matrix with more than one row.
            testCase.verifyEqual(size(grid, 2), 2);
            testCase.verifyGreaterThan(size(grid, 1), 1);

            % [0 0] is always included.
            hasOrigin = any(grid(:,1) == 0 & grid(:,2) == 0);
            testCase.verifyTrue(hasOrigin, '[0 0] must be in grid.');

            % Symmetric: every [dx dy] has a [-dx -dy] counterpart.
            for k = 1:size(grid, 1)
                dx = grid(k,1); dy = grid(k,2);
                mirror = any(abs(grid(:,1)+dx) < 1e-9 & abs(grid(:,2)+dy) < 1e-9);
                testCase.verifyTrue(mirror, ...
                    sprintf('[%g %g] has no symmetric counterpart', dx, dy));
            end

            % Feed directly into generatePPSF.
            target = [400, 400];
            nReps  = 2;
            seq = tfp.trial.TrialSequence.generatePPSF(target, grid, nReps, 5.0);
            testCase.verifyEqual(numel(seq.trials), size(grid, 1) * nReps);
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
