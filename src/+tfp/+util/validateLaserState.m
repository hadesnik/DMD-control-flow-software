function state = validateLaserState(state)
%validateLaserState Validate and complete the operator-entered laser state.
%
%   state = tfp.util.validateLaserState(state)
%
%   The CARBIDE control software runs on the Holo/SLM PC and this repo
%   deliberately does NOT talk to it [USER 2026-08-19]: the analog modulator
%   BNC already gives continuous power control from the DAQ PC, and the only
%   parameters a software link would add — rep rate, pulse-picker division,
%   shutter — are exactly the ones a human should change deliberately. Keeping
%   them out of software preserves the invariant the whole interlock rests on:
%   *the AO modulator voltage is the only laser parameter software can move*.
%
%   The cost of that choice is that rep rate and pulse-picker division must be
%   entered by hand, and getting them wrong is dangerous in one direction:
%   believing 100 kHz while the picker sits at /100 understates pulse energy
%   100x. So this validator is FAIL-CLOSED — a missing or nonsensical field is
%   an error, never a default.
%
%   Required fields:
%     .repRateKhz            base rep rate before the picker (kHz), > 0
%
%   Optional fields (defaulted, but see the note on frontPanelPowerW):
%     .pulsePickerDivision   integer >= 1; 1 = no division      (default 1)
%     .frontPanelPowerW      average power the laser reports (W). STRONGLY
%                            preferred by tfp.util.assertPulseEnergySafe:
%                            it is a laser-plane number, so the interlock
%                            needs no arm-transmission assumption.
%     .frontPanelSetpointNm  wavelength on the front panel     (default 1030)
%     .measuredWavelengthNm  certificate value                 (default 1038)
%     .shutterOpen           logical                           (default false)
%     .attenuatorNote        free text                         (default '')
%     .operator              free text                         (default '')
%     .laserModel            free text                         (default 'CARBIDE')
%
%   Derived fields, always overwritten:
%     .effectiveRepRateHz    repRateKhz*1e3 / pulsePickerDivision
%     .pulseEnergyUJAtFront  frontPanelPowerW*1e6 / effectiveRepRateHz, or
%                            NaN when frontPanelPowerW is not supplied
%     .enteredAt             ISO-8601 char (char, not datetime, so the struct
%                            survives jsonencode in tfp.io.sessionLog)
%
%   Both the 1030 setpoint and the 1038 certificate value are recorded because
%   they genuinely differ: 1030 is the CARBIDE's front-panel setpoint and 1038
%   is the measured value on factory certificate s/n C264570. The handoff uses
%   1038.
%
%   Throws tfp:util:validateLaserState:{badInput,missingField,badValue}.
%
%   See also tfp.util.assertPulseEnergySafe, tfp.io.sessionLog.

if nargin < 1 || ~isstruct(state) || ~isscalar(state)
    error('tfp:util:validateLaserState:badInput', ...
        'state must be a scalar struct; got %s.', class(state));
end

% --- required ---
if ~isfield(state, 'repRateKhz')
    error('tfp:util:validateLaserState:missingField', ...
        ['state.repRateKhz is required and has no safe default. Read it ' ...
         'off the CARBIDE control software on the Holo PC and enter it: ' ...
         'assuming the wrong rep rate mis-scales every pulse-energy check.']);
end
state.repRateKhz = checkPositive(state.repRateKhz, 'repRateKhz');

% --- optional, defaulted ---
if ~isfield(state, 'pulsePickerDivision') || isempty(state.pulsePickerDivision)
    state.pulsePickerDivision = 1;
end
div = state.pulsePickerDivision;
if ~isnumeric(div) || ~isscalar(div) || ~isfinite(div) || div < 1 || mod(div, 1) ~= 0
    error('tfp:util:validateLaserState:badValue', ...
        'state.pulsePickerDivision must be an integer >= 1; got %s.', ...
        num2str(div));
end
state.pulsePickerDivision = double(div);

if ~isfield(state, 'frontPanelPowerW'), state.frontPanelPowerW = []; end
if ~isempty(state.frontPanelPowerW)
    state.frontPanelPowerW = checkNonNegative(state.frontPanelPowerW, 'frontPanelPowerW');
end

state = defaultField(state, 'frontPanelSetpointNm', 1030);
state = defaultField(state, 'measuredWavelengthNm', 1038);
state = defaultField(state, 'attenuatorNote', '');
state = defaultField(state, 'operator',       '');
state = defaultField(state, 'laserModel',     'CARBIDE');

if ~isfield(state, 'shutterOpen') || isempty(state.shutterOpen)
    state.shutterOpen = false;
end
if ~(islogical(state.shutterOpen) || isnumeric(state.shutterOpen)) || ~isscalar(state.shutterOpen)
    error('tfp:util:validateLaserState:badValue', ...
        'state.shutterOpen must be a logical scalar.');
end
state.shutterOpen = logical(state.shutterOpen);

% --- derived ---
state.effectiveRepRateHz = state.repRateKhz * 1e3 / state.pulsePickerDivision;

% W -> uJ per pulse: P[W] / f[Hz] = J, x 1e6 = uJ. The handoff's worked
% example is 8.5 W at 100 kHz = 85 uJ (optics_handoff.md section 7a).
if isempty(state.frontPanelPowerW)
    state.pulseEnergyUJAtFront = NaN;
else
    state.pulseEnergyUJAtFront = state.frontPanelPowerW * 1e6 / state.effectiveRepRateHz;
end

state.enteredAt = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));

end

% ---------------------------------------------------------------------------
function s = defaultField(s, name, default)
if ~isfield(s, name) || isempty(s.(name))
    s.(name) = default;
end
end

function v = checkPositive(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
    error('tfp:util:validateLaserState:badValue', ...
        'state.%s must be a positive finite scalar.', name);
end
v = double(v);
end

function v = checkNonNegative(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v < 0
    error('tfp:util:validateLaserState:badValue', ...
        'state.%s must be a non-negative finite scalar.', name);
end
v = double(v);
end
