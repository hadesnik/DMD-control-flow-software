classdef test_MP285ZStage_mock < matlab.unittest.TestCase
    %test_MP285ZStage_mock MP285ZStage over its in-memory mock transport.
    %   Exercises the byte framing ('c' read / 'm' move), the um<->usteps
    %   conversion, the mount-dependent direction_sign, the XY gate, and
    %   the rulerId provenance string — none of which need a serial port.
    %
    %   Every config sets timeoutS small: waitForCr busy-polls until the
    %   timeout, so a mock regression should fail in ~0.5 s, not 10 s.
    %   At usteps_per_um = 25 one ustep is 0.04 um, hence AbsTol 0.02
    %   (half a ustep) on position comparisons.

    properties (Constant)
        BaseCfg = struct('mockTransport', true, 'timeoutS', 0.5, ...
                         'usteps_per_um', 25, 'serial_port', 'COM5')
    end

    methods (Test)

        function mockRoundTripAndLog(testCase)
            z = tfp.hardware.MP285ZStage(testCase.BaseCfg);
            testCase.verifyTrue(z.isInitialized);
            testCase.verifyEqual(z.getPositionUm(), 0, 'AbsTol', 0.02);

            z.moveToUm(10);
            testCase.verifyEqual(z.getPositionUm(), 10, 'AbsTol', 0.02);
            z.moveRelativeUm(-2.6);
            testCase.verifyEqual(z.getPositionUm(), 7.4, 'AbsTol', 0.02);

            % moveRelativeUm routes through moveToUm -> 2 logged moves.
            entries = z.getLog();
            testCase.verifyEqual(sum(strcmp({entries.eventType}, 'moveToUm')), 2);

            testCase.verifyError(@() z.moveToUm(NaN), ...
                'tfp:hardware:MP285ZStage:badZ');

            % Constructed without config = never initialized.
            zBare = tfp.hardware.MP285ZStage();
            testCase.verifyError(@() zBare.moveToUm(1), ...
                'tfp:hardware:MP285ZStage:notInitialized');
        end

        function directionSignNegatesRawZ(testCase)
            % Write side: the contract-frame command lands negated in the
            % RAW device frame (the sign cancels on a um round-trip, so the
            % raw usteps are the only place this is observable).
            cfg = testCase.BaseCfg;
            cfg.direction_sign = -1;
            z = tfp.hardware.MP285ZStage(cfg);
            z.moveToUm(10);
            testCase.verifyEqual(z.getPositionUm(), 10, 'AbsTol', 0.02);
            st = z.getStatus();
            testCase.verifyEqual(st.xyzUsteps(3), -250, ...
                'direction_sign=-1 must negate the raw z usteps');
            testCase.verifyEqual(st.directionSign, -1);
            testCase.verifyEqual(st.mount, 'objective');

            % Read side: a raw +250 usteps reads as -10 um in the contract
            % frame under the flipped mount.
            cfg2 = cfg;
            cfg2.mockStartUsteps = [0 0 250];
            z2 = tfp.hardware.MP285ZStage(cfg2);
            testCase.verifyEqual(z2.getPositionUm(), -10, 'AbsTol', 0.02);
        end

        function zMoveEchoesXY(testCase)
            % A pure-z move must echo x/y back bit-identically (audit #3).
            cfg = testCase.BaseCfg;
            cfg.mockStartUsteps = [1234 -567 80];
            z = tfp.hardware.MP285ZStage(cfg);
            z.moveToUm(4);
            st = z.getStatus();
            testCase.verifyEqual(st.xyzUsteps, [1234 -567 100]);
        end

        function xyGatedOnObjectiveMount(testCase)
            % Refusing this is the whole point of the mount key: on the
            % objective mount an XY move would translate the MOM objective.
            z = tfp.hardware.MP285ZStage(testCase.BaseCfg);
            testCase.verifyError(@() z.moveToXYUm(10, 10), ...
                'tfp:hardware:MP285ZStage:xyRequiresSampleMount');
        end

        function xyMoveOnSampleMount(testCase)
            cfg = testCase.BaseCfg;
            cfg.mount           = 'sample';
            cfg.direction_sign  = -1;
            cfg.mockStartUsteps = [0 0 250];
            z = tfp.hardware.MP285ZStage(cfg);

            z.moveToXYUm(100, -40);
            % X/Y in the raw stage frame, z untouched and still sign-correct.
            testCase.verifyEqual(z.getPositionXYZUm(), [100 -40 -10], ...
                'AbsTol', 0.02);
            st = z.getStatus();
            testCase.verifyEqual(st.xyzUsteps, [2500 -1000 250]);

            % Element 3 of getPositionXYZUm is the contract-frame z.
            testCase.verifyEqual(z.getPositionXYZUm(), ...
                [100 -40 z.getPositionUm()], 'AbsTol', 0.02);

            testCase.verifyError(@() z.moveToXYUm(NaN, 0), ...
                'tfp:hardware:MP285ZStage:badXY');
        end

        function configValidation(testCase)
            bad = testCase.BaseCfg;
            bad.direction_sign = 0;
            testCase.verifyError(@() tfp.hardware.MP285ZStage(bad), ...
                'tfp:hardware:MP285ZStage:badDirectionSign');
            bad.direction_sign = 2;
            testCase.verifyError(@() tfp.hardware.MP285ZStage(bad), ...
                'tfp:hardware:MP285ZStage:badDirectionSign');

            bad2 = testCase.BaseCfg;
            bad2.mount = 'ceiling';
            testCase.verifyError(@() tfp.hardware.MP285ZStage(bad2), ...
                'tfp:hardware:MP285ZStage:badMount');
        end

        function rulerIdStrings(testCase)
            z = tfp.hardware.MP285ZStage(testCase.BaseCfg);
            testCase.verifyEqual(z.rulerId(), ...
                'tfp.hardware.MP285ZStage(mount=objective,sign=+1,port=COM5)');

            cfg = testCase.BaseCfg;
            cfg.mount          = 'sample';
            cfg.direction_sign = -1;
            cfg.serial_port    = 'COM6';
            z2 = tfp.hardware.MP285ZStage(cfg);
            testCase.verifyEqual(z2.rulerId(), ...
                'tfp.hardware.MP285ZStage(mount=sample,sign=-1,port=COM6)');
        end

        function calibrationContractWithFlippedSign(testCase)
            % End-to-end: the REAL slm z-calibration, ruled by a flipped-sign
            % sample-mount MP-285. The contract normalizes the sign, so the
            % recovered slope must match truth exactly as with MockZStage.
            cfg = testCase.BaseCfg;
            cfg.mount          = 'sample';
            cfg.direction_sign = -1;
            cfg.serial_port    = 'COM6';
            cfg.timeoutS       = 5;    % many moves; keep headroom
            zstage = tfp.hardware.MP285ZStage(cfg);

            [calib, truth] = tfp.calibration.calibrateSlmDefocus_mock( ...
                struct('zstage', zstage));

            testCase.verifyEqual(calib.fit.slopeUmPerCmd, truth.slmUmPerCmd, ...
                'AbsTol', 0.08, ...
                'Flipped-sign sample-mount ruler must recover the truth slope');
            testCase.verifyGreaterThan(calib.fit.r2, 0.98);
            testCase.verifyEqual(calib.zRuler, ...
                'tfp.hardware.MP285ZStage(mount=sample,sign=-1,port=COM6)');
        end
    end
end
