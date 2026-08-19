classdef test_power_sweep_single_mock < matlab.unittest.TestCase
    %test_power_sweep_single_mock tfp.calibration.powerMeterSweepSingle driven
    %   end to end against tfp.sim.SyntheticPowerMeter.
    %
    %   This exercises the REAL sweep, the REAL LaserPowerController and the
    %   REAL interlock — only the PM100D is synthetic. The older
    %   powerMeterSweep_mock re-implemented the arithmetic instead, so it could
    %   not have caught a fault in the code that runs at the bench.
    %
    %   Methods:
    %     recoversTheSyntheticCurve   — measured mW track the injected response.
    %     emitsSchema2                — ready for normalizePowerCurve consumers.
    %     stampsLaserStateAndChannel  — provenance travels with the curve.
    %     asksOnceForTheWholeRamp     — one envelope dialog, not one per step.
    %     declinedRampMakesNoOutput   — nothing reaches the DAQ.
    %     meterFaultLeavesBeamOff     — a throw mid-sweep still zeroes the AO.
    %     endsAtZeroVolts             — the sweep never leaves the beam on.
    %     unwiredRefuses
    %     curveInvertsThroughController — the point of measuring it at all.

    methods (Test)

        function recoversTheSyntheticCurve(testCase)
            [curve, truth] = tfp.calibration.powerMeterSweepSingle_mock();
            testCase.verifyEqual(curve.voltage.voltageV, truth.voltageSteps, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(curve.voltage.powerMw, truth.expectedMw, ...
                'AbsTol', 0.05, ...
                'measured power must track the injected response within noise');
        end

        function emitsSchema2(testCase)
            curve = tfp.calibration.powerMeterSweepSingle_mock();
            testCase.verifyEqual(curve.schema, 2);
            testCase.verifyEqual(curve.kind, 'power_curve');
            testCase.verifyNotEmpty(curve.voltage.powerStdMw);
            testCase.verifyEmpty(curve.pattern.dmdActivePx, ...
                'a volts sweep must not claim to be an ON-count curve');
        end

        function stampsLaserStateAndChannel(testCase)
            curve = tfp.calibration.powerMeterSweepSingle_mock();
            testCase.verifyEqual(curve.laserState.repRateKhz, 100);
            testCase.verifyEqual(curve.laserState.effectiveRepRateHz, 1e5);
            testCase.verifyEqual(curve.aoChannel, 'ao1');
            testCase.verifyEqual(curve.dmdActivePxAtSweep, 25, ...
                'the ON count must come from the pattern actually projected');
        end

        function asksOnceForTheWholeRamp(testCase)
            calls = containers.Map({'n'}, {0});
            tfp.calibration.powerMeterSweepSingle_mock(struct( ...
                'confirmFcn', @(spec) countYes(calls, spec)));
            testCase.verifyEqual(calls('n'), 1, ...
                ['a monotone ramp must take consent once for its envelope; ' ...
                 'a dialog per step trains the operator to click through']);
        end

        function declinedRampMakesNoOutput(testCase)
            testCase.verifyError(@() tfp.calibration.powerMeterSweepSingle_mock( ...
                struct('confirmFcn', @(spec) false)), ...
                'tfp:hardware:LaserPowerController:confirmationDeclined');
        end

        function meterFaultLeavesBeamOff(testCase)
            % A meter that throws part way through must not leave the beam on.
            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct('sampleRate', 10000, 'analogOutChannels', [0 1]));
            config.laser = struct('carbide_modulator_ao_channel', 'ao1', ...
                'carbide_voltage_min', 0, 'carbide_voltage_max', 5, ...
                'arm_transmission', 0.182);
            laser = tfp.hardware.LaserPowerController(daq, config, struct( ...
                'confirmFcn', @(spec) true, ...
                'laserState', struct('repRateKhz', 100, 'frontPanelPowerW', 8.5)));

            spot = false(100, 100);
            spot(48:52, 48:52) = true;
            meter = FlakyMeter(3);
            testCase.verifyError(@() tfp.calibration.powerMeterSweepSingle( ...
                laser, struct('voltageSteps', linspace(0, 5, 11), ...
                'meter', meter, 'patterns', spot, 'settleTimeS', 0, ...
                'warmupTimeS', 0, 'readPauseS', 0, 'nAverages', 1, ...
                'verbose', false)), 'FlakyMeter:boom');

            v = aoVoltages(daq);
            testCase.verifyEqual(v(end), 0, ...
                'the last thing written to the modulator must be zero');
        end

        function endsAtZeroVolts(testCase)
            [~, truth] = tfp.calibration.powerMeterSweepSingle_mock();
            v = aoVoltages(truth.daq);
            testCase.verifyEqual(v(end), 0);
            testCase.verifyEqual(truth.laser.currentVolts, 0);
        end

        function unwiredRefuses(testCase)
            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct('sampleRate', 10000, 'analogOutChannels', 0));
            config.laser = struct('carbide_modulator_ao_channel', '');
            laser = tfp.hardware.LaserPowerController(daq, config, struct( ...
                'laserState', struct('repRateKhz', 100)));
            testCase.verifyError(@() tfp.calibration.powerMeterSweepSingle(laser), ...
                'tfp:calibration:powerMeterSweepSingle:notWired');
        end

        function curveInvertsThroughController(testCase)
            % The whole reason for measuring the curve: ask for milliwatts.
            [curve, truth] = tfp.calibration.powerMeterSweepSingle_mock();
            truth.laser.loadPowerCurve(curve);
            wantMw = 20;
            v = truth.laser.voltsForMw(wantMw);
            testCase.verifyEqual(truth.laser.mwForVolts(v), wantMw, 'AbsTol', 0.2);
        end
    end
end

% ---------------------------------------------------------------------------
function ok = countYes(calls, ~)
calls('n') = calls('n') + 1;
ok = true;
end

function v = aoVoltages(daq)
entries = daq.getLog();
v = [];
for k = 1:numel(entries)
    if strcmp(entries(k).eventType, 'outputSingleAnalog')
        v(end+1) = entries(k).payload.voltageV; %#ok<AGROW>
    end
end
end
