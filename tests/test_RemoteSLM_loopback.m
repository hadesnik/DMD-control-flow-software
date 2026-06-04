classdef test_RemoteSLM_loopback < matlab.unittest.TestCase
%test_RemoteSLM_loopback Unit tests for tfp.hardware.RemoteSLM in loopback mode.
%
%   Uses small SLM dims (128×128) and 6 GS iterations for fast execution.
%   Tests loopback (in-process MockSLM dispatch) and 'mock' mode alias.
%   No network is involved.

    properties
        cfg     % base config used to build RemoteSLM
    end

    methods (TestMethodSetup)
        function buildConfig(tc)
            tc.cfg.connectionMode      = 'loopback';
            tc.cfg.dims                = [128 128];   % [nCols nRows] — small
            tc.cfg.pitch_um            = 17;
            tc.cfg.lambda_nm           = 1030;
            tc.cfg.f_ft_um             = 16800;
            tc.cfg.mag                 = 1;
            tc.cfg.n                   = 1.33;
            tc.cfg.gsIters             = 6;
            tc.cfg.gsWeighted          = true;
            tc.cfg.gsSeed              = 0;
            tc.cfg.maxCells            = 20;
            tc.cfg.addressableRadiusUm = 1e6;   % effectively unlimited
            tc.cfg.minSpacingUm        = 0;
            tc.cfg.slmScanCalib_file   = '';
            tc.cfg.efficiencyMap_file  = '';
        end
    end

    % --------------------------------------------------------------------- %
    methods (Test)

        function test_loopback_initialize(tc)
            slm = tfp.hardware.RemoteSLM(tc.cfg);
            slm.initialize(tc.cfg);
            tc.verifyTrue(slm.isInitialized);
            tc.verifyEqual(slm.nCols, 128);
            tc.verifyEqual(slm.nRows, 128);
        end

        function test_mock_alias_for_loopback(tc)
            cfg2                = tc.cfg;
            cfg2.connectionMode = 'mock';
            slm = tfp.hardware.RemoteSLM(cfg2);
            slm.initialize(cfg2);
            tc.verifyTrue(slm.isInitialized, '''mock'' mode should initialize cleanly');
        end

        function test_projectTargets_returns_res(tc)
            slm = buildSlm_(tc);
            siCentroids = [0, 0];  % single cell at origin
            res = slm.projectTargets(siCentroids);

            tc.verifyTrue(isstruct(res));
            tc.verifyTrue(isfield(res, 'nAccepted'));
            tc.verifyTrue(isfield(res, 'perCellDeliveredFraction'));
            tc.verifyTrue(isfield(res, 'etaEffective'));
            tc.verifyEqual(res.nAccepted, 1);
            tc.verifyTrue(isfinite(res.perCellDeliveredFraction), ...
                'perCellDeliveredFraction must be finite');
        end

        function test_getLocalSlm_activePattern_shape(tc)
            slm = buildSlm_(tc);
            slm.projectTargets([0, 0]);

            localSlm = slm.getLocalSlm();
            tc.verifyNotEmpty(localSlm, 'getLocalSlm should return MockSLM in loopback mode');

            mask = localSlm.getActivePattern();
            tc.verifyClass(mask, 'uint8');
            % Dims: [nRows nCols] = [128 128] from config
            tc.verifyEqual(size(mask), [128 128]);
        end

        function test_blank(tc)
            slm = buildSlm_(tc);
            slm.blank();
            localSlm = slm.getLocalSlm();
            status = localSlm.getStatus();
            tc.verifyEqual(status.state, 'presenting');
            mask = localSlm.getActivePattern();
            tc.verifyTrue(all(mask(:) == 0), 'blank should produce all-zero mask');
        end

        function test_slmPower_true(tc)
            slm = buildSlm_(tc);
            slm.slmPower(true);
            localSlm = slm.getLocalSlm();
            status   = localSlm.getStatus();
            tc.verifyTrue(status.powerOn);
        end

        function test_slmPower_false(tc)
            slm = buildSlm_(tc);
            slm.slmPower(true);
            slm.slmPower(false);
            localSlm = slm.getLocalSlm();
            status   = localSlm.getStatus();
            tc.verifyFalse(status.powerOn);
        end

        function test_getStatus(tc)
            slm    = buildSlm_(tc);
            status = slm.getStatus();
            tc.verifyTrue(isstruct(status), 'getStatus must return a struct');
            tc.verifyTrue(isfield(status, 'state'));
            tc.verifyTrue(isfield(status, 'powerOn'));
        end

        function test_cleanup(tc)
            slm = buildSlm_(tc);
            slm.cleanup();
            tc.verifyFalse(slm.isInitialized);
        end

        function test_multi_cell_projectTargets(tc)
            slm = buildSlm_(tc);
            siCentroids = [0 0; 5 0; -5 0];   % 3 cells
            res = slm.projectTargets(siCentroids);
            tc.verifyEqual(res.nAccepted, 3);
        end

        function test_getLocalSlm_nil_before_init(tc)
            % Before initialize() mode is unknown; getLocalSlm would error on
            % mode_ being empty — just verify initialize sets things up.
            slm = tfp.hardware.RemoteSLM(tc.cfg);
            tc.verifyFalse(slm.isInitialized);
            % Do not call getLocalSlm before init; object is in undefined mode.
        end

        function test_getLog_not_empty_after_ops(tc)
            slm = buildSlm_(tc);
            slm.slmPower(true);
            slm.blank();
            log = slm.getLog();
            tc.verifyTrue(numel(log) >= 3, ...
                'Log should have at least initialize + slmPower + blank entries');
        end

    end % methods (Test)

    % --------------------------------------------------------------------- %
    methods (Access = private)
        function slm = buildSlm_(tc)
            slm = tfp.hardware.RemoteSLM(tc.cfg);
            slm.initialize(tc.cfg);
        end
    end
end
