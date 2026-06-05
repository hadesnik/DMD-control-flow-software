classdef test_assertLaserPowerSafe < matlab.unittest.TestCase
    %test_assertLaserPowerSafe Laser-power safety policy + DAQ choke-point checks.
    %
    %   All tests force cfg.interactive = false so the policy takes the
    %   non-interactive (block-unless-autoConfirm) branch and never opens a
    %   dialog — the suite stays deterministic whether runtests is launched in
    %   -batch or interactively.

    methods (TestMethodTeardown)
        function clearOverride(~)
            % Ensure the persistent calibration override never leaks between tests.
            w = warning('off', 'all');
            tfp.util.assertLaserPowerSafe('overrideOff');
            warning(w);
        end
    end

    methods (Access = private)
        function c = baseCfg(~, autoConfirm)
            c = struct('fullPowerVoltage', 5, 'offVoltage', 0, ...
                'confirmPct', 10, 'maxSustainedPct', 20, ...
                'sustainedDurationS', 1, 'autoConfirmPower', autoConfirm, ...
                'interactive', false);
        end

        function daq = makeMockDaq(~, autoConfirm)
            daq = tfp.hardware.MockDAQ();
            dcfg.sampleRate         = 1000;
            dcfg.analogInChannels   = [];
            dcfg.analogOutChannels  = [3];
            dcfg.digitalOutChannels = {};
            dcfg.digitalInChannels  = {};
            dcfg.aiRangeV           = [-5 5];
            daq.initialize(dcfg);
            lcfg = struct('fs50_ao_channel', 'ao3', ...
                'modulation_voltage_max', 5, 'modulation_voltage_min', 0, ...
                'confirm_power_pct', 10, 'max_sustained_power_pct', 20, ...
                'sustained_duration_s', 1, 'autoConfirmPower', autoConfirm, ...
                'interactive', false);
            daq.configureLaserSafety(lcfg);
        end
    end

    methods (Test)

        % ---- policy tiers ------------------------------------------------ %
        function offIsAlwaysSafe(tc)
            tc.verifyWarningFree(@() tfp.util.assertLaserPowerSafe(0, Inf, tc.baseCfg(false)));
        end

        function belowConfirmIsSilent(tc)
            % 0.4 V = 8% (<= 10%), sustained -> silent OK.
            tc.verifyWarningFree(@() tfp.util.assertLaserPowerSafe(0.4, Inf, tc.baseCfg(false)));
        end

        function exactlyConfirmThresholdIsSilent(tc)
            % 0.5 V = 10% exactly (<= confirmPct) -> silent OK.
            tc.verifyWarningFree(@() tfp.util.assertLaserPowerSafe(0.5, Inf, tc.baseCfg(false)));
        end

        function aboveConfirmBlocksHeadless(tc)
            % 0.75 V = 15% (>10%, <=20%), no autoConfirm -> blocked headless.
            tc.verifyError(@() tfp.util.assertLaserPowerSafe(0.75, Inf, tc.baseCfg(false)), ...
                'tfp:util:assertLaserPowerSafe:confirmRequired');
        end

        function aboveConfirmAutoConfirmAllows(tc)
            % 0.75 V = 15%, autoConfirm=true -> allowed (warns, no error).
            tc.verifyWarning(@() tfp.util.assertLaserPowerSafe(0.75, Inf, tc.baseCfg(true)), ...
                'tfp:util:assertLaserPowerSafe:autoConfirmed');
        end

        function exactly20pctSustainedIsNotHardBlock(tc)
            % 1.0 V = 20% exactly (== cap, not over), sustained, autoConfirm
            % -> allowed (confirmation tier), not a hard block.
            tc.verifyWarning(@() tfp.util.assertLaserPowerSafe(1.0, Inf, tc.baseCfg(true)), ...
                'tfp:util:assertLaserPowerSafe:autoConfirmed');
        end

        function sustainedOverCapHardBlocksEvenAutoConfirm(tc)
            % 2.0 V = 40% for 1.0 s (>= sustained) -> HARD BLOCK even with autoConfirm.
            tc.verifyError(@() tfp.util.assertLaserPowerSafe(2.0, 1.0, tc.baseCfg(true)), ...
                'tfp:util:assertLaserPowerSafe:sustainedOverCap');
        end

        function briefOverCapAllowedWithAutoConfirm(tc)
            % 2.0 V = 40% for 0.5 s (< sustained) -> brief burst, allowed (autoConfirm).
            tc.verifyWarning(@() tfp.util.assertLaserPowerSafe(2.0, 0.5, tc.baseCfg(true)), ...
                'tfp:util:assertLaserPowerSafe:autoConfirmed');
        end

        function briefOverCapBlocksHeadlessNoAutoConfirm(tc)
            % 2.0 V = 40% for 0.5 s, no autoConfirm -> blocked (needs confirm).
            tc.verifyError(@() tfp.util.assertLaserPowerSafe(2.0, 0.5, tc.baseCfg(false)), ...
                'tfp:util:assertLaserPowerSafe:confirmRequired');
        end

        function nanDurationTreatedAsSustained(tc)
            % Unknown duration -> conservative (sustained); 40% -> hard block.
            tc.verifyError(@() tfp.util.assertLaserPowerSafe(2.0, NaN, tc.baseCfg(true)), ...
                'tfp:util:assertLaserPowerSafe:sustainedOverCap');
        end

        % ---- override ----------------------------------------------------- %
        function overrideBypassesThenRestores(tc)
            tc.verifyWarning(@() tfp.util.assertLaserPowerSafe('overrideOn', 'test'), ...
                'tfp:util:assertLaserPowerSafe:overrideOn');
            % With override active, even 100% sustained is allowed.
            tc.verifyWarningFree(@() tfp.util.assertLaserPowerSafe(5.0, Inf, tc.baseCfg(false)));
            tfp.util.assertLaserPowerSafe('overrideOff');
            % Restored -> the same request is hard-blocked.
            tc.verifyError(@() tfp.util.assertLaserPowerSafe(5.0, Inf, tc.baseCfg(false)), ...
                'tfp:util:assertLaserPowerSafe:sustainedOverCap');
        end

        function badCommandErrors(tc)
            tc.verifyError(@() tfp.util.assertLaserPowerSafe('bogus'), ...
                'tfp:util:assertLaserPowerSafe:badCommand');
        end

        % ---- DAQ choke-point enforcement (MockDAQ) ----------------------- %
        function daqOutputSingleAnalogSustainedOverCapBlocks(tc)
            daq = tc.makeMockDaq(false);
            tc.verifyError(@() daq.outputSingleAnalog('ao3', 2.0), ...
                'tfp:util:assertLaserPowerSafe:sustainedOverCap');
        end

        function daqOutputSingleAnalogLowPowerOK(tc)
            daq = tc.makeMockDaq(false);
            tc.verifyWarningFree(@() daq.outputSingleAnalog('ao3', 0.4));   % 8%
        end

        function daqOutputSingleAnalogOffOK(tc)
            daq = tc.makeMockDaq(false);
            tc.verifyWarningFree(@() daq.outputSingleAnalog('ao3', 0));      % laser off
        end

        function daqNonLaserChannelUnchecked(tc)
            % ao0 is not the laser channel -> no power check even at 4 V (80%).
            daq = tc.makeMockDaq(false);
            tc.verifyWarningFree(@() daq.outputSingleAnalog('ao0', 4.0));
        end

        function daqQueueClockedAOComputesOnTime(tc)
            % Brief 1.5 V (30%) pulse < 1 s with autoConfirm -> allowed;
            % the same level held >= 1 s -> sustained hard block.
            daqBrief = tc.makeMockDaq(true);
            scfg.sampleRate = 1000; scfg.aiChannels = []; scfg.aoChannels = 3;
            scfg.diLines = {}; scfg.doLines = {}; scfg.frameClockLine = '';
            daqBrief.startContinuousSession(scfg);
            brief = 1.5 * ones(50, 1);      % 0.05 s on-time
            tc.verifyWarning(@() daqBrief.queueClockedAO(brief, 1000, 'immediate'), ...
                'tfp:util:assertLaserPowerSafe:autoConfirmed');
            daqBrief.stopContinuousSession();

            daqLong = tc.makeMockDaq(true);
            daqLong.startContinuousSession(scfg);
            long = 1.5 * ones(1000, 1);     % 1.0 s on-time (>= sustained)
            tc.verifyError(@() daqLong.queueClockedAO(long, 1000, 'immediate'), ...
                'tfp:util:assertLaserPowerSafe:sustainedOverCap');
            daqLong.stopContinuousSession();
        end

    end
end
