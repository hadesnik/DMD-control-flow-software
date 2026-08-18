classdef test_bridge_multiplane_mock < matlab.unittest.TestCase
    %test_bridge_multiplane_mock Free-run 3D session on the mock bridge:
    %   plane-selective synthetic F, setActiveDefocus plumbing, and the
    %   axial response factor in CellResponseModel.

    methods (Test)

        function freeRunSessionShape(testCase)
            b = tfp.hardware.MockScanImageBridge({}, struct());
            info = b.beginFreeRunSession(3);
            testCase.verifyTrue(info.freeRun);
            testCase.verifyEqual(info.nPlanes, 3);
            testCase.verifyEqual(numel(info.planeZUm), 3);
            shape = b.getVolumeShape();
            testCase.verifyEqual(shape.nPlanes, 3);
        end

        function planeSelectiveVisibility(testCase)
            % One cell at plane 1's depth, one at plane 3's: each cell's
            % response must appear (mostly) in its own plane's frames.
            planeZ = [-15, 0, 15];
            cellA = tfp.sim.CellResponseModel([200 200], 8, ...
                'positionZUm', -15, 'sigmaZ', 14, 'amplitude', 2);
            cellB = tfp.sim.CellResponseModel([600 400], 8, ...
                'positionZUm',  15, 'sigmaZ', 14, 'amplitude', 2);
            b = tfp.hardware.MockScanImageBridge({cellA, cellB}, struct( ...
                'frameRate', 30, 'planeZUm', planeZ, 'imagingSigmaZUm', 5));
            b.beginFreeRunSession(3);
            b.noteTrialFrames(30);
            b.setActiveDefocus(-15, struct('gradientUmPerUm', 0, ...
                'gradientSign', 1));
            % Stimulate cell A's location only.
            mask = false(800, 1280);
            mask(195:205, 195:205) = true;
            b.setActivePattern(mask, 0.1, 0.1);
            b.getLastAcquisition();
            r = b.getSyntheticResult();

            planeOf = tfp.io.assignFramePlanes(1:30, 3);
            BASELINE = 1000;
            respA = double(r.F(1, :)) - BASELINE;
            % Cell A responds, and its response lives in plane-1 frames.
            inPlane  = mean(abs(respA(planeOf == 1)));
            offPlane = mean(abs(respA(planeOf == 3)));
            testCase.verifyGreaterThan(inPlane, 3 * offPlane);
            % Cell B (unstimulated, far away laterally) stays near baseline.
            respB = double(r.F(2, :)) - BASELINE;
            testCase.verifyLessThan(max(abs(respB)), 0.5 * max(abs(respA)));
        end

        function axialFactorGatesResponse(testCase)
            % Direct CellResponseModel check: identical lateral stim, right
            % vs wrong commanded defocus.
            cell = tfp.sim.CellResponseModel([640 400], 8, ...
                'positionZUm', 20, 'sigmaZ', 10, 'amplitude', 2);
            mask = false(800, 1280);
            mask(395:405, 635:645) = true;
            ts = linspace(0, 2, 60);

            zGood = struct('commandedDefocusUm', 20, ...
                'gradientUmPerUm', 0, 'gradientSign', 1);
            zBad  = struct('commandedDefocusUm', -20, ...
                'gradientUmPerUm', 0, 'gradientSign', 1);

            % Average response windows over reps to beat the 0.10 noise
            % (test_fakeCellCoupling convention).
            nRep = 5;
            good = 0; bad = 0;
            for k = 1:nRep
                tg = cell.computeTrace(mask, ts, 0.2, 0.2, zGood);
                tb = cell.computeTrace(mask, ts, 0.2, 0.2, zBad);
                good = good + mean(tg(ts > 0.3 & ts < 1.0));
                bad  = bad  + mean(tb(ts > 0.3 & ts < 1.0));
            end
            good = good / nRep; bad = bad / nRep;
            % zBad is 40 um off at sigmaZ 10 -> factor exp(-8) ~ 0: the
            % wrong-depth response must be an order of magnitude smaller.
            testCase.verifyGreaterThan(good, 0.3);
            testCase.verifyLessThan(abs(bad), good / 5);
        end

        function nearestBlobCentroidFixS11(testCase)
            % Two-blob pattern: one blob ON the cell, one 400 px away. The
            % old pattern-OR centroid landed between them (~200 px off ->
            % zero response); the nearest-blob rule must give a full response.
            cell = tfp.sim.CellResponseModel([300 400], 8, ...
                'amplitude', 2, 'sigma', 10);
            mask = false(800, 1280);
            mask(395:405, 295:305) = true;   % on the cell
            mask(395:405, 695:705) = true;   % far blob
            ts = linspace(0, 2, 60);
            resp = 0;
            for k = 1:5
                tr = cell.computeTrace(mask, ts, 0.2, 0.2);
                resp = resp + mean(tr(ts > 0.3 & ts < 1.0));
            end
            resp = resp / 5;
            testCase.verifyGreaterThan(resp, 0.3, ...
                'nearest-blob centroid fix (S11) not effective');
        end
    end
end
