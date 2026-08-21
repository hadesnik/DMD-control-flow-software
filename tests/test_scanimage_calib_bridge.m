classdef test_scanimage_calib_bridge < matlab.unittest.TestCase
    %test_scanimage_calib_bridge The DAQ-PC half of si_calib_helper.
    %
    %   Exercised over the socket-free mock transport, which answers with the
    %   right SHAPES and nothing meaningful — a test that needed real pixel
    %   values would be testing the emulator. What is worth testing here is
    %   the protocol: opcodes, reply lengths, error codes, and the two guards
    %   that exist to stop a calibration going wrong quietly.
    %
    %   Methods:
    %     refusesToWorkBeforeConnecting
    %     roundTripsTheDocumentedOpcodes
    %     squarePixelCountIsRefused
    %     helperErrorCodesBecomeErrors
    %     truncatedVolumeIsCaughtNotReshaped
    %     opcodesDoNotCollideWithTheZRulerBlock
    %     disconnectNeverThrows

    methods (Access = private)
        function b = connected(testCase)
            b = tfp.hardware.ScanImageCalibBridge(struct('host', 'imaging-pc'));
            b.connect(struct('mockTransport', true));
            testCase.addTeardown(@() b.disconnect());
        end
    end

    methods (Test)

        function refusesToWorkBeforeConnecting(testCase)
            b = tfp.hardware.ScanImageCalibBridge(struct('host', 'imaging-pc'));
            testCase.verifyError(@() b.startFocus(), ...
                'tfp:hardware:ScanImageCalibBridge:notConnected');
            % And without a host there is nothing to connect to — the message
            % has to say what to do, since "the helper is not running" and
            % "you never told me where it is" want different fixes.
            b2 = tfp.hardware.ScanImageCalibBridge(struct());
            testCase.verifyError(@() b2.connect(), ...
                'tfp:hardware:ScanImageCalibBridge:missingHost');
        end

        function roundTripsTheDocumentedOpcodes(testCase)
            b = testCase.connected();

            b.setPixelCounts(512, 256);
            cfg = b.config();
            testCase.verifyEqual(cfg.nFast, 512);
            testCase.verifyEqual(cfg.nSlow, 256);

            b.startFocus();
            b.commandRoi(-120, 45, 50, 50);
            b.abort();

            brightness = b.planeBrightness(3);
            testCase.verifySize(brightness, [1 3]);

            stack = b.grabStack(3);
            testCase.verifyEqual(ndims(stack), 3);
            testCase.verifyEqual(size(stack, 3), 3);
        end

        function squarePixelCountIsRefused(testCase)
            % Section 4b's whole method is that the raster rectangle's LONG
            % axis identifies the fast (resonant) axis. A square frame
            % destroys that information in a way nothing downstream can
            % recover, so it is refused at the point of asking rather than
            % discovered as an unresolvable sign later.
            b = testCase.connected();
            testCase.verifyError(@() b.setPixelCounts(512, 512), ...
                'tfp:hardware:ScanImageCalibBridge:squarePixelCount');
        end

        function helperErrorCodesBecomeErrors(testCase)
            % A non-zero first element is the helper reporting a failure, and
            % it must not be read as data.
            b = testCase.connected();
            b.queueMockReply(-1);
            testCase.verifyError(@() b.startFocus(), ...
                'tfp:hardware:ScanImageCalibBridge:helperError');
        end

        function truncatedVolumeIsCaughtNotReshaped(testCase)
            % reshape() on a short vector throws something unhelpful; a
            % volume too big for one message is a real and recoverable
            % situation, so it gets its own message naming the fix.
            b = testCase.connected();
            b.queueMockReply([0, 8, 8, 3, zeros(1, 10)]);   % 192 pixels promised, 10 sent
            testCase.verifyError(@() b.grabStack(3), ...
                'tfp:hardware:ScanImageCalibBridge:truncatedStack');
        end

        function opcodesDoNotCollideWithTheZRulerBlock(testCase)
            % si_calib_helper serves si_motor_helper's opcodes 1/2/3 as well,
            % because one MATLAB can hold only one accept loop and section 6b
            % needs the z ruler and plane brightness in the same measurement
            % loop. Every opcode this class sends must therefore be >= 10, or
            % a calibration request would silently move the objective.
            b = testCase.connected();
            b.setPixelCounts(512, 256);
            b.startFocus();
            b.abort();
            b.planeBrightness(3);
            b.grabStack(3);
            b.commandRoi(0, 0, 10, 10);
            b.config();

            entries = b.getLog();
            opcodes = [];
            for k = 1:numel(entries)
                if strcmp(entries(k).eventType, 'request')
                    opcodes(end+1) = entries(k).payload.opcode; %#ok<AGROW>
                end
            end
            testCase.verifyNotEmpty(opcodes);
            testCase.verifyTrue(all(opcodes >= 10), sprintf( ...
                ['opcode(s) %s collide with si_motor_helper''s z block (1-3); ' ...
                 'a calibration request would move the objective'], ...
                mat2str(opcodes(opcodes < 10))));
        end

        function disconnectNeverThrows(testCase)
            % Teardown must not take a session down with it (lab convention).
            b = tfp.hardware.ScanImageCalibBridge(struct('host', 'imaging-pc'));
            testCase.verifyWarningFree(@() b.disconnect());
            b.connect(struct('mockTransport', true));
            b.disconnect();
            testCase.verifyFalse(b.isConnected());
            testCase.verifyWarningFree(@() b.disconnect());
        end
    end
end
