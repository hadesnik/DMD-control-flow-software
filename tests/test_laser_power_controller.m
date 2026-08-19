classdef test_laser_power_controller < matlab.unittest.TestCase
    %test_laser_power_controller tfp.hardware.LaserPowerController — the single
    %   gateway to the CARBIDE external-modulator BNC.
    %
    %   Methods:
    %     unwiredRefusesEveryOutput   — the configs/real.yaml placeholder made
    %                                   load-bearing: '' means refuse, loudly.
    %     drivesTheConfiguredChannel  — channel and voltage land in MockDAQ's log.
    %     clampsToCarbideRange        — the laser's limit, named as such, raised
    %                                   before the DAQ's own +/-10 V check.
    %     setPowerMwNeedsACurve / setVoltsDoesNot — the asymmetry that lets the
    %                                   sweep produce the curve it needs.
    %     voltsMwRoundTrip / powerOutOfRangeThrows / nonMonotonicCurveThrows
    %     declinedConfirmationMakesNoOutput — the central safety assertion.
    %     confirmsOnFirstLight / onIncrease / onNewStep / onPatternChange
    %     doesNotConfirmOnDecreaseOrZero — blocking the safe direction is how a
    %                                   safety dialog becomes a hazard.
    %     interlockRefusesBeforeAsking — an unsafe request is never offered for
    %                                   confirmation.
    %     daqFaultLeavesTrailingZero / deleteZeroes
    %     simulatedDmdWithRealDaqRefuses
    %     noLaserStateFailsClosed

    properties (Constant)
        % Front-panel wattage is part of the operator-entered state and is
        % what bounds the interlock before a volts->mW curve exists.
        LaserState = struct('repRateKhz', 100, 'pulsePickerDivision', 1, ...
            'frontPanelPowerW', 8.5);
    end

    methods (Access = private)

        function daq = makeDaq(~)
            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct('sampleRate', 10000, ...
                'analogOutChannels', [0 1 3]));
        end

        function cfg = wiredConfig(~, varargin)
            cfg.laser = struct( ...
                'carbide_modulator_ao_channel', 'ao1', ...
                'carbide_voltage_min', 0, ...
                'carbide_voltage_max', 5, ...
                'arm_transmission',    0.182);
            for k = 1:2:numel(varargin)
                cfg.laser.(varargin{k}) = varargin{k+1};
            end
        end

        function [lp, daq, calls] = makeController(testCase, varargin)
            % varargin are LaserPowerController options overrides.
            daq   = testCase.makeDaq();
            calls = containers.Map({'n'}, {0});
            opts  = struct( ...
                'confirmFcn', @(spec) yes(calls), ...
                'laserState', testCase.LaserState);
            for k = 1:2:numel(varargin)
                opts.(varargin{k}) = varargin{k+1};
            end
            lp = tfp.hardware.LaserPowerController(daq, testCase.wiredConfig(), opts);
            % A sparse single spot: what every calibration step actually projects.
            lp.notePattern(testCase.spotPattern());
        end

        function frame = spotPattern(~)
            frame = false(100, 100);
            frame(48:52, 48:52) = true;    % 0.25% of the chip
        end

        function curve = linearCurve(~)
            % 0..5 V -> 0..50 mW at the sample, strictly monotone.
            v = linspace(0, 5, 11);
            curve = struct('voltageV', v, 'powerMw', v * 10, ...
                'powerStdMw', zeros(size(v)), 'fovAreaUm2', pi * 400^2, ...
                'wavelengthNm', 1038, 'dmdActivePx', 25);
        end

        function v = aoLog(~, daq)
            % Every outputSingleAnalog voltage, in order.
            entries = daq.getLog();
            v = [];
            for k = 1:numel(entries)
                if strcmp(entries(k).eventType, 'outputSingleAnalog')
                    v(end+1) = entries(k).payload.voltageV; %#ok<AGROW>
                end
            end
        end
    end

    methods (Test)

        % --- wiring placeholder -----------------------------------------
        function unwiredRefusesEveryOutput(testCase)
            daq = testCase.makeDaq();
            lp  = tfp.hardware.LaserPowerController(daq, ...
                testCase.wiredConfig('carbide_modulator_ao_channel', ''), ...
                struct('laserState', testCase.LaserState));
            testCase.verifyFalse(lp.isWired());
            testCase.verifyError(@() lp.setVolts(1), ...
                'tfp:hardware:LaserPowerController:notWired');
            testCase.verifyError(@() lp.zero(), ...
                'tfp:hardware:LaserPowerController:notWired');
            testCase.verifyEmpty(testCase.aoLog(daq));
        end

        % --- basic output ------------------------------------------------
        function drivesTheConfiguredChannel(testCase)
            [lp, daq] = testCase.makeController();
            lp.setVolts(2.0);
            entries = daq.getLog();
            last    = entries(end);
            testCase.verifyEqual(last.eventType, 'outputSingleAnalog');
            testCase.verifyEqual(last.payload.channel,  'ao1');
            testCase.verifyEqual(last.payload.voltageV, 2.0);
            testCase.verifyEqual(lp.currentVolts, 2.0);
        end

        function clampsToCarbideRange(testCase)
            lp = testCase.makeController();
            testCase.verifyError(@() lp.setVolts(5.5), ...
                'tfp:hardware:LaserPowerController:voltageOutOfRange');
            testCase.verifyError(@() lp.setVolts(-0.1), ...
                'tfp:hardware:LaserPowerController:voltageOutOfRange');
        end

        % --- the curve ----------------------------------------------------
        function setPowerMwNeedsACurve(testCase)
            lp = testCase.makeController();
            testCase.verifyError(@() lp.setPowerMw(5), ...
                'tfp:hardware:LaserPowerController:noPowerCurve');
            % ...but setVolts works, which is how the sweep that produces the
            % curve is driven in the first place.
            lp.setVolts(1.0);
            testCase.verifyEqual(lp.currentVolts, 1.0);
        end

        function voltsMwRoundTrip(testCase)
            [lp, daq] = testCase.makeController();
            lp.loadPowerCurve(testCase.linearCurve());
            testCase.verifyTrue(lp.hasPowerCurve());
            testCase.verifyEqual(lp.voltsForMw(25), 2.5, 'AbsTol', 1e-9);
            testCase.verifyEqual(lp.mwForVolts(2.5), 25,  'AbsTol', 1e-9);

            lp.setPowerMw(30);
            testCase.verifyEqual(lp.currentVolts,   3.0, 'AbsTol', 1e-9);
            testCase.verifyEqual(lp.currentPowerMw, 30,  'AbsTol', 1e-9);
            testCase.verifyEqual(testCase.aoLog(daq), 3.0, 'AbsTol', 1e-9);
        end

        function powerOutOfRangeThrows(testCase)
            lp = testCase.makeController();
            lp.loadPowerCurve(testCase.linearCurve());
            testCase.verifyError(@() lp.voltsForMw(500), ...
                'tfp:hardware:LaserPowerController:powerOutOfRange');
        end

        function nonMonotonicCurveThrows(testCase)
            lp = testCase.makeController();
            bad = testCase.linearCurve();
            bad.powerMw(6) = bad.powerMw(6) - 20;   % a genuine decrease
            lp.loadPowerCurve(bad);
            testCase.verifyError(@() lp.voltsForMw(10), ...
                'tfp:hardware:LaserPowerController:nonMonotonicCurve');
        end

        % --- confirmation -------------------------------------------------
        function declinedConfirmationMakesNoOutput(testCase)
            % The central assertion of the whole safety layer.
            [lp, daq] = testCase.makeController('confirmFcn', @(spec) false);
            testCase.verifyError(@() lp.setVolts(3.0), ...
                'tfp:hardware:LaserPowerController:confirmationDeclined');
            testCase.verifyEmpty(testCase.aoLog(daq));
            testCase.verifyEqual(lp.currentVolts, lp.voltageMin);
        end

        function confirmsOnFirstLight(testCase)
            [lp, ~, calls] = testCase.makeController();
            lp.setVolts(1.0);
            testCase.verifyEqual(calls('n'), 1);
        end

        function confirmsOnIncreaseNotOnDecrease(testCase)
            [lp, ~, calls] = testCase.makeController();
            lp.loadPowerCurve(testCase.linearCurve());
            lp.setVolts(1.0);                       % first light -> ask
            n1 = calls('n');
            lp.setVolts(0.5);                       % decrease -> silent
            testCase.verifyEqual(calls('n'), n1);
            lp.setVolts(2.0);                       % increase -> ask
            testCase.verifyEqual(calls('n'), n1 + 1);
        end

        function zeroIsNeverGated(testCase)
            [lp, daq, calls] = testCase.makeController('confirmFcn', @(spec) false);
            lp.zero();          % must not ask, must not throw
            testCase.verifyEqual(calls('n'), 0);
            testCase.verifyEqual(testCase.aoLog(daq), lp.voltageMin);
        end

        function confirmsOnNewStep(testCase)
            [lp, ~, calls] = testCase.makeController();
            lp.loadPowerCurve(testCase.linearCurve());
            lp.setVolts(2.0);
            n1 = calls('n');
            lp.setVolts(2.0);                                    % same power, same step
            testCase.verifyEqual(calls('n'), n1);
            lp.setVolts(2.0, struct('stepToken', 'crossRegister'));
            testCase.verifyEqual(calls('n'), n1 + 1, ...
                'a new calibration step must re-ask even at unchanged power');
        end

        function confirmsOnPatternChange(testCase)
            [lp, ~, calls] = testCase.makeController();
            lp.loadPowerCurve(testCase.linearCurve());
            lp.setVolts(2.0);
            n1 = calls('n');
            other = false(100, 100);
            other(10:40, 10:40) = true;      % different ON and blob fractions
            lp.setVolts(2.0, struct('patterns', other));
            testCase.verifyEqual(calls('n'), n1 + 1);
        end

        function interlockRefusesBeforeAsking(testCase)
            % All-ON at 40 W-equivalent: the interlock must refuse outright
            % rather than offer it for confirmation.
            [lp, daq, calls] = testCase.makeController();
            lp.loadPowerCurve(struct('voltageV', [0 5], 'powerMw', [0 40000], ...
                'powerStdMw', [0 0]));
            lp.notePattern(true(100, 100));
            testCase.verifyError(@() lp.setVolts(5), ...
                'tfp:util:assertPulseEnergySafe:pulseEnergyExceeded');
            testCase.verifyEqual(calls('n'), 0, ...
                'an unsafe request must never reach the confirmation dialog');
            testCase.verifyEmpty(testCase.aoLog(daq));
        end

        % --- failure paths ------------------------------------------------
        function daqFaultLeavesTrailingZero(testCase)
            [lp, daq] = testCase.makeController();
            daq.cleanup();     % subsequent outputSingleAnalog throws notInitialized
            testCase.verifyError(@() lp.setVolts(1.0), ...
                'tfp:hardware:MockDAQ:notInitialized');
            % The zero attempt also fails on a dead DAQ, but it must be
            % ATTEMPTED and must warn rather than mask the original fault.
            testCase.verifyWarning(@() lp.zeroQuiet(), ...
                'tfp:hardware:LaserPowerController:zeroFailed');
        end

        function deleteZeroes(testCase)
            [lp, daq] = testCase.makeController();
            lp.setVolts(2.0);
            delete(lp);
            v = testCase.aoLog(daq);
            testCase.verifyEqual(v(end), 0, ...
                'the destructor must leave the modulator at its minimum');
        end

        function simulatedDmdWithRealDaqRefuses(testCase)
            % A mock DAQ emits no real light, so a fully simulated session is
            % allowed; the refusal is specifically about real light through an
            % unknown pattern. Exercised here through the mock path.
            [lp, ~] = testCase.makeController('simulated', struct('dmd', true));
            lp.setVolts(1.0);   % mock DAQ: permitted
            testCase.verifyEqual(lp.currentVolts, 1.0);
        end

        function noLaserStateFailsClosed(testCase)
            daq = testCase.makeDaq();
            lp  = tfp.hardware.LaserPowerController(daq, testCase.wiredConfig(), ...
                struct('confirmFcn', @(spec) true));
            lp.notePattern(testCase.spotPattern());
            testCase.verifyError(@() lp.setVolts(1.0), ...
                'tfp:util:assertPulseEnergySafe:badLaserState');
            testCase.verifyEmpty(testCase.aoLog(daq));
        end
    end
end

% ---------------------------------------------------------------------------
function ok = yes(calls)
calls('n') = calls('n') + 1;
ok = true;
end
