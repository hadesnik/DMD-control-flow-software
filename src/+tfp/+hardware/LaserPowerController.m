classdef LaserPowerController < handle
    %LaserPowerController Volts<->mW on the CARBIDE external-modulator BNC.
    %
    %   The single place in this repo allowed to drive the photostim laser's
    %   analog power input. Everything else — the calibration GUI, the sweeps,
    %   the experiments — asks this object, so that the interlock, the
    %   confirmation dialog, the clamp and the zero-on-every-path guarantee
    %   exist once rather than per call site.
    %
    %   WHY THERE IS NO LINK TO THE CARBIDE SOFTWARE. It runs on the Holo/SLM
    %   PC and this repo deliberately does not talk to it [USER 2026-08-19].
    %   The analog modulator BNC already gives continuous power control from
    %   the DAQ PC; the only parameters a software link would add — rep rate,
    %   pulse-picker division, shutter — are exactly the ones a human should
    %   change deliberately. Keeping them out of software preserves the
    %   invariant every safety calculation here rests on: *the AO modulator
    %   voltage is the only laser parameter software can move*. Rep rate and
    %   division therefore arrive as an operator-entered laser state (see
    %   tfp.util.validateLaserState) and are stamped into every record.
    %
    %   WIRING. As of 2026-08-19 the modulator BNC is NOT connected:
    %   configs/real.yaml carries `laser.carbide_modulator_ao_channel: ''`.
    %   Until an operator wires it and fills in docs/WIRING.md, every output
    %   call throws :notWired with the remedy in the message. That is the
    %   placeholder made load-bearing rather than a comment.
    %
    %   Construction:
    %     lp = tfp.hardware.LaserPowerController(daq, config)
    %     lp = tfp.hardware.LaserPowerController(daq, config, options)
    %
    %   config.laser fields read:
    %     .carbide_modulator_ao_channel  'ao1' etc; '' means unwired
    %     .carbide_voltage_min/_max      clamp, in volts (default 0 / 5)
    %     .carbide_calibration_file      path to a saved power curve, or ''
    %     .arm_transmission              laser -> sample fraction, or absent
    %
    %   options:
    %     .confirmFcn   @(spec) logical — informed-consent gate. Default
    %                   @tfp.util.consoleConfirmPower. Tests pass @(s) true or
    %                   @(s) false; the GUI passes a uiconfirm closure. Same
    %                   injection idiom as ManualZStage.promptFcn.
    %     .laserState   struct for tfp.util.validateLaserState
    %     .logFcn       @(eventType, payload) — session log sink; default none
    %     .simulated    struct with logical .dmd / .camera flags
    %     .confirmDeltaMw  dead band below which an increase does not re-ask
    %                   (default 0 — any increase asks)
    %
    %   POWER WITH NO CURVE. During the sweep that produces the volts->mW
    %   curve there is, by construction, no curve. Rather than skip the
    %   interlock there, the request is bounded by the operator's front-panel
    %   average power: an external modulator can only attenuate, so that is a
    %   sound upper bound on what reaches the relay pupil at any voltage. The
    %   confirmation spec flags it as .powerIsWorstCase so the operator knows
    %   the displayed pulse energy is a bound, not a measurement.
    %
    %   SAFETY ORDERING, which is not arbitrary:
    %     1. wired?  2. finite?  3. inside the configured clamp?
    %     4. tfp.util.assertPulseEnergySafe in 'error' mode — a hard refusal;
    %     5. only then the confirmation dialog.
    %   An unsafe request is refused, never offered for confirmation: asking
    %   an operator to approve something the interlock has already judged
    %   unsafe trains them to click through it.
    %
    %   ZERO ON EVERY PATH. Output is wrapped in try/catch that zeroes and
    %   rethrows (the tfp.calibration.powerMeterSweep precedent), delete()
    %   zeroes, and zero() itself is never gated by any dialog — blocking the
    %   safe direction is how a safety dialog becomes a hazard. Because
    %   outputSingleAnalog needs a live NI session, callers must shut this
    %   object down BEFORE daq.cleanup().
    %
    %   See also tfp.util.assertPulseEnergySafe, tfp.util.validateLaserState,
    %   tfp.calibration.normalizePowerCurve, tfp.util.consoleConfirmPower.

    properties (SetAccess = protected)
        aoChannel      = ''      % '' when unwired
        voltageMin     = 0
        voltageMax     = 5
        currentVolts   = 0
        currentPowerMw = NaN     % NaN when no curve is loaded
    end

    properties (Access = private)
        daq_
        config_
        curve_            = []
        confirmFcn_
        laserState_       = []
        logFcn_           = []
        simulated_        = struct('dmd', false, 'camera', false)
        confirmDeltaMw_   = 0
        armTransmission_  = []
        % pattern context: worst frame only, so a long sequence costs one frame
        patternFrame_     = []
        patternSig_       = []
        patternFracs_     = struct('onFraction', 1, 'largestBlobFraction', 1)
        % confirmation bookkeeping
        stepToken_        = ''
        lastConfirmedMw_  = -Inf
        authorisedVolts_  = -Inf
        everOutputNonZero_ = false
        released_          = false
    end

    methods
        function obj = LaserPowerController(daq, config, options)
            if nargin < 3 || isempty(options), options = struct(); end
            if nargin < 2 || isempty(config),  config  = struct(); end
            if nargin < 1 || isempty(daq)
                error('tfp:hardware:LaserPowerController:badDaq', ...
                    'a tfp.hardware.DAQ is required.');
            end
            if ~isa(daq, 'tfp.hardware.DAQ')
                error('tfp:hardware:LaserPowerController:badDaq', ...
                    'daq must be a tfp.hardware.DAQ; got %s.', class(daq));
            end
            obj.daq_    = daq;
            obj.config_ = config;

            laserCfg = tfp.util.configField(config, 'laser', struct());
            obj.aoChannel  = char(tfp.util.configField(laserCfg, ...
                'carbide_modulator_ao_channel', ''));
            obj.voltageMin = double(tfp.util.configField(laserCfg, 'carbide_voltage_min', 0));
            obj.voltageMax = double(tfp.util.configField(laserCfg, 'carbide_voltage_max', 5));
            if ~isfinite(obj.voltageMin) || ~isfinite(obj.voltageMax) ...
                    || obj.voltageMax <= obj.voltageMin
                error('tfp:hardware:LaserPowerController:badVoltageRange', ...
                    ['laser.carbide_voltage_min/_max must be finite with ' ...
                     'max > min; got [%g %g].'], obj.voltageMin, obj.voltageMax);
            end
            obj.currentVolts = obj.voltageMin;

            at = tfp.util.configField(laserCfg, 'arm_transmission', []);
            if ~isempty(at) && isnumeric(at) && isscalar(at) && at > 0 && at <= 1
                obj.armTransmission_ = double(at);
            end

            obj.confirmFcn_     = tfp.util.configField(options, 'confirmFcn', ...
                                    @tfp.util.consoleConfirmPower);
            obj.logFcn_         = tfp.util.configField(options, 'logFcn', []);
            obj.confirmDeltaMw_ = double(tfp.util.configField(options, 'confirmDeltaMw', 0));
            sim = tfp.util.configField(options, 'simulated', struct());
            obj.simulated_.dmd    = logical(tfp.util.configField(sim, 'dmd', false));
            obj.simulated_.camera = logical(tfp.util.configField(sim, 'camera', false));

            ls = tfp.util.configField(options, 'laserState', []);
            if ~isempty(ls), obj.setLaserState(ls); end

            calFile = char(tfp.util.configField(laserCfg, 'carbide_calibration_file', ''));
            if ~isempty(calFile) && isfile(calFile)
                obj.loadPowerCurve(calFile);
            end
        end

        % -------------------------------------------------------------------
        function tf = isWired(obj)
            %isWired True when a modulator AO channel is configured.
            tf = ~isempty(obj.aoChannel);
        end

        function setLaserState(obj, state)
            %setLaserState Validate and adopt the operator-entered laser state.
            obj.laserState_ = tfp.util.validateLaserState(state);
            obj.log('laser_state', obj.laserState_);
        end

        function state = getLaserState(obj)
            state = obj.laserState_;
        end

        % -------------------------------------------------------------------
        function loadPowerCurve(obj, curveOrPath)
            %loadPowerCurve Adopt a volts->mW curve from a struct or a .mat path.
            if ischar(curveOrPath) || isstring(curveOrPath)
                c = tfp.io.loadCalibration(char(curveOrPath));
            else
                c = curveOrPath;
            end
            obj.curve_ = tfp.calibration.normalizePowerCurve(c, ...
                struct('requireBranch', 'voltage'));
            obj.currentPowerMw = obj.mwForVolts(obj.currentVolts);
            obj.log('power_curve_loaded', struct( ...
                'nPoints',  numel(obj.curve_.voltage.voltageV), ...
                'maxMw',    max(obj.curve_.voltage.powerMw), ...
                'notes',    obj.curve_.notes));
        end

        function tf = hasPowerCurve(obj)
            tf = ~isempty(obj.curve_);
        end

        function volts = voltsForMw(obj, mw)
            %voltsForMw Invert the measured curve: sample-plane mW -> AO volts.
            obj.assertCurve('voltsForMw');
            [vk, pk] = obj.invertibleCurve();
            volts = interp1(pk, vk, double(mw), 'linear');
            if any(~isfinite(volts(:)))
                error('tfp:hardware:LaserPowerController:powerOutOfRange', ...
                    ['%g mW is outside the calibrated range [%.4g %.4g] mW. ' ...
                     'Extrapolating a laser power curve is how you overshoot ' ...
                     '— re-run the sweep over the range you need.'], ...
                    mw, min(pk), max(pk));
            end
        end

        function mw = mwForVolts(obj, volts)
            %mwForVolts Forward lookup; NaN outside the calibrated range, and
            %   NaN when no curve is loaded (a display query, not a gate).
            if isempty(obj.curve_)
                mw = NaN(size(volts));
                return
            end
            v = obj.curve_.voltage.voltageV;
            p = obj.curve_.voltage.powerMw;
            [v, iv] = sort(v(:)');
            p = p(iv);
            mw = interp1(v, p, double(volts), 'linear');
        end

        % -------------------------------------------------------------------
        function notePattern(obj, patterns)
            %notePattern Record the DMD pattern the beam is about to pass.
            %   Keeps only the worst single frame (largest contiguous ON blob),
            %   which is what the interlock takes the max over anyway — so a
            %   25-frame calibration sequence costs one frame of memory, not 25.
            %   A change of pattern at non-zero power forces re-confirmation:
            %   the ON and blob fractions changed, so the pupil estimate did.
            [frame, fracs, sig] = tfp.hardware.LaserPowerController.worstFrame(patterns);
            changed = ~isequal(sig, obj.patternSig_);
            obj.patternFrame_ = frame;
            obj.patternFracs_ = fracs;
            obj.patternSig_   = sig;
            if changed
                obj.lastConfirmedMw_ = -Inf;   % force a fresh confirmation
                obj.authorisedVolts_ = -Inf;   % the envelope was for the old pattern
                obj.log('pattern_noted', fracs);
            end
        end

        % -------------------------------------------------------------------
        function info = setVolts(obj, volts, context)
            %setVolts Drive the modulator to a voltage, gated and logged.
            if nargin < 3, context = struct(); end
            info = obj.commandOutput(double(volts), context);
        end

        function info = setPowerMw(obj, mw, context)
            %setPowerMw Drive the modulator to a sample-plane power.
            if nargin < 3, context = struct(); end
            obj.assertCurve('setPowerMw');
            info = obj.commandOutput(obj.voltsForMw(mw), context);
        end

        function zero(obj)
            %zero Drive the modulator to its minimum. Never gated, never asks.
            obj.assertWired('zero');
            obj.daq_.outputSingleAnalog(obj.aoChannel, obj.voltageMin);
            obj.currentVolts   = obj.voltageMin;
            obj.currentPowerMw = obj.mwForVolts(obj.voltageMin);
            obj.log('ao_zero', struct('channel', obj.aoChannel, ...
                'voltageV', obj.voltageMin));
        end

        function zeroQuiet(obj)
            %zeroQuiet zero() that warns instead of throwing.
            %   For error paths and destructors, where the DAQ session may
            %   already be gone and a throw would mask the original fault.
            try
                obj.zero();
            catch ME
                warning('tfp:hardware:LaserPowerController:zeroFailed', ...
                    ['could not zero the modulator (%s). Check the AO output ' ...
                     'on a scope before assuming the beam is off.'], ME.message);
            end
        end

        function s = getState(obj)
            %getState Everything a view needs to render, in one struct.
            s = struct( ...
                'wired',          obj.isWired(), ...
                'aoChannel',      obj.aoChannel, ...
                'voltageMin',     obj.voltageMin, ...
                'voltageMax',     obj.voltageMax, ...
                'currentVolts',   obj.currentVolts, ...
                'currentPowerMw', obj.currentPowerMw, ...
                'hasPowerCurve',  obj.hasPowerCurve(), ...
                'laserState',     obj.laserState_, ...
                'onFraction',     obj.patternFracs_.onFraction, ...
                'largestBlobFraction', obj.patternFracs_.largestBlobFraction, ...
                'simulated',      obj.simulated_);
        end

        function info = authoriseUpTo(obj, maxVolts, context)
            %authoriseUpTo Consent once to a whole voltage ramp, not step by step.
            %   A power sweep is a monotonically increasing ramp under operator
            %   supervision. Asking per step would produce 25 dialogs and train
            %   the operator to click through them, which is worse than not
            %   asking at all. So consent is taken ONCE for the envelope — the
            %   dialog shows the maximum the ramp will reach — after which
            %   setVolts up to that ceiling proceeds silently.
            %
            %   The HARD INTERLOCK is not waived: assertPulseEnergySafe still
            %   runs on every single step. Only the dialog is suppressed, and
            %   only up to the authorised ceiling. beginStep and any pattern
            %   change revoke the authorisation.
            if nargin < 3, context = struct(); end
            obj.assertWired('authorise a power ramp');
            maxVolts = double(maxVolts);
            if ~isscalar(maxVolts) || ~isfinite(maxVolts) ...
                    || maxVolts < obj.voltageMin || maxVolts > obj.voltageMax
                error('tfp:hardware:LaserPowerController:voltageOutOfRange', ...
                    ['ramp ceiling %.3f V is outside the configured CARBIDE ' ...
                     'modulator range [%.3f %.3f] V.'], ...
                    maxVolts, obj.voltageMin, obj.voltageMax);
            end

            if isfield(context, 'patterns') && ~isempty(context.patterns)
                obj.notePattern(context.patterns);
            end

            maxMw = obj.mwForVolts(maxVolts);
            [info, isWorstCase] = obj.runInterlock(maxMw, 'error');

            spec = obj.buildSpec(maxVolts, maxMw, info, context);
            spec.powerIsWorstCase = isWorstCase;
            spec.title    = sprintf('Authorise power ramp to %.3f V%s', maxVolts, ...
                stepSuffix(context, obj.stepToken_));
            spec.severity = 'danger';        % an envelope is always worth a look
            spec.defaultAnswer = false;
            spec.warnings{end+1} = sprintf(['this authorises every step up to ' ...
                '%.3f V without a further prompt. The pulse-energy interlock ' ...
                'still runs on each step; only the dialog is suppressed.'], maxVolts);

            obj.log('power_confirm', spec);
            ok = obj.confirmFcn_(spec);
            if ~(islogical(ok) || isnumeric(ok)) || ~isscalar(ok) || ~ok
                obj.log('power_declined', spec);
                error('tfp:hardware:LaserPowerController:confirmationDeclined', ...
                    'operator declined the power ramp to %.3f V; no output was made.', ...
                    maxVolts);
            end
            obj.authorisedVolts_ = maxVolts;
            obj.lastConfirmedMw_ = nanToNegInf(maxMw);
            obj.log('ramp_authorised', struct('maxVolts', maxVolts, 'maxMw', maxMw));
        end

        function revokeAuthorisation(obj)
            %revokeAuthorisation Drop any ramp envelope; the next increase asks.
            obj.authorisedVolts_ = -Inf;
            obj.lastConfirmedMw_ = -Inf;
        end

        function beginStep(obj, stepName)
            %beginStep Mark a new calibration step.
            %   A new step forces a confirmation even at unchanged power: the
            %   beam path and pattern context have changed around it.
            obj.stepToken_       = char(stepName);
            obj.lastConfirmedMw_ = -Inf;
            obj.authorisedVolts_ = -Inf;
            obj.log('step_start', struct('step', obj.stepToken_));
        end

        function release(obj)
            %release Mark an orderly shutdown; the destructor then stays quiet.
            %   Without this, a normal shutdown (which zeroes the laser and
            %   THEN cleans up the DAQ) triggers a second zero attempt from the
            %   destructor against a dead DAQ session, and warns about a beam
            %   that was deliberately turned off a moment earlier. Crying wolf
            %   on a safety warning is how it stops being read.
            obj.released_ = true;
        end

        function delete(obj)
            if obj.released_, return; end
            if ~isempty(obj.daq_) && isvalid(obj.daq_) && obj.isWired()
                obj.zeroQuiet();
            end
        end
    end

    % =======================================================================
    methods (Access = private)

        function info = commandOutput(obj, volts, context)
            obj.assertWired('output');

            if ~isnumeric(volts) || ~isscalar(volts) || ~isfinite(volts)
                error('tfp:hardware:LaserPowerController:badVoltage', ...
                    'voltage must be a finite scalar; got %s.', mat2str(volts));
            end
            if volts < obj.voltageMin || volts > obj.voltageMax
                error('tfp:hardware:LaserPowerController:voltageOutOfRange', ...
                    ['%.3f V is outside the configured CARBIDE modulator range ' ...
                     '[%.3f %.3f] V (laser.carbide_voltage_min/_max). This is ' ...
                     'the laser''s limit, not the DAQ board''s.'], ...
                    volts, obj.voltageMin, obj.voltageMax);
            end

            % A simulated DMD means the pattern on the chip is unknown, so the
            % blob fraction the interlock relies on is a fiction. Refuse to put
            % real light through a fictional pattern.
            if obj.simulated_.dmd && ~isa(obj.daq_, 'tfp.hardware.MockDAQ') ...
                    && volts > obj.voltageMin
                error('tfp:hardware:LaserPowerController:simulatedRigNoOutput', ...
                    ['the DMD is simulated but the DAQ is real: the pattern ' ...
                     'actually on the chip is unknown, so the interlock''s ' ...
                     'ON-blob fraction would be a guess. Fix the DMD backend ' ...
                     'before putting light on the sample.']);
            end

            if isfield(context, 'patterns') && ~isempty(context.patterns)
                obj.notePattern(context.patterns);
            end
            if isfield(context, 'stepToken') && ~isempty(context.stepToken) ...
                    && ~strcmp(char(context.stepToken), obj.stepToken_)
                obj.beginStep(context.stepToken);
            end

            requestedMw = obj.mwForVolts(volts);

            % --- 4. hard interlock: refuse before asking ---
            [info, isWorstCase] = obj.runInterlock(requestedMw, 'error');

            % --- 5. informed consent ---
            if obj.needsConfirmation(volts, requestedMw, info)
                spec = obj.buildSpec(volts, requestedMw, info, context);
                spec.powerIsWorstCase = isWorstCase;
                obj.log('power_confirm', spec);
                ok = obj.confirmFcn_(spec);
                if ~(islogical(ok) || isnumeric(ok)) || ~isscalar(ok) || ~ok
                    obj.log('power_declined', spec);
                    error('tfp:hardware:LaserPowerController:confirmationDeclined', ...
                        ['operator declined the power step (%s). No output was ' ...
                         'made; the modulator remains at %.3f V.'], ...
                        spec.title, obj.currentVolts);
                end
                obj.lastConfirmedMw_ = nanToNegInf(requestedMw);
            end

            % --- output, zeroing on any fault (the powerMeterSweep precedent) ---
            try
                obj.daq_.outputSingleAnalog(obj.aoChannel, volts);
            catch ME
                obj.zeroQuiet();
                rethrow(ME);
            end

            obj.currentVolts   = volts;
            obj.currentPowerMw = requestedMw;
            if volts > obj.voltageMin
                obj.everOutputNonZero_ = true;
            end
            obj.log('ao_set', struct('channel', obj.aoChannel, ...
                'voltageV', volts, 'powerMw', requestedMw, ...
                'pulseEnergyUJ', info.pulseEnergyUJ, 'verdict', info.verdict));
        end

        % ---------------------------------------------------------------
        function [info, isWorstCase] = runInterlock(obj, requestedMw, mode)
            opts = struct('mode', mode, 'powerReference', 'sample', ...
                'label', 'LaserPowerController');
            if ~isempty(obj.armTransmission_)
                opts.armTransmission = obj.armTransmission_;
            end

            % No curve => the sample-plane power is genuinely unknown. This is
            % not an edge case: it is the state during the very sweep that
            % produces the curve. Bound it instead of guessing — the external
            % modulator can only ATTENUATE, so the laser's front-panel average
            % power is a sound upper bound on what reaches the relay pupil at
            % any modulator voltage. assertPulseEnergySafe takes [] as "use
            % laserState.frontPanelPowerW", which is exactly that bound, and
            % fails closed if the operator has not entered it.
            isWorstCase = isnan(requestedMw);
            if isWorstCase
                mwArg = [];
            else
                mwArg = requestedMw;
            end
            info = tfp.util.assertPulseEnergySafe(obj.patternFrame_, mwArg, ...
                obj.laserState_, opts);
            if isWorstCase
                info.warnings{end+1} = sprintf(['no volts->mW curve loaded: ' ...
                    'the figures above assume the laser''s full front-panel ' ...
                    '%.3g W reaches the pupil, which is a worst-case upper ' ...
                    'bound (the modulator can only attenuate). Actual power ' ...
                    'at %s is lower and unmeasured.'], ...
                    obj.laserState_.frontPanelPowerW, obj.aoChannel);
            end
        end

        function tf = needsConfirmation(obj, volts, requestedMw, info)
            % Never for the safe direction.
            if volts <= obj.voltageMin
                tf = false;
                return
            end
            % Inside an authorised ramp envelope: the operator already
            % consented to this and everything below it.
            if volts <= obj.authorisedVolts_
                tf = false;
                return
            end
            % First light of the session always asks.
            if ~obj.everOutputNonZero_
                tf = true;
                return
            end
            % A caution-verdict request always asks, regardless of direction.
            if ~strcmp(info.verdict, 'ok')
                tf = true;
                return
            end
            % An increase beyond the dead band asks. With no curve the mW are
            % NaN, so fall back to comparing volts.
            if isnan(requestedMw)
                tf = volts > obj.currentVolts;
            else
                tf = requestedMw > nanToNegInf(obj.lastConfirmedMw_) + obj.confirmDeltaMw_;
            end
        end

        function spec = buildSpec(obj, volts, requestedMw, info, context)
            step = char(tfp.util.configField(context, 'step', obj.stepToken_));

            firstLight = ~obj.everOutputNonZero_;
            if ~strcmp(info.verdict, 'ok') || info.marginX < 2 || firstLight
                severity = 'danger';
            elseif requestedMw > 2 * max(obj.currentPowerMw, eps)
                severity = 'caution';
            else
                severity = 'info';
            end

            if firstLight
                title = 'First light this session';
            else
                title = 'Increase laser power';
            end
            if ~isempty(step)
                title = sprintf('%s — %s', title, step);
            end

            spec = struct( ...
                'title',               title, ...
                'step',                step, ...
                'severity',            severity, ...
                'requestedMw',         requestedMw, ...
                'requestedV',          volts, ...
                'previousMw',          obj.currentPowerMw, ...
                'previousV',           obj.currentVolts, ...
                'aoChannel',           obj.aoChannel, ...
                'pulseEnergyUJ',       info.pulseEnergyUJ, ...
                'ceilingUJ',           info.ceilingUJ, ...
                'marginX',             info.marginX, ...
                'pupilIntensityWcm2',  info.pupilIntensityWcm2, ...
                'thresholdWcm2',       info.thresholdWcm2, ...
                'onFraction',          info.onFraction, ...
                'largestBlobFraction', info.largestBlobFraction, ...
                'laserState',          obj.laserState_, ...
                'warnings',            {info.warnings}, ...
                'powerIsWorstCase',    false, ...
                'defaultAnswer',       ~strcmp(severity, 'danger'));
        end

        % ---------------------------------------------------------------
        function assertWired(obj, what)
            if obj.isWired(), return; end
            error('tfp:hardware:LaserPowerController:notWired', ...
                ['cannot %s: no CARBIDE modulator AO channel is configured. ' ...
                 'Connect the CARBIDE external-modulator BNC to an NI-6323 AO ' ...
                 'terminal, record the terminal, cable label, voltage range ' ...
                 'and polarity in docs/WIRING.md, then set ' ...
                 'laser.carbide_modulator_ao_channel in configs/real.yaml ' ...
                 '(it is '''' today).'], what);
        end

        function assertCurve(obj, what)
            if obj.hasPowerCurve(), return; end
            error('tfp:hardware:LaserPowerController:noPowerCurve', ...
                ['cannot %s without a volts->mW curve. Run the power ' ...
                 'calibration first (setVolts still works — that is how the ' ...
                 'sweep that produces the curve is driven).'], what);
        end

        function [vk, pk] = invertibleCurve(obj)
            v = obj.curve_.voltage.voltageV(:)';
            p = obj.curve_.voltage.powerMw(:)';
            [v, iv] = sort(v);
            p = p(iv);
            % A real modulator curve is monotone but may sit flat at zero below
            % threshold and jitter by a noise floor. Reject a genuine decrease;
            % keep only strictly-increasing steps for the inversion.
            noise = 1e-3 * max(abs(p));
            if any(diff(p) < -noise)
                error('tfp:hardware:LaserPowerController:nonMonotonicCurve', ...
                    ['the power curve decreases with voltage somewhere, so it ' ...
                     'cannot be inverted. Re-run the sweep — a non-monotonic ' ...
                     'curve usually means the meter was still settling.']);
            end
            keep = [true, diff(p) > 0];
            vk = v(keep);
            pk = p(keep);
            if numel(pk) < 2
                error('tfp:hardware:LaserPowerController:nonMonotonicCurve', ...
                    'the power curve has fewer than 2 distinct power levels.');
            end
        end

        function log(obj, eventType, payload)
            if isempty(obj.logFcn_), return; end
            try
                obj.logFcn_(eventType, payload);
            catch ME
                warning('tfp:hardware:LaserPowerController:logFailed', ...
                    'session log sink threw on ''%s'': %s', eventType, ME.message);
            end
        end
    end

    % =======================================================================
    methods (Static, Access = private)
        function [frame, fracs, sig] = worstFrame(patterns)
            %worstFrame The frame with the largest contiguous ON blob.
            if isempty(patterns)
                frame = [];
                fracs = struct('onFraction', 1, 'largestBlobFraction', 1);
                sig   = 'empty';
                return
            end
            pats    = logical(patterns);
            nPx     = size(pats, 1) * size(pats, 2);
            haveIpt = exist('bwconncomp', 'file') == 2;
            bestK   = 1;
            bestBlob = -1;
            onMax   = 0;
            for k = 1:size(pats, 3)
                f   = pats(:, :, k);
                nOn = nnz(f);
                onMax = max(onMax, nOn / nPx);
                if haveIpt && nOn > 0
                    cc   = bwconncomp(f);
                    blob = max(cellfun(@numel, cc.PixelIdxList));
                else
                    blob = nOn;   % conservative upper bound
                end
                if blob > bestBlob
                    bestBlob = blob;
                    bestK    = k;
                end
            end
            frame = pats(:, :, bestK);
            fracs = struct('onFraction', onMax, ...
                'largestBlobFraction', max(bestBlob, 0) / nPx);
            sig   = [size(pats), nnz(pats), bestBlob, bestK];
        end
    end
end

% ---------------------------------------------------------------------------
function v = nanToNegInf(v)
if isnan(v), v = -Inf; end
end

function s = stepSuffix(context, fallback)
step = '';
if isstruct(context) && isfield(context, 'step') && ~isempty(context.step)
    step = char(context.step);
elseif ~isempty(fallback)
    step = char(fallback);
end
if isempty(step), s = ''; else, s = sprintf(' — %s', step); end
end
