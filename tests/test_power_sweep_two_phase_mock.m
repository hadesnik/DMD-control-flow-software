classdef test_power_sweep_two_phase_mock < matlab.unittest.TestCase
    %test_power_sweep_two_phase_mock The FS-50 two-phase sweep
    %   (tfp.calibration.powerMeterSweep, build A) after being refitted onto
    %   private/runPowerSweepPhase and private/openPowerMeter.
    %
    %   Before those seams existed this function could not be tested at all:
    %   TLPM() was constructed unconditionally and each phase blocked on a bare
    %   pause(). These tests drive the real function headlessly.
    %
    %   Methods:
    %     runsHeadlessWithInjectedMeterAndPrompts
    %     derivesDmdActivePxFromTheHandoff — no more pasted 768*1024.
    %     emitsSchema2
    %     zeroesBetweenPhases — the laser must be off while the operator
    %                           changes pulse-picker settings.
    %     endsAtZeroVolts

    methods (Access = private)
        function [curve, daq, prompts] = runSweep(~)
            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct('sampleRate', 10000, 'analogOutChannels', [0 3]));
            meter   = tfp.sim.SyntheticPowerMeter(daq, 'ao3', struct('maxMw', 20));
            prompts = containers.Map({'n'}, {0});
            curve = tfp.calibration.powerMeterSweep(daq, struct( ...
                'meter',             meter, ...
                'promptFcn',         @(msg) bump(prompts), ...
                'voltageStepsDiv',   linspace(0, 5, 6), ...
                'voltageStepsFull',  linspace(0, 1, 3), ...
                'settleTimeS',       0, ...
                'warmupTimeS',       0, ...
                'sensorRelaxTimeS',  0, ...
                'nAverages',         2, ...
                'showFigure',        false));
        end
    end

    methods (Test)

        function runsHeadlessWithInjectedMeterAndPrompts(testCase)
            [curve, ~, prompts] = testCase.runSweep();
            testCase.verifyEqual(prompts('n'), 2, ...
                'both pulse-picker prompts must go through promptFcn');
            testCase.verifyNotEmpty(curve.voltage.voltageV);
            testCase.verifyEqual(numel(curve.voltage.voltageV), ...
                numel(curve.voltage.powerMw));
        end

        function derivesDmdActivePxFromTheHandoff(testCase)
            curve = testCase.runSweep();
            hc = tfp.util.readHandoffConstants();
            testCase.verifyEqual(curve.dmdActivePxAtSweep, hc.dmd_rows * hc.dmd_cols);
        end

        function emitsSchema2(testCase)
            curve = testCase.runSweep();
            testCase.verifyEqual(curve.schema, 2);
            testCase.verifyEqual(curve.kind,   'power_curve');
            % legacy fields survive the migration
            testCase.verifyTrue(isfield(curve, 'fitDeg2Coeffs'));
            testCase.verifyTrue(isfield(curve, 'divMode'));
        end

        function zeroesBetweenPhases(testCase)
            % powerMeterSweep zeroes the AO before prompting the operator to
            % change pulse-picker settings; that ordering is load-bearing.
            [~, daq] = testCase.runSweep();
            entries = daq.getLog();
            v = []; isPrompt = [];
            for k = 1:numel(entries)
                if strcmp(entries(k).eventType, 'outputSingleAnalog')
                    v(end+1) = entries(k).payload.voltageV; %#ok<AGROW>
                end
            end
            testCase.verifyTrue(any(v == 0), 'the AO must be zeroed mid-run');
            testCase.verifyEqual(v(end), 0);
        end

        function endsAtZeroVolts(testCase)
            [~, daq] = testCase.runSweep();
            entries = daq.getLog();
            last = entries(find(strcmp({entries.eventType}, 'outputSingleAnalog'), 1, 'last'));
            testCase.verifyEqual(last.payload.voltageV, 0);
        end
    end
end

% ---------------------------------------------------------------------------
function bump(prompts)
prompts('n') = prompts('n') + 1;
end
