classdef test_laser_state < matlab.unittest.TestCase
    %test_laser_state tfp.util.validateLaserState — the operator-entered laser
    %   state that stands in for a software link to the CARBIDE control
    %   software on the Holo PC.
    %
    %   Methods:
    %     repRateIsRequired          — no default; a wrong rep rate mis-scales
    %                                  every pulse-energy check, so it is
    %                                  fail-closed rather than assumed.
    %     defaultsAreFilled          — the optional fields land at their
    %                                  documented values.
    %     derivesEffectiveRepRate    — the pulse picker divides the rep rate.
    %     derivesFrontPanelPulseEnergy — the handoff's own worked example:
    %                                  8.5 W at 100 kHz is 85 uJ.
    %     pulseEnergyNaNWithoutPower — no front-panel wattage, no derived energy.
    %     rejectsBadValues           — division, rep rate, shutter, non-struct.
    %     enteredAtIsChar            — survives jsonencode in tfp.io.sessionLog.

    methods (Test)

        function repRateIsRequired(testCase)
            testCase.verifyError( ...
                @() tfp.util.validateLaserState(struct('pulsePickerDivision', 1)), ...
                'tfp:util:validateLaserState:missingField');
        end

        function defaultsAreFilled(testCase)
            s = tfp.util.validateLaserState(struct('repRateKhz', 100));
            testCase.verifyEqual(s.pulsePickerDivision,   1);
            testCase.verifyEqual(s.frontPanelSetpointNm,  1030);
            testCase.verifyEqual(s.measuredWavelengthNm,  1038);
            testCase.verifyFalse(s.shutterOpen);
            testCase.verifyEqual(s.laserModel, 'CARBIDE');
            testCase.verifyEmpty(s.frontPanelPowerW);
        end

        function derivesEffectiveRepRate(testCase)
            s = tfp.util.validateLaserState( ...
                struct('repRateKhz', 100, 'pulsePickerDivision', 10));
            testCase.verifyEqual(s.effectiveRepRateHz, 1e4, 'RelTol', 1e-12);
        end

        function derivesFrontPanelPulseEnergy(testCase)
            % optics_handoff.md section 7a: 8.5 W at 100 kHz = 85 uJ per pulse.
            s = tfp.util.validateLaserState(struct( ...
                'repRateKhz', 100, 'frontPanelPowerW', 8.5));
            testCase.verifyEqual(s.pulseEnergyUJAtFront, 85, 'RelTol', 1e-12);
        end

        function pulseEnergyNaNWithoutPower(testCase)
            s = tfp.util.validateLaserState(struct('repRateKhz', 100));
            testCase.verifyTrue(isnan(s.pulseEnergyUJAtFront));
        end

        function rejectsBadValues(testCase)
            testCase.verifyError(@() tfp.util.validateLaserState(42), ...
                'tfp:util:validateLaserState:badInput');
            testCase.verifyError(@() tfp.util.validateLaserState( ...
                struct('repRateKhz', 0)), 'tfp:util:validateLaserState:badValue');
            testCase.verifyError(@() tfp.util.validateLaserState( ...
                struct('repRateKhz', 100, 'pulsePickerDivision', 2.5)), ...
                'tfp:util:validateLaserState:badValue');
            testCase.verifyError(@() tfp.util.validateLaserState( ...
                struct('repRateKhz', 100, 'pulsePickerDivision', 0)), ...
                'tfp:util:validateLaserState:badValue');
            testCase.verifyError(@() tfp.util.validateLaserState( ...
                struct('repRateKhz', 100, 'frontPanelPowerW', -1)), ...
                'tfp:util:validateLaserState:badValue');
        end

        function enteredAtIsChar(testCase)
            s = tfp.util.validateLaserState(struct('repRateKhz', 100));
            testCase.verifyClass(s.enteredAt, 'char');
            % must round-trip through jsonencode: tfp.io.sessionLog uses it.
            testCase.verifyClass(jsonencode(s), 'char');
        end
    end
end
