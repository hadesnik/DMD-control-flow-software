classdef test_ZStage_mock < matlab.unittest.TestCase
    %test_ZStage_mock ZStage backends that run without hardware:
    %   MockZStage, ManualZStage (injected prompt), RelayZStage (mock
    %   transport), and the makeZStage factory.

    methods (Test)

        function mockMoveReadRelative(testCase)
            z = tfp.hardware.MockZStage();
            z.initialize(struct('startZUm', 5));
            testCase.verifyEqual(z.getPositionUm(), 5);
            z.moveToUm(-12.5);
            testCase.verifyEqual(z.getPositionUm(), -12.5);
            z.moveRelativeUm(2.5);
            testCase.verifyEqual(z.getPositionUm(), -10);

            entries = z.getLog();
            testCase.verifyEqual(sum(strcmp({entries.eventType}, 'moveToUm')), 2);

            testCase.verifyError(@() z.moveToUm(NaN), ...
                'tfp:hardware:MockZStage:badZ');
        end

        function manualUsesInjectedPrompt(testCase)
            z = tfp.hardware.ManualZStage();
            z.initialize(struct('promptFcn', @(msg) '33.25'));
            z.moveToUm(30);   % operator "achieved" 33.25
            testCase.verifyEqual(z.getPositionUm(), 33.25);

            % Empty answer = "done, at requested position".
            z2 = tfp.hardware.ManualZStage();
            z2.initialize(struct('promptFcn', @(msg) ''));
            z2.moveToUm(30);
            testCase.verifyEqual(z2.getPositionUm(), 30);

            % Garbage reading errors rather than silently continuing.
            z3 = tfp.hardware.ManualZStage();
            z3.initialize(struct('promptFcn', @(msg) 'about thirty'));
            testCase.verifyError(@() z3.moveToUm(30), ...
                'tfp:hardware:ManualZStage:badReading');
        end

        function relayMockTransportRoundTrip(testCase)
            z = tfp.hardware.RelayZStage(struct());
            testCase.verifyError(@() z.moveToUm(1), ...
                'tfp:hardware:RelayZStage:notConnected');
            z.connect(struct('mockTransport', true));
            z.moveToUm(40);
            testCase.verifyEqual(z.getPositionUm(), 40);
            z.moveRelativeUm(-15);
            testCase.verifyEqual(z.getPositionUm(), 25);
        end

        function factorySelectsBackends(testCase)
            cfg.zstage = struct('backend', 'mock', 'startZUm', 7);
            z = tfp.hardware.makeZStage(cfg);
            testCase.verifyClass(z, 'tfp.hardware.MockZStage');
            testCase.verifyEqual(z.getPositionUm(), 7);

            cfg.zstage = struct('backend', 'manual', ...
                'promptFcn', @(msg) '1.0');
            z = tfp.hardware.makeZStage(cfg);
            testCase.verifyClass(z, 'tfp.hardware.ManualZStage');

            cfg.zstage = struct('backend', 'relay');
            z = tfp.hardware.makeZStage(cfg, ...
                struct('connectOptions', struct('mockTransport', true)));
            testCase.verifyClass(z, 'tfp.hardware.RelayZStage');
            z.moveToUm(3);
            testCase.verifyEqual(z.getPositionUm(), 3);

            cfg.zstage = struct('backend', 'hoverboard');
            testCase.verifyError(@() tfp.hardware.makeZStage(cfg), ...
                'tfp:hardware:makeZStage:badBackend');
        end
    end
end
