classdef test_MockDAQ < matlab.unittest.TestCase
    %test_MockDAQ Phase 1 MockDAQ tests.

    methods (Access = private)
        function daq = makeDaq(~)
            daq = tfp.hardware.MockDAQ();
            config.sampleRate         = 10000;
            config.analogInChannels   = [0 1 2];
            config.analogOutChannels  = [0 1];
            config.digitalInChannels  = {'port0/line2', 'port0/line3'};
            config.digitalOutChannels = {'port0/line0', 'port0/line1'};
            daq.initialize(config);
        end
    end

    methods (Test)
        function initialize_setsConfig(testCase)
            daq = tfp.hardware.MockDAQ();
            config.sampleRate         = 10000;
            config.analogInChannels   = [0 1 2];
            config.analogOutChannels  = [0 1];
            config.digitalInChannels  = {};
            config.digitalOutChannels = {'port0/line0', 'port0/line1'};
            daq.initialize(config);

            testCase.verifyEqual(daq.sampleRate, 10000);
            testCase.verifyEqual(daq.analogInChannels, [0 1 2]);
            testCase.verifyEqual(daq.analogOutChannels, [0 1]);
            testCase.verifyEqual(daq.digitalOutChannels, ...
                {'port0/line0', 'port0/line1'});
            testCase.verifyTrue(daq.isInitialized);
            testCase.verifyFalse(daq.isRunning);
        end

        function configureAnalogInput_validates(testCase)
            daq = testCase.makeDaq();
            testCase.verifyError(@() daq.configureAnalogInput([0 1 99], [-5 5]), ...
                'tfp:hardware:MockDAQ:badChannels');
            % Valid subset accepted.
            daq.configureAnalogInput([0 1], [-5 5]);
        end

        function queueAnalogOutput_validatesShape(testCase)
            daq = testCase.makeDaq();
            daq.configureAnalogOutput([0 1]);   % 2 channels configured

            badData  = zeros(100, 3);           % wrong nChans
            testCase.verifyError(@() daq.queueAnalogOutput(badData), ...
                'tfp:hardware:MockDAQ:badShape');

            goodData = zeros(100, 2);
            daq.queueAnalogOutput(goodData);    % no error
        end

        function queueDigitalPulses_validatesLines(testCase)
            daq = testCase.makeDaq();
            daq.configureDigitalOutput({'port0/line0'});

            testCase.verifyError(@() ...
                daq.queueDigitalPulses({'port0/line99'}, 0.1, 0.001), ...
                'tfp:hardware:MockDAQ:badLines');

            daq.queueDigitalPulses({'port0/line0'}, 0.1, 0.001);
        end

        function startStop_flagsRunning(testCase)
            daq = testCase.makeDaq();
            testCase.verifyFalse(daq.isRunning);
            daq.start();
            testCase.verifyTrue(daq.isRunning);
            daq.stop();
            testCase.verifyFalse(daq.isRunning);
        end

        function readAnalogInput_returnsNoise(testCase)
            daq = testCase.makeDaq();
            daq.configureAnalogInput([0 1], [-5 5]);

            N = 10000;
            data = daq.readAnalogInput(N);

            testCase.verifyEqual(size(data), [N, 2]);
            testCase.verifyTrue(all(isfinite(data(:))));

            % Mean of zero-mean noise + small random-walk drift.
            % Combined std of the sample mean ~ 6e-4 (white noise std/sqrt(N)
            % combined with drift std sigma*sqrt(N/3)). Tolerance 0.05 leaves
            % ~85 sigma margin -- safe against flaky failures.
            testCase.verifyLessThan(abs(mean(data(:, 1))), 0.05);
            testCase.verifyLessThan(abs(mean(data(:, 2))), 0.05);
        end

        function configureDigitalInput_validates(testCase)
            daq = testCase.makeDaq();  % digitalInChannels = {'port0/line2','port0/line3'}

            % Valid line accepted without error.
            daq.configureDigitalInput({'port0/line2'});

            % Line not in digitalInChannels is rejected.
            testCase.verifyError( ...
                @() daq.configureDigitalInput({'port0/line99'}), ...
                'tfp:hardware:MockDAQ:badLines');
        end

        function readDigitalInput_returnsSyntheticClock(testCase)
            daq = testCase.makeDaq();
            daq.configureDigitalInput({'port0/line2'});

            N    = 1000;
            data = daq.readDigitalInput('port0/line2', N);

            testCase.verifyEqual(size(data), [N, 1]);
            testCase.verifyTrue(all(data == 0 | data == 1), ...
                'frame clock values must be binary (0 or 1)');
            % At 10 kHz / 30 Hz = 333 samples/frame, 1000 samples -> 3 pulses.
            testCase.verifyGreaterThanOrEqual(sum(data), 3);
        end

        function sendDigitalPulse_logs(testCase)
            daq = testCase.makeDaq();
            daq.configureDigitalOutput({'port0/line0'});
            daq.sendDigitalPulse('port0/line0', 0.001);

            entries = daq.getLog();
            eventTypes = {entries.eventType};
            iPulse = find(strcmp(eventTypes, 'sendDigitalPulse'), 1, 'last');
            testCase.verifyNotEmpty(iPulse);

            payload = entries(iPulse).payload;
            testCase.verifyEqual(payload.lineName, 'port0/line0');
            testCase.verifyEqual(payload.durationS, 0.001);
        end

        function cleanup_resetsState(testCase)
            daq = testCase.makeDaq();
            daq.configureAnalogInput([0 1], [-5 5]);
            daq.start();
            daq.cleanup();
            testCase.verifyFalse(daq.isInitialized);
            testCase.verifyFalse(daq.isRunning);
        end
    end
end
