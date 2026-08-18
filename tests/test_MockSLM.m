classdef test_MockSLM < matlab.unittest.TestCase
    %test_MockSLM MockSLM sequence interface + MeadowlarkSLM proxy protocol.

    methods (Access = private)
        function [slm, sys] = makeSequencedSlm(~, mode, pulseFcn)
            slm = tfp.hardware.MockSLM();
            % Tiny array keeps mask computation fast in tests.
            slm.initialize(struct('nRows', 64, 'nCols', 64, ...
                'pitch_um', 17.0, 'nStates', 256, 'lambda_nm', 1038, ...
                'settle_s', 0));
            if nargin >= 3 && ~isempty(pulseFcn)
                slm.setTtlPulseFcn(pulseFcn);
            end
            sys = struct('mRelay', 1.2, 'nImm', 1.0, ...
                'fObjUm', 20000, 'NA', 0.45, 'wrapPhaseRad', 2 * pi);
            slm.prepareDefocusSequence([0, 10, 20, 30], sys);
            slm.armSequenceTrigger(mode);
        end
    end

    methods (Test)

        function defaultsAreMeadowlarkGeometry(testCase)
            slm = tfp.hardware.MockSLM();
            slm.initialize(struct());
            testCase.verifyEqual(slm.nRows, 1024);
            testCase.verifyEqual(slm.nCols, 1024);
            testCase.verifyEqual(slm.pitchX_um, 17.0);
            testCase.verifyEqual(slm.pitchY_um, 17.0);
            testCase.verifyEqual(slm.nPhaseStates, 256);
            testCase.verifyEqual(slm.lambda_nm, 1038);
            testCase.verifyTrue(slm.supportsDefocusSequence());
        end

        function sequenceBookkeeping(testCase)
            slm = testCase.makeSequencedSlm('software');
            testCase.verifyEqual(slm.getSequenceIndex(), 0);
            testCase.verifyTrue(isnan(slm.getCurrentDefocusUm()));

            slm.advanceToIndex(2);
            testCase.verifyEqual(slm.getSequenceIndex(), 2);
            testCase.verifyEqual(slm.getCurrentDefocusUm(), 10);

            slm.advanceToIndex(4);
            testCase.verifyEqual(slm.getCurrentDefocusUm(), 30);

            % Wrap-around: 4 -> 1 is one step forward.
            slm.advanceToIndex(1);
            testCase.verifyEqual(slm.getCurrentDefocusUm(), 0);

            % Active pattern tracks the sequence position.
            testCase.verifySize(slm.getActivePattern(), [64, 64]);
        end

        function ttlModePulsesOncePerStep(testCase)
            counter = containers.Map({'n'}, {0});   % handle => mutable in closure
            pulse   = @() increment(counter);
            slm = testCase.makeSequencedSlm('ttl', pulse);

            slm.advanceToIndex(1);   % parked -> 1: one pulse
            testCase.verifyEqual(counter('n'), 1);
            slm.advanceToIndex(3);   % 1 -> 3: two pulses
            testCase.verifyEqual(counter('n'), 3);
            slm.advanceToIndex(3);   % dedupe: same index, zero pulses
            testCase.verifyEqual(counter('n'), 3);
            slm.advanceToIndex(2);   % 3 -> 2 wraps: 3 steps (3->4->1->2)
            testCase.verifyEqual(counter('n'), 6);

            % Settle events logged once per advance that moved.
            entries = slm.getLog();
            nSettle = sum(strcmp({entries.eventType}, 'settle'));
            testCase.verifyEqual(nSettle, 3);
        end

        function errorPaths(testCase)
            slm = tfp.hardware.MockSLM();
            slm.initialize(struct('nRows', 64, 'nCols', 64));
            sys = struct('mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, 'NA', 0.45);

            testCase.verifyError(@() slm.advanceToIndex(1), ...
                'tfp:hardware:MockSLM:noSequence');
            testCase.verifyError(@() slm.armSequenceTrigger('ttl'), ...
                'tfp:hardware:MockSLM:noSequence');

            slm.prepareDefocusSequence([0 10], sys);
            testCase.verifyError(@() slm.advanceToIndex(1), ...
                'tfp:hardware:MockSLM:notArmed');
            testCase.verifyError(@() slm.armSequenceTrigger('ttl'), ...
                'tfp:hardware:MockSLM:noPulseFcn');

            slm.armSequenceTrigger('software');
            testCase.verifyError(@() slm.advanceToIndex(5), ...
                'tfp:hardware:MockSLM:badIdx');
            testCase.verifyError(@() slm.advanceToIndex(0), ...
                'tfp:hardware:MockSLM:badIdx');
        end

        % ------------------------------------------------------------
        % MeadowlarkSLM proxy (mock transport — no sockets)

        function proxyProtocolRoundTrip(testCase)
            slm = tfp.hardware.MeadowlarkSLM(struct( ...
                'nRows', 64, 'nCols', 64, 'trigger_mode', 'software', ...
                'settle_s', 0));
            testCase.verifyError(@() slm.prepareDefocusSequence([0 10], struct()), ...
                'tfp:hardware:MeadowlarkSLM:notConnected');

            slm.connect(struct('mockTransport', true));
            sys = struct('mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, 'NA', 0.45);
            slm.prepareDefocusSequence([0, 15, 30], sys);
            slm.armSequenceTrigger('software');
            slm.advanceToIndex(2);
            testCase.verifyEqual(slm.getSequenceIndex(), 2);
            testCase.verifyEqual(slm.getCurrentDefocusUm(), 15);

            % 'send' log entries: 1 spec + 2 ADV steps... advanceToIndex(2)
            % from parked = 2 steps.
            entries = slm.getLog();
            nSend = sum(strcmp({entries.eventType}, 'send'));
            testCase.verifyEqual(nSend, 3);
        end

        function proxyRejectsBadReply(testCase)
            slm = tfp.hardware.MeadowlarkSLM(struct('nRows', 64, 'nCols', 64));
            slm.connect(struct('mockTransport', true));
            slm.queueMockReply('ERR: no Blink SDK');
            sys = struct('mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, 'NA', 0.45);
            testCase.verifyError(@() slm.prepareDefocusSequence([0 10], sys), ...
                'tfp:hardware:MeadowlarkSLM:badReply');
        end

        function proxyRefusesPixelLoad(testCase)
            slm = tfp.hardware.MeadowlarkSLM(struct('nRows', 64, 'nCols', 64));
            testCase.verifyError(@() slm.loadPattern(zeros(64, 64, 'uint8')), ...
                'tfp:hardware:MeadowlarkSLM:notSupported');
        end

        % ------------------------------------------------------------
        % Legacy devices keep working and report no sequence support.

        function legacyDevicesReportNoSequenceSupport(testCase)
            plm = tfp.hardware.MockPLM();
            plm.initialize(struct());
            testCase.verifyFalse(plm.supportsDefocusSequence());
            testCase.verifyEqual(plm.settleTimeS(), 0);
            testCase.verifyError(@() plm.prepareDefocusSequence([0 1], struct()), ...
                'tfp:hardware:PLM:notSupported');
            testCase.verifyError(@() plm.getSequenceIndex(), ...
                'tfp:hardware:PLM:notSupported');
        end
    end
end

% --- Local helper (containers.Map is a handle, so this mutates in place) ---

function increment(counter)
counter('n') = counter('n') + 1;
end
