classdef test_assertPulseEnergySafe < matlab.unittest.TestCase
    %test_assertPulseEnergySafe Pupil pulse-energy interlock (TASK-BU T-BU-1d).
    %
    %   This guards a SECOND, INDEPENDENT hazard from the ao3 average-power
    %   policy: every 4f relay of a collimated DMD forms a real focus in air at
    %   its pupil, and a high-fill ON pattern puts the whole pulse into one
    %   ~27 um spot there. The average-power guard is structurally blind to it
    %   (it sees a voltage and a duration, never the pattern).
    %
    %   The tests below deliberately pin THREE things a future "simplification"
    %   would break:
    %     1. The rep-rate INVERSION — at fixed average power, LOWERING the rep
    %        rate RAISES pulse energy, i.e. the opposite direction from the
    %        average-power guard's conservatism. See repRateInversion*.
    %     2. Sparse patterns pass easily (quadratic fill scaling is the reason
    %        the gate exists). See sparse*.
    %     3. The 40 W correction moves the DELIVERABLE energy (400 uJ, not
    %        800 uJ) but NOT the 68 uJ limit, which is an air-ionisation
    %        property of the optics. See *PowerCorrection*.
    %
    %   All tests force cfg.interactive = false so the confirmation tier takes
    %   the non-interactive (block-unless-autoConfirm) branch and never opens a
    %   dialog — the suite stays deterministic in -batch and interactively.

    methods (Access = private)

        function c = baseCfg(~, autoConfirm)
            %baseCfg The configs/real.yaml laser block, in snake_case.
            if nargin < 2 || isempty(autoConfirm)
                autoConfirm = false;
            end
            c = struct( ...
                'modulation_voltage_max',        5, ...
                'modulation_voltage_min',        0, ...
                'rep_rate_hz',                   1e5, ...
                'max_power_w',                   40, ...
                'max_pulse_energy_uj_pupil',     68, ...
                'pupil_interlock_fill_fraction', 0.2, ...
                'autoConfirmPulseEnergy',        autoConfirm, ...
                'interactive',                   false);
        end

        function p = discPattern(~, radiusPx)
            %discPattern 800x1280 logical ON disc centred on the design patch.
            %   Patch centre/radius come from opticalModel, not hardcoded here.
            m = tfp.util.opticalModel();
            H = 800; W = 1280;
            [cc, rr] = meshgrid(1:W, 1:H);
            p = ((cc - m.patchCenterPx(1)).^2 + (rr - m.patchCenterPx(2)).^2) ...
                <= radiusPx^2;
        end

        function msg = captureErrorMessage(tc, fcn, expectedId)
            %captureErrorMessage Run fcn, require it to throw expectedId, return
            %   the message text so its CONTENT can be asserted.
            %   (verifyError returns a logical, not the MException.)
            msg = '';
            try
                fcn();
                tc.verifyFail(sprintf('Expected %s, but nothing was thrown.', ...
                    expectedId));
            catch ME
                tc.verifyEqual(ME.identifier, expectedId);
                msg = ME.message;
            end
        end

    end

    methods (Test)

        % ---- the headline case: all-ON alignment frame ------------------ %

        function fullFieldAtFullPowerIsHardBlocked(tc)
            % fill = 1.0, 5 V, 100 kHz -> 400 uJ vs the 68 uJ limit.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function allOnLogicalFrameIsHardBlocked(tc)
            % The literal scripts/alpCheckerboard-style all-ON frame.
            p = true(800, 1280);
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function autoConfirmCannotBypassTheHardBlock(tc)
            % Unlike the average-power confirm tier, nothing opts past the limit.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 5.0, tc.baseCfg(true)), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        % ---- energy arithmetic: the 40 W correction --------------------- %

        function fortyWattsGivesFourHundredMicrojoulesAtHundredKilohertz(tc)
            % 40 W / 100 kHz = 400 uJ. NOT the 800 uJ printed in handoff s7,
            % which assumed an erroneous 80 W.
            info = tfp.util.assertPulseEnergySafe(0.0, 5.0, tc.baseCfg());
            tc.verifyEqual(info.avgPowerW, 40, 'AbsTol', 1e-9);
            tc.verifyEqual(info.pulseEnergyUj, 400, 'AbsTol', 1e-6);
        end

        function fullFieldExceedsLimitByAboutFiveNinetimes(tc)
            % 400 / 68 = 5.88x. The handoff banner quotes "~5.9x".
            info = tfp.util.assertPulseEnergySafe(0.0, 5.0, tc.baseCfg());
            tc.verifyEqual(info.pulseEnergyUj / info.limitUj, 5.88, 'AbsTol', 0.02);
        end

        function limitIsUnchangedByThePowerCorrection(tc)
            % 68 uJ is an air-ionisation limit set by the OPTICS and the 230 fs
            % pulse. Doubling the laser rating doubles the deliverable energy
            % but must NOT move the limit.
            c40 = tc.baseCfg();
            c80 = c40; c80.max_power_w = 80;
            i40 = tfp.util.assertPulseEnergySafe(0.0, 5.0, c40);
            i80 = tfp.util.assertPulseEnergySafe(0.0, 5.0, c80);
            tc.verifyEqual(i40.limitUj, 68);
            tc.verifyEqual(i80.limitUj, 68, ...
                'The pupil limit is an optics property; it must not track laser power.');
            tc.verifyEqual(i40.pulseEnergyUj, 400, 'AbsTol', 1e-6);
            tc.verifyEqual(i80.pulseEnergyUj, 800, 'AbsTol', 1e-6);
        end

        function linearVoltageMapMatchesTheAveragePowerGuard(tc)
            % Same map as assertLaserPowerSafe: %power = 100*(V-off)/(full-off).
            info = tfp.util.assertPulseEnergySafe(0.0, 2.5, tc.baseCfg());
            tc.verifyEqual(info.avgPowerW, 20, 'AbsTol', 1e-9);   % 50% of 40 W
            tc.verifyEqual(info.pulseEnergyUj, 200, 'AbsTol', 1e-6);
        end

        function voltageWaveformUsesItsPeak(tc)
            % A clocked AO waveform is reduced to its peak (worst case).
            wave = [0; 0; 5; 0.1; 0];
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, wave, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
            info = tfp.util.assertPulseEnergySafe(0.0, wave, tc.baseCfg());
            tc.verifyEqual(info.peakVoltageV, 5);
        end

        % ---- THE REP-RATE INVERSION ------------------------------------- %

        function repRateInversionLoweringRepRateBlocksAtTheSameVoltage(tc)
            % THE point of this guard. Identical 0.4 V command and identical
            % full fill; only the rep rate changes.
            %   100 kHz -> 3.2 W / 1e5 =  32 uJ  -> passes
            %    10 kHz -> 3.2 W / 1e4 = 320 uJ  -> HARD BLOCK
            % Lowering the rep rate is what the average-power guard calls
            % "conservative". Here it is the hazard.
            fast = tc.baseCfg();  fast.rep_rate_hz = 1e5;
            slow = tc.baseCfg();  slow.rep_rate_hz = 1e4;

            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 0.4, fast));
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 0.4, slow), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function repRateInversionAveragePowerGuardIsIndifferent(tc)
            % The companion half of the inversion: at 0.4 V (8% of max) the
            % AVERAGE-POWER guard passes silently regardless of rep rate, so it
            % cannot possibly catch the 10 kHz case above. Both guards must run.
            lcfg = struct('fullPowerVoltage', 5, 'offVoltage', 0, ...
                'confirmPct', 10, 'maxSustainedPct', 20, ...
                'sustainedDurationS', 1, 'autoConfirmPower', false, ...
                'interactive', false);
            tc.verifyWarningFree(@() tfp.util.assertLaserPowerSafe(0.4, Inf, lcfg));
        end

        function repRateInversionRemedyIsToRaiseTheRepRate(tc)
            % minSafeRepRateHz = P/limit; raising the rep rate to it clears the
            % block at the SAME voltage.
            slow = tc.baseCfg();  slow.rep_rate_hz = 1e4;
            info = tfp.util.assertPulseEnergySafe(0.0, 0.4, slow);
            tc.verifyEqual(info.minSafeRepRateHz, 1e6 * 3.2 / 68, 'RelTol', 1e-9);

            % At (just above) that rep rate the HARD BLOCK is cleared — the
            % request lands in the confirmation band instead.
            atLimit = tc.baseCfg(true);
            atLimit.rep_rate_hz = 1.001 * info.minSafeRepRateHz;
            tc.verifyWarning(@() tfp.util.assertPulseEnergySafe(1.0, 0.4, atLimit), ...
                'tfp:util:assertPulseEnergySafe:autoConfirmed');

            % Raise it further and the same command passes silently.
            fixed = slow;  fixed.rep_rate_hz = 3 * info.minSafeRepRateHz;
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 0.4, fixed));
        end

        % ---- sparse patterns pass easily -------------------------------- %

        function sparseScalarFillPassesAtFullPower(tc)
            % 2% fill at 5 V: exempt. Pupil peak is 2500x below full field.
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(0.02, 5.0, tc.baseCfg()));
        end

        function sparseSomaSizedPatternPassesAtFullPower(tc)
            % A realistic single-target spot inside the patch.
            p = tc.discPattern(6);              % ~113 px of a ~242,800 px patch
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg()));
            info = tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg());
            tc.verifyLessThan(info.fillFraction, 0.01);
            tc.verifyFalse(info.gated, 'A sparse pattern must not engage the check.');
        end

        function quadraticScalingIsReported(tc)
            % Pupil peak ~ fill^2 relative to a full-field frame. This is the
            % documented rationale for the fill gate.
            info = tfp.util.assertPulseEnergySafe(0.05, 1.0, tc.baseCfg());
            tc.verifyEqual(info.pupilPeakScale, 0.05^2, 'AbsTol', 1e-12);
        end

        % ---- the fill gate ---------------------------------------------- %

        function justBelowGateIsExempt(tc)
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(0.1999, 5.0, tc.baseCfg()));
        end

        function exactlyAtGateIsSubjectToTheCheck(tc)
            % ">= pupil_interlock_fill_fraction" is subject, not "> ".
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(0.2, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function gateIsConfigurable(tc)
            c = tc.baseCfg();  c.pupil_interlock_fill_fraction = 0.5;
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(0.3, 5.0, c));
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(0.6, 5.0, c), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        % ---- patch-restricted fill governs ------------------------------ %

        function patchFillGovernsOverWholeArrayFill(tc)
            % Only the illuminated patch carries light. A disc of radius 200
            % centred on the patch is 52% of the PATCH but only 12% of the
            % chip; averaged over the array it would slip under the 0.2 gate.
            p    = tc.discPattern(200);
            info = tfp.util.assertPulseEnergySafe(p, 0.0, tc.baseCfg());
            tc.verifyTrue(info.patchFillApplied);
            tc.verifyLessThan(info.fillArray, 0.2, ...
                'Whole-array fill should be under the gate for this pattern.');
            tc.verifyGreaterThan(info.fillPatch, 0.2);
            tc.verifyEqual(info.fillFraction, info.fillPatch, 'AbsTol', 1e-12);
            % ...and it is therefore caught at full power.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function allOnPatchIsFillOne(tc)
            p    = tc.discPattern(tfp.util.opticalModel().patchRadiusPx);
            info = tfp.util.assertPulseEnergySafe(p, 0.0, tc.baseCfg());
            tc.verifyEqual(info.fillPatch, 1, 'AbsTol', 1e-12);
            tc.verifyEqual(info.fillArray, 0.237, 'AbsTol', 0.01);
            tc.verifyEqual(info.fillFraction, 1, 'AbsTol', 1e-12);
        end

        function croppedArrayFallsBackToArrayFill(tc)
            % The patch disc does not land on a small cropped test pattern;
            % the whole-array fill governs (conservative).
            p    = true(100, 100);
            info = tfp.util.assertPulseEnergySafe(p, 0.0, tc.baseCfg());
            tc.verifyFalse(info.patchFillApplied);
            tc.verifyEqual(info.fillFraction, 1, 'AbsTol', 1e-12);
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        % ---- stacks ------------------------------------------------------ %

        function stackIsEvaluatedSliceBySliceAndWorstGoverns(tc)
            % Slices 1 and 3 are sparse; slice 2 is the all-ON alignment frame.
            stack = false(800, 1280, 3);
            stack(:, :, 1) = tc.discPattern(6);
            stack(:, :, 2) = true;
            stack(:, :, 3) = tc.discPattern(8);
            info = tfp.util.assertPulseEnergySafe(stack, 0.0, tc.baseCfg());
            tc.verifyEqual(info.nPatterns, 3);
            tc.verifyEqual(info.worstIndex, 2);
            tc.verifyEqual(info.fillFraction, 1, 'AbsTol', 1e-12);
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(stack, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function stackOfSparseSlicesPasses(tc)
            stack = false(800, 1280, 3);
            for k = 1:3
                stack(:, :, k) = tc.discPattern(5 + k);
            end
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(stack, 5.0, tc.baseCfg()));
        end

        function errorNamesTheOffendingSliceIndex(tc)
            stack = false(800, 1280, 2);
            stack(:, :, 1) = tc.discPattern(6);
            stack(:, :, 2) = true;
            msg = tc.captureErrorMessage(@() ...
                tfp.util.assertPulseEnergySafe(stack, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
            tc.verifyNotEmpty(regexp(msg, 'pattern 2', 'once'), ...
                'The error must name the offending slice.');
        end

        % ---- confirmation tier ------------------------------------------ %

        function belowConfirmBandIsSilent(tc)
            % 0.2 V -> 1.6 W -> 16 uJ, under half the 68 uJ limit.
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 0.2, tc.baseCfg()));
        end

        function confirmBandBlocksHeadless(tc)
            % 0.8 V -> 6.4 W -> 64 uJ: within the limit but above 0.5*limit.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 0.8, tc.baseCfg(false)), ...
                'tfp:util:assertPulseEnergySafe:confirmRequired');
        end

        function confirmBandAutoConfirmWarnsButAllows(tc)
            tc.verifyWarning(@() tfp.util.assertPulseEnergySafe(1.0, 0.8, tc.baseCfg(true)), ...
                'tfp:util:assertPulseEnergySafe:autoConfirmed');
        end

        function confirmBandDoesNotApplyToSparsePatterns(tc)
            % Same 0.8 V, sparse fill -> exempt, no prompt at all.
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(0.02, 0.8, tc.baseCfg(false)));
        end

        function maxSafeVoltageIsReportedAndIsTheBoundary(tc)
            % 68 uJ * 100 kHz / 40 W = 6.8 W -> 0.85 V.
            info = tfp.util.assertPulseEnergySafe(0.0, 0.1, tc.baseCfg());
            tc.verifyEqual(info.maxSafeVoltageV, 0.85, 'AbsTol', 1e-9);
            % Just under -> allowed (with autoConfirm, it is in the confirm band).
            tc.verifyWarning(@() tfp.util.assertPulseEnergySafe(1.0, 0.849, tc.baseCfg(true)), ...
                'tfp:util:assertPulseEnergySafe:autoConfirmed');
            % Just over -> hard block.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 0.851, tc.baseCfg(true)), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        % ---- laser off ---------------------------------------------------- %

        function laserOffIsAlwaysSafeEvenAllOn(tc)
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 0.0, tc.baseCfg()));
            info = tfp.util.assertPulseEnergySafe(1.0, 0.0, tc.baseCfg());
            tc.verifyEqual(info.pulseEnergyUj, 0);
            tc.verifyEqual(info.headroomFactor, Inf);
        end

        function belowOffFloorIsSafe(tc)
            c = tc.baseCfg();  c.modulation_voltage_min = 0.5;
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 0.4, c));
        end

        % ---- error message content -------------------------------------- %

        function errorMessageStatesEnergyFillLimitAndRemedy(tc)
            m = tc.captureErrorMessage(@() ...
                tfp.util.assertPulseEnergySafe(1.0, 5.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
            tc.verifyNotEmpty(regexp(m, '400', 'once'),   'must state the pulse energy (uJ)');
            tc.verifyNotEmpty(regexp(m, '1\.000', 'once'), 'must state the fill fraction');
            tc.verifyNotEmpty(regexp(m, '68', 'once'),    'must state the limit');
            tc.verifyNotEmpty(regexp(m, 'uJ', 'once'),    'must give units');
            tc.verifyNotEmpty(regexp(m, 'RAISE THE REP RATE', 'once'), ...
                'the remedy must be to raise the rep rate');
            tc.verifyNotEmpty(regexp(m, 'fill\^2', 'once'), ...
                'must explain the quadratic fill scaling as the alternative remedy');
            tc.verifyNotEmpty(regexp(m, 'not a laser spec', 'once'), ...
                'must warn against raising the limit itself');
        end

        % ---- input validation -------------------------------------------- %

        function missingVoltageErrors(tc)
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(0.5), ...
                'tfp:util:assertPulseEnergySafe:badCommand');
        end

        function nonFiniteVoltageErrors(tc)
            % Refuse to guess a power rather than silently passing.
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, NaN, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badCommand');
        end

        function outOfRangeFillErrors(tc)
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.5, 1.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badFill');
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(-0.1, 1.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badFill');
        end

        function greyscalePatternErrors(tc)
            % The DMD is binary; a grey-scale array's mean means something else.
            p = 0.5 * ones(20, 20);
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(p, 1.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badPattern');
        end

        function emptyPatternErrors(tc)
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(logical([]), 1.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badPattern');
        end

        function fourDimensionalPatternErrors(tc)
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(true(2, 2, 2, 2), 1.0, tc.baseCfg()), ...
                'tfp:util:assertPulseEnergySafe:badPattern');
        end

        function badVoltageMapErrors(tc)
            c = tc.baseCfg();  c.modulation_voltage_max = 0;
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(0.1, 1.0, c), ...
                'tfp:util:assertPulseEnergySafe:badConfig');
        end

        function binaryNumericPatternIsAccepted(tc)
            p = double(tc.discPattern(6));
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(p, 5.0, tc.baseCfg()));
        end

        % ---- config plumbing --------------------------------------------- %

        function acceptsAFullConfigWithLaserSubstruct(tc)
            full = struct('laser', tc.baseCfg());
            tc.verifyError(@() tfp.util.assertPulseEnergySafe(1.0, 5.0, full), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
        end

        function defaultsComeFromOpticalModel(tc)
            % No cfg at all -> the opticalModel defaults (40 W, 100 kHz, 68 uJ,
            % gate 0.2). Nothing in this function hardcodes them.
            m    = tfp.util.opticalModel();
            info = tfp.util.assertPulseEnergySafe(0.0, 5.0, struct('interactive', false));
            tc.verifyEqual(info.limitUj,          m.maxPulseEnergyUjPupil);
            tc.verifyEqual(info.gateFillFraction, m.pupilInterlockFillFraction);
            tc.verifyEqual(info.pulseEnergyUj,    m.maxDeliverablePulseEnergyUj, ...
                'AbsTol', 1e-6);
        end

        function camelCaseOverridesWin(tc)
            c = tc.baseCfg();
            c.maxPulseEnergyUjPupil = 1000;     % absurd, but proves the override
            tc.verifyWarningFree(@() tfp.util.assertPulseEnergySafe(1.0, 5.0, c));
        end

    end
end
