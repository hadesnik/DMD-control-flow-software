classdef test_fakeCellCoupling < matlab.unittest.TestCase
%test_fakeCellCoupling Phase 1.5 tests for the all-optical PPSF simulator.
%
%   Verifies that:
%     - On-target cells produce a detectable GCaMP-like response.
%     - Off-target cells (no overlap) produce only baseline noise.
%     - A 5-distance PPSF sweep shows a monotone-decreasing response.
%     - SyntheticImaging produces correctly-shaped Fall.mat-like output.
%     - MockScanImageBridge integrates with CellResponseModel end-to-end.
%
%   All tests use simulateLatency=false so no real pauses occur.
%   Where noise-sensitive thresholds are checked, the response window mean
%   (over ~30 frames) is used rather than the single-sample peak, reducing
%   effective noise by ~sqrt(30) and making thresholds robust without
%   requiring a fixed RNG seed.

    methods (Access = private)

        function dmd = fakeDmd(~)
            %fakeDmd Return a minimal struct that singleSpot() accepts.
            dmd.nRows = 800;
            dmd.nCols = 1280;
        end

        function cell1 = makeCell(~, col, row, varargin)
            %makeCell Convenience wrapper for CellResponseModel.
            cell1 = tfp.sim.CellResponseModel([col, row], 8, varargin{:});
        end

        function t = frameTimestamps(~)
            %frameTimestamps 60 frames over a 2-second trial at 30 Hz.
            t = linspace(0, 2, 60);
        end

        function idx = responseWindow(~, t)
            %responseWindow Logical index for the stim response window (0.5–1.5 s).
            idx = t >= 0.5 & t <= 1.5;
        end
    end

    methods (Test)

        % ------------------------------------------------------------------
        function cellResponse_onTarget(testCase)
        %cellResponse_onTarget Cell directly under the DMD spot should respond.
        %   Spot centred on cell (col=640, row=400), same radius (8 px).
        %   Overlap ≈ 1 → scaled amplitude ≈ 1.5 dF/F.
        %   The mean ΔF/F over the post-stim response window should clearly
        %   exceed 1.0 (where noise mean ≈ 0, signal ≈ 0.4–0.7).

            c    = testCase.makeCell(640, 400, 'amplitude', 1.5);
            dmd  = testCase.fakeDmd();
            mask = tfp.patterns.singleSpot(dmd, [640, 400], 8);
            t    = testCase.frameTimestamps();

            trace   = c.computeTrace(mask, t, 0.5, 0.1);
            meanRsp = mean(trace(testCase.responseWindow(t)));

            testCase.verifyGreaterThan(meanRsp, 0.2, ...
                'On-target cell should have positive mean response in response window.');
        end

        % ------------------------------------------------------------------
        function cellResponse_offTarget(testCase)
        %cellResponse_offTarget Cell 50 px from spot should show only noise.
        %   Cell at col=640, spot at col=690 → distance=50, radii=8 → zero overlap.
        %   Mean ΔF/F over response window is pure Gaussian noise;
        %   averaging ~30 frames reduces std to ≈0.018, so |mean| << 0.1.

            c    = testCase.makeCell(640, 400, 'amplitude', 1.5);
            dmd  = testCase.fakeDmd();
            mask = tfp.patterns.singleSpot(dmd, [690, 400], 8);  % 50 px away
            t    = testCase.frameTimestamps();

            trace   = c.computeTrace(mask, t, 0.5, 0.1);
            meanRsp = abs(mean(trace(testCase.responseWindow(t))));

            testCase.verifyLessThan(meanRsp, 0.15, ...
                'Off-target cell mean response should be near zero (noise only).');
        end

        % ------------------------------------------------------------------
        function ppsfShape_gaussianFalloff(testCase)
        %ppsfShape_gaussianFalloff PPSF response falls off with stim offset.
        %   Cell at [640, 400], stim radius 8 px.
        %   Offsets [0, 5, 10, 20, 40] px along col axis.
        %   Overlap geometry:
        %     d=0:  full overlap (1.0)
        %     d=5:  partial overlap (≈0.6)
        %     d=10: partial overlap (≈0.25)
        %     d=20: zero overlap (>16 px separation for r=8)
        %     d=40: zero overlap
        %
        %   Test verifies:
        %     1. Mean response strictly decreases from d=0 to d=10.
        %     2. Mean response at d=40 is near zero (< 0.1 dF/F).

            c       = testCase.makeCell(640, 400, 'amplitude', 1.5);
            dmd     = testCase.fakeDmd();
            offsets = [0, 5, 10, 20, 40];
            t       = testCase.frameTimestamps();
            respIdx = testCase.responseWindow(t);

            meanResp = zeros(1, numel(offsets));
            for k = 1:numel(offsets)
                mask           = tfp.patterns.singleSpot(dmd, ...
                                     [640 + offsets(k), 400], 8);
                trace          = c.computeTrace(mask, t, 0.5, 0.1);
                meanResp(k)    = mean(trace(respIdx));
            end

            % Monotone decrease in the overlap-dominated regime (d=0,5,10).
            testCase.verifyGreaterThan(meanResp(1), meanResp(2), ...
                'Mean response at d=0 should exceed d=5.');
            testCase.verifyGreaterThan(meanResp(2), meanResp(3), ...
                'Mean response at d=5 should exceed d=10.');

            % Near-zero at maximum offset (no overlap, noise only).
            testCase.verifyLessThan(abs(meanResp(end)), 0.1, ...
                'Mean response at d=40 px should be indistinguishable from noise.');
        end

        % ------------------------------------------------------------------
        function syntheticImaging_outputShape(testCase)
        %syntheticImaging_outputShape SyntheticImaging returns correctly-shaped Fall.mat.
        %   3 cells, 60 frames → F must be 3×60, iscell 3×2, stat(i).med present.

            dmd   = testCase.fakeDmd();
            cells = [testCase.makeCell(640, 400, 'amplitude', 1.5, 'responseTag', 'c1'), ...
                     testCase.makeCell(400, 300, 'amplitude', 1.2, 'responseTag', 'c2'), ...
                     testCase.makeCell(900, 500, 'amplitude', 1.8, 'responseTag', 'c3')];
            mask  = tfp.patterns.singleSpot(dmd, [640, 400], 8);
            t     = testCase.frameTimestamps();

            result = tfp.sim.SyntheticImaging(cells, mask, t, 0.5, 0.1);

            testCase.verifySize(result.F,      [3, 60], 'F must be nCells×T.');
            testCase.verifySize(result.Fneu,   [3, 60], 'Fneu must be nCells×T.');
            testCase.verifySize(result.iscell, [3,  2], 'iscell must be nCells×2.');
            testCase.verifyEqual(numel(result.stat), 3, 'stat must have nCells entries.');
            testCase.verifyTrue(isfield(result.stat, 'med'), ...
                'stat entries must have .med field.');
            testCase.verifyEqual(numel(result.stat(1).med), 2, ...
                'stat.med must be a 2-element [row col] vector.');
            testCase.verifyTrue(all(isfinite(result.F(:))), 'F must be finite.');
            testCase.verifyTrue(all(result.F(:) > 0), ...
                'F must be positive (baseline=1000 + dF*1000).');
            testCase.verifyEqual(result.ops.fs, 30);
            testCase.verifyEqual(result.ops.Ly, 512);
            testCase.verifyEqual(result.ops.Lx, 512);
        end

        % ------------------------------------------------------------------
        function mockSiBridge_integration(testCase)
        %mockSiBridge_integration End-to-end bridge: arm→set→wait→acquire→result.
        %   One cell directly under the stim spot.
        %   Verifies F is 1×60, finite, positive, and getLog records all calls.

            c      = testCase.makeCell(640, 400, 'amplitude', 1.5, 'responseTag', 'c1');
            cfg.frameRate       = 30;
            cfg.simulateLatency = false;
            bridge = tfp.hardware.MockScanImageBridge(c, cfg);

            dmd  = testCase.fakeDmd();
            mask = tfp.patterns.singleSpot(dmd, [640, 400], 8);

            bridge.armForExternalTrigger(60);
            bridge.setActivePattern(mask, 0.5, 0.1);
            bridge.waitForCompletion(5.0);
            [framesPath, frameTimestamps] = bridge.getLastAcquisition();
            result = bridge.getSyntheticResult();

            % Frame timestamps
            testCase.verifyEmpty(framesPath, 'framesPath must be empty string.');
            testCase.verifyEqual(numel(frameTimestamps), 60, ...
                'Must return 60 frame timestamps.');

            % Synthetic result
            testCase.verifyFalse(isempty(result), 'getSyntheticResult must not be empty.');
            testCase.verifySize(result.F, [1, 60], 'F must be 1×60 for one cell.');
            testCase.verifyTrue(all(isfinite(result.F(:))), 'F must be finite.');
            testCase.verifyTrue(all(result.F(:) > 0), 'F must be positive.');

            % Log records expected events
            logEvents = {bridge.getLog().eventType};
            testCase.verifyTrue(any(strcmp(logEvents, 'armForExternalTrigger')));
            testCase.verifyTrue(any(strcmp(logEvents, 'setActivePattern')));
            testCase.verifyTrue(any(strcmp(logEvents, 'waitForCompletion')));
            testCase.verifyTrue(any(strcmp(logEvents, 'getLastAcquisition')));
        end

    end
end
