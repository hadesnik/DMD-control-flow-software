classdef test_slm_dispatch < matlab.unittest.TestCase
%test_slm_dispatch Unit tests for tfp.io.slmDispatch.
%
%   Tests each supported op using a MockSLM initialised with small dims
%   ([256 256]) so CGH computation is fast.  ctx.params carries the merged
%   defaultParams plus the three validation fields so validateSLMTargets
%   can read them.

    properties
        slm     % tfp.hardware.MockSLM
        ctx     % struct(params, calib, effMap)
    end

    methods (TestMethodSetup)
        function buildFixture(tc)
            % Small dims for speed.
            slmCfg.dims               = [256 256];
            slmCfg.pitch_um           = 17;
            slmCfg.lambda_nm          = 1030;
            slmCfg.f_ft_um            = 16800;
            slmCfg.mag                = 1;
            slmCfg.n                  = 1.33;
            slmCfg.gsIters            = 8;
            slmCfg.gsWeighted         = true;
            slmCfg.gsSeed             = 0;

            % Build merged params (defaultParams + validation fields).
            params                    = tfp.patterns.threeDShot.defaultParams(slmCfg);
            params.maxCells            = 20;
            params.addressableRadiusUm = 1e6;  % effectively unlimited
            params.minSpacingUm        = 0;

            % Identity calibration and uniform efficiency map.
            calib  = tfp.patterns.threeDShot.loadSLMScanCalibration('');
            effMap = tfp.patterns.threeDShot.loadEfficiencyMap('');

            tc.ctx = struct('params', params, 'calib', calib, 'effMap', effMap);

            % MockSLM must be initialised with the SAME dims so mask shape matches.
            tc.slm = tfp.hardware.MockSLM();
            tc.slm.initialize(slmCfg);
        end
    end

    % --------------------------------------------------------------------- %
    methods (Test)

        function test_projectTargets_ok(tc)
            % Single centroid at the origin; should complete without error.
            payload  = [0, 0];   % 1×2 SI centroid (µm)
            reply    = tfp.io.slmDispatch(tc.slm, tc.ctx, 'projectTargets', payload);

            tc.verifyTrue(reply.ok, 'reply.ok should be true');
            tc.verifyEqual(reply.op, 'projectTargets');
            tc.verifyEqual(reply.nAccepted, 1);
            tc.verifyTrue(isnumeric(reply.perCellDeliveredFraction), ...
                'perCellDeliveredFraction must be numeric');
            tc.verifyTrue(isnumeric(reply.etaEffective), ...
                'etaEffective must be numeric');
            tc.verifyTrue(isfinite(reply.perCellDeliveredFraction), ...
                'perCellDeliveredFraction must be finite');
        end

        function test_projectTargets_slm_presenting(tc)
            % After projectTargets the MockSLM should be in 'presenting' state
            % with a uint8 mask of the right size.
            payload = [10, -5; -10, 5];   % 2×2 centroids
            tfp.io.slmDispatch(tc.slm, tc.ctx, 'projectTargets', payload);

            status = tc.slm.getStatus();
            tc.verifyEqual(status.state, 'presenting');

            mask = tc.slm.getActivePattern();
            tc.verifyClass(mask, 'uint8');
            expectedDims = [tc.ctx.params.Ny, tc.ctx.params.Nx];  % [nRows nCols]
            tc.verifyEqual(size(mask), expectedDims);
        end

        function test_projectTargets_multi_cell(tc)
            % 3 cells; nAccepted should be 3 given unlimited radius.
            payload  = [0 0; 5 0; -5 0];
            reply    = tfp.io.slmDispatch(tc.slm, tc.ctx, 'projectTargets', payload);
            tc.verifyTrue(reply.ok);
            tc.verifyEqual(reply.nAccepted, 3);
        end

        function test_blank_ok(tc)
            reply = tfp.io.slmDispatch(tc.slm, tc.ctx, 'blank', []);
            tc.verifyTrue(reply.ok);
            tc.verifyEqual(reply.op, 'blank');
        end

        function test_blank_zeros_mask(tc)
            % After blank, getActivePattern should be all-zero uint8.
            tfp.io.slmDispatch(tc.slm, tc.ctx, 'blank', []);
            mask = tc.slm.getActivePattern();
            tc.verifyClass(mask, 'uint8');
            tc.verifyTrue(all(mask(:) == 0), 'blank mask must be all zeros');
        end

        function test_slmPower_ok(tc)
            reply = tfp.io.slmDispatch(tc.slm, tc.ctx, 'slmPower', true);
            tc.verifyTrue(reply.ok);
            tc.verifyEqual(reply.op, 'slmPower');
            status = tc.slm.getStatus();
            tc.verifyTrue(status.powerOn);
        end

        function test_slmPower_off(tc)
            tfp.io.slmDispatch(tc.slm, tc.ctx, 'slmPower', true);
            tfp.io.slmDispatch(tc.slm, tc.ctx, 'slmPower', false);
            status = tc.slm.getStatus();
            tc.verifyFalse(status.powerOn);
        end

        function test_ping_ok(tc)
            reply = tfp.io.slmDispatch(tc.slm, tc.ctx, 'ping', []);
            tc.verifyTrue(reply.ok);
            tc.verifyEqual(reply.op, 'ping');
            tc.verifyTrue(isfield(reply, 'status'), 'ping reply must carry status');
        end

        function test_shutdown_ok(tc)
            reply = tfp.io.slmDispatch(tc.slm, tc.ctx, 'shutdown', []);
            tc.verifyTrue(reply.ok);
            tc.verifyEqual(reply.op, 'shutdown');
            tc.verifyTrue(reply.shutdown);
        end

        function test_unknown_op_returns_not_ok(tc)
            reply = tfp.io.slmDispatch(tc.slm, tc.ctx, 'notAnOp', []);
            tc.verifyFalse(reply.ok, 'unknown op must return ok=false');
            tc.verifyEqual(reply.op, 'notAnOp');
            tc.verifyTrue(isfield(reply, 'error'), 'reply must carry error field');
        end

        function test_error_caught_returns_struct(tc)
            % Pass a nil SLM so any op that touches slm will throw.
            badSlm = struct();   % not an SLM — calling .blank() will fail
            reply  = tfp.io.slmDispatch(badSlm, tc.ctx, 'blank', []);
            tc.verifyFalse(reply.ok, 'error path must return ok=false');
            tc.verifyTrue(isfield(reply, 'error'));
        end

    end % methods (Test)
end
