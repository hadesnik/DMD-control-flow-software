classdef test_pulse_energy_safety < matlab.unittest.TestCase
    %test_pulse_energy_safety tfp.util.assertPulseEnergySafe — the DMD
    %   relay-pupil air-breakdown interlock (optics_handoff.md section 7a).
    %
    %   scripts/alignmentField.m and scripts/alpSmokeTest43.m have pointed at
    %   this function as "the programmatic gate" since 2026-07 while it did not
    %   exist. These tests pin the behaviour they were promising.
    %
    %   Methods:
    %     operatingPointPasses        — 8.5 W / 100 kHz = 85 uJ, the handoff's
    %                                   own worked example, under the 89 uJ cap.
    %     overCeilingThrows           — 9.5 W = 95 uJ.
    %     pulsePickerRaisesPulseEnergy — 0.9 W at /10 is 90 uJ and throws, even
    %                                   though 0.9 W at /1 would be trivial.
    %                                   This is the failure the manual laser
    %                                   panel exists to prevent.
    %     sparsePatternPassesTheBlobGate — 200 uJ is fine when the largest
    %                                   contiguous blob is 0.09% of the chip.
    %     emptyPatternIsTreatedAsAllOn — same power, no pattern: enforced.
    %     pupilIntensityWarnsNearThreshold / pupilIntensityThrowsAboveThreshold
    %     blobFloorIsNotTheSlmConstant — why 0.10 here and 0.02 there.
    %     armTransmissionWarnsWhenAssumed
    %     frontPanelPowerNeedsNoTransmission
    %     unknownPowerFailsClosed
    %     badLaserStateFailsClosed
    %     reportModeNeitherThrowsNorWarns — what the confirm dialog uses.
    %     infoCarriesEveryDisplayedNumber

    properties (Constant)
        % 100 kHz, no pulse-picker division: the CARBIDE's operating point.
        LaserState = struct('repRateKhz', 100, 'pulsePickerDivision', 1);
    end

    methods (Access = private)

        function frame = allOn(~)
            frame = true(100, 100);
        end

        function frame = sparse(~)
            % One 3x3 blob in 100x100 = 9e-4 of the chip, well under the
            % 0.02 blob-fraction floor.
            frame = false(100, 100);
            frame(50:52, 50:52) = true;
        end

        function opts = laserRef(~, varargin)
            opts = struct('powerReference', 'laser');
            for k = 1:2:numel(varargin)
                opts.(varargin{k}) = varargin{k+1};
            end
        end
    end

    methods (Test)

        function operatingPointPasses(testCase)
            % 8.5 W at 100 kHz = 85 uJ, under the 89 uJ ceiling. All-ON at this
            % energy sits at 4.8e13 W/cm^2 vs the ~5e13 threshold, so the
            % handoff's own operating point is 'caution', not 'unsafe'.
            info = tfp.util.assertPulseEnergySafe(testCase.allOn(), 8500, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            testCase.verifyEqual(info.pulseEnergyUJ, 85, 'RelTol', 1e-9);
            testCase.verifyEqual(info.verdict, 'caution');
        end

        function overCeilingThrows(testCase)
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 9500, testCase.LaserState, testCase.laserRef()), ...
                'tfp:util:assertPulseEnergySafe:pulseEnergyExceeded');
        end

        function pulsePickerRaisesPulseEnergy(testCase)
            % 0.9 W at /10 -> 10 kHz -> 90 uJ. Believing /1 here would
            % understate the pulse energy tenfold.
            state = struct('repRateKhz', 100, 'pulsePickerDivision', 10);
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 900, state, testCase.laserRef()), ...
                'tfp:util:assertPulseEnergySafe:pulseEnergyExceeded');

            % Same power, no division: 0.9 uJ, entirely safe.
            info = tfp.util.assertPulseEnergySafe(testCase.allOn(), 900, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            testCase.verifyEqual(info.verdict, 'ok');
        end

        function sparsePatternPassesTheBlobGate(testCase)
            % 20 W at 100 kHz = 200 uJ, far over the ceiling — but the pupil
            % peak scales with the SQUARE of the contiguous fraction, so a
            % 0.09% blob is orders of magnitude below threshold.
            info = tfp.util.assertPulseEnergySafe(testCase.sparse(), 20000, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            testCase.verifyEqual(info.pulseEnergyUJ, 200, 'RelTol', 1e-9);
            testCase.verifyLessThan(info.largestBlobFraction, info.blobFractionFloor);
            testCase.verifyEqual(info.verdict, 'ok');

            % and in 'error' mode it genuinely does not throw
            tfp.util.assertPulseEnergySafe(testCase.sparse(), 20000, ...
                testCase.LaserState, testCase.laserRef());
        end

        function emptyPatternIsTreatedAsAllOn(testCase)
            % Identical power to the sparse case above. An unknown pattern is
            % not a safe pattern, so it is enforced as all-ON.
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                [], 20000, testCase.LaserState, testCase.laserRef()), ...
                'tfp:util:assertPulseEnergySafe:pulseEnergyExceeded');
        end

        function pupilIntensityWarnsNearThreshold(testCase)
            testCase.verifyWarning(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 8500, testCase.LaserState, testCase.laserRef()), ...
                'tfp:util:assertPulseEnergySafe:pupilIntensityNearThreshold');
        end

        function pupilIntensityThrowsAboveThreshold(testCase)
            % CLAUDE.md's warning made concrete: run a half-lit chip at the
            % CARBIDE's full 40 W and the relay pupil sees breakdown, even
            % though the DMD's own 50% ON cap is satisfied. Here check 1 is
            % gated off (blob 0.5 < floor 0.9) so this exercises check 2 alone
            % — the continuous pupil-intensity physics.
            half = false(100, 100);
            half(1:50, :) = true;              % one contiguous blob, 50% of chip
            opts = testCase.laserRef('blobFractionFloor', 0.9);

            info = tfp.util.assertPulseEnergySafe(half, 40000, ...
                testCase.LaserState, testCase.laserRef( ...
                    'blobFractionFloor', 0.9, 'mode', 'report'));
            testCase.verifyEqual(info.pulseEnergyUJ, 400, 'RelTol', 1e-9);
            testCase.verifyEqual(info.largestBlobFraction, 0.5, 'RelTol', 1e-9);
            testCase.verifyGreaterThanOrEqual(info.pupilIntensityWcm2, ...
                info.thresholdWcm2);
            testCase.verifyEqual(info.verdict, 'unsafe');

            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                half, 40000, testCase.LaserState, opts), ...
                'tfp:util:assertPulseEnergySafe:pupilIntensityExceeded');
        end

        function blobFloorIsNotTheSlmConstant(testCase)
            % Documents a deliberate divergence: assertSlmPowerSafe uses 0.02
            % because its hazard (a spectral line on the LC, post-grating) is
            % roughly binary. This hazard is pre-grating and scales as the
            % SQUARE of the blob fraction, so its floor is the 10% where the
            % handoff's own section 7a table begins.
            info = tfp.util.assertPulseEnergySafe(testCase.sparse(), 900, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            testCase.verifyEqual(info.blobFractionFloor, 0.10);
        end

        function armTransmissionWarnsWhenAssumed(testCase)
            % Sample-plane power with no measured transmission: the default
            % 0.182 is a guess and must announce itself.
            testCase.verifyWarning(@() tfp.util.assertPulseEnergySafe( ...
                testCase.sparse(), 5, testCase.LaserState), ...
                'tfp:util:assertPulseEnergySafe:armTransmissionAssumed');

            % Supplying a measured value silences it.
            info = tfp.util.assertPulseEnergySafe(testCase.sparse(), 5, ...
                testCase.LaserState, struct('armTransmission', 0.2, 'mode', 'report'));
            testCase.verifyFalse(info.armTransmissionAssumed);
            testCase.verifyEqual(info.laserPowerMw, 25, 'RelTol', 1e-9);
        end

        function frontPanelPowerNeedsNoTransmission(testCase)
            % The assumption-free path: powerMw = [] falls back to the
            % operator-entered front-panel wattage, already at the laser.
            state = struct('repRateKhz', 100, 'frontPanelPowerW', 8.5);
            info  = tfp.util.assertPulseEnergySafe(testCase.allOn(), [], ...
                state, struct('mode', 'report'));
            testCase.verifyEqual(info.pulseEnergyUJ,  85, 'RelTol', 1e-9);
            testCase.verifyEqual(info.powerReference, 'laser');
            testCase.verifyFalse(info.armTransmissionAssumed);
        end

        function unknownPowerFailsClosed(testCase)
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), [], testCase.LaserState), ...
                'tfp:util:assertPulseEnergySafe:unknownPower');
        end

        function badLaserStateFailsClosed(testCase)
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 100, struct('pulsePickerDivision', 1), ...
                testCase.laserRef()), ...
                'tfp:util:assertPulseEnergySafe:badLaserState');
        end

        function reportModeNeitherThrowsNorWarns(testCase)
            % The confirmation dialog needs the numbers without the interlock
            % firing on the question it is asking.
            f = @() tfp.util.assertPulseEnergySafe(testCase.allOn(), 20000, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            testCase.verifyWarningFree(f);
            info = f();
            testCase.verifyEqual(info.verdict, 'unsafe');
        end

        function infoCarriesEveryDisplayedNumber(testCase)
            info = tfp.util.assertPulseEnergySafe(testCase.sparse(), 900, ...
                testCase.LaserState, testCase.laserRef('mode', 'report'));
            expected = {'pulseEnergyUJ', 'ceilingUJ', 'marginX', 'repRateHz', ...
                'laserPowerMw', 'powerReference', 'armTransmission', ...
                'armTransmissionAssumed', 'onFraction', 'largestBlobFraction', ...
                'blobFractionFloor', 'pupilIntensityWcm2', 'thresholdWcm2', ...
                'pupilRefWcm2', 'pupilRefPulseUJ', 'verdict', 'warnings'};
            for k = 1:numel(expected)
                testCase.verifyTrue(isfield(info, expected{k}), ...
                    sprintf('info is missing field %s', expected{k}));
            end
            caps = tfp.util.readHandoffConstants();
            testCase.verifyEqual(info.ceilingUJ, caps.safe_pulse_energy_uJ);
        end

        function badOptionsRejected(testCase)
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 100, testCase.LaserState, ...
                struct('mode', 'shout')), ...
                'tfp:util:assertPulseEnergySafe:badMode');
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 100, testCase.LaserState, ...
                struct('powerReference', 'pupil')), ...
                'tfp:util:assertPulseEnergySafe:badOptions');
            testCase.verifyError(@() tfp.util.assertPulseEnergySafe( ...
                testCase.allOn(), 100, testCase.LaserState, ...
                struct('armTransmission', 1.5)), ...
                'tfp:util:assertPulseEnergySafe:badOptions');
        end
    end
end
