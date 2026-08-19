function curve = powerMeterSweepSingle(laser, options)
%powerMeterSweepSingle Single-phase volts->mW calibration for the CARBIDE.
%
%   curve = tfp.calibration.powerMeterSweepSingle(laser)
%   curve = tfp.calibration.powerMeterSweepSingle(laser, options)
%
%   WHY A SECOND SWEEP. tfp.calibration.powerMeterSweep is two-phase because
%   the FS-50's pulse picker had to be switched by hand between a divided rate
%   and full rep rate mid-sweep, and the two regimes needed stitching in power
%   space. The CARBIDE runs at a fixed 100 kHz with the division set on the
%   front panel and unchanged during a sweep, so none of that machinery
%   applies: one monotone ramp, one fit. The FS-50 function is left intact for
%   build A; both share private/runPowerSweepPhase so the ramp logic exists
%   once.
%
%   Inputs:
%     laser   - tfp.hardware.LaserPowerController, already constructed with a
%               laser state. Every step goes through it, so the pulse-energy
%               interlock runs on each one. Consent is taken ONCE for the
%               ramp's ceiling via authoriseUpTo rather than per step — 25
%               dialogs would train the operator to click through them.
%     options - struct, all optional:
%       .voltageSteps  AO volts to visit; default 21 points spanning the
%                      controller's configured [carbide_voltage_min, _max]
%       .settleTimeS   dwell after each step (default 5.0)
%       .warmupTimeS   extra wait at the first non-zero step (default 5.0)
%       .nAverages     meter readings averaged per step (default 5)
%       .readPauseS    pause between averaged readings (default 0.5)
%       .meter         injected meter exposing measPower() -> W; when absent a
%                      real PM100D is opened via the TLPM driver
%       .wavelengthNm  PM100D spectral correction (default 1038)
%       .fovAreaUm2    FOV area for later power-density work
%                      (default pi*400^2, an 800 um circle)
%       .patterns      the DMD frame(s) lit during the sweep, so the interlock
%                      sees the real ON geometry rather than assuming all-ON
%       .dmdActivePx   ON count during the sweep; derived from .patterns when
%                      given, else from the handoff's full chip
%       .onStep        @(k,n,voltsSoFar,mwSoFar,stdSoFar) progress sink
%       .notes         char appended to curve.notes
%       .verbose       print per-step lines (default true)
%
%   Output: a schema-2 power curve (see tfp.calibration.normalizePowerCurve)
%   with the volts branch filled, the operator's laser state stamped, and
%   kind = 'power_curve' ready for tfp.io.saveCalibration.
%
%   Throws tfp:calibration:powerMeterSweepSingle:{badLaser,notWired,badSteps,
%   noDriver,noDevice,badMeter}; a declined authorisation surfaces as
%   tfp:hardware:LaserPowerController:confirmationDeclined.
%
%   See also tfp.calibration.powerMeterSweep, tfp.hardware.LaserPowerController.

if nargin < 2 || isempty(options), options = struct(); end
if nargin < 1 || ~isa(laser, 'tfp.hardware.LaserPowerController')
    error('tfp:calibration:powerMeterSweepSingle:badLaser', ...
        'laser must be a tfp.hardware.LaserPowerController.');
end
if ~laser.isWired()
    error('tfp:calibration:powerMeterSweepSingle:notWired', ...
        ['the CARBIDE modulator BNC is not wired: ' ...
         'laser.carbide_modulator_ao_channel is empty in the config. ' ...
         'See docs/WIRING.md.']);
end

voltageSteps = tfp.util.configField(options, 'voltageSteps', ...
    linspace(laser.voltageMin, laser.voltageMax, 21));
voltageSteps = sort(double(voltageSteps(:)'));
if numel(voltageSteps) < 3 || any(~isfinite(voltageSteps))
    error('tfp:calibration:powerMeterSweepSingle:badSteps', ...
        'options.voltageSteps must be at least 3 finite values.');
end

settleTimeS  = tfp.util.configField(options, 'settleTimeS',  5.0);
warmupTimeS  = tfp.util.configField(options, 'warmupTimeS',  5.0);
nAverages    = tfp.util.configField(options, 'nAverages',    5);
readPauseS   = tfp.util.configField(options, 'readPauseS',   0.5);
wavelengthNm = tfp.util.configField(options, 'wavelengthNm', 1038);
fovAreaUm2   = tfp.util.configField(options, 'fovAreaUm2',   pi * 400^2);
patterns     = tfp.util.configField(options, 'patterns',     []);
onStep       = tfp.util.configField(options, 'onStep',       []);
notes        = char(tfp.util.configField(options, 'notes',   ''));
verbose      = logical(tfp.util.configField(options, 'verbose', true));

% ON count during the sweep: measured from the pattern when we have one,
% otherwise the full chip from the handoff. Never a pasted 768*1024.
if ~isempty(patterns)
    dmdActivePx = nnz(logical(patterns(:, :, 1)));
else
    hc          = tfp.util.readHandoffConstants();
    dmdActivePx = hc.dmd_rows * hc.dmd_cols;
end
dmdActivePx = tfp.util.configField(options, 'dmdActivePx', dmdActivePx);

% --- meter ---
[meter, ownsMeter] = openPowerMeter(struct('meter', ...
    tfp.util.configField(options, 'meter', []), ...
    'wavelengthNm', wavelengthNm), 'powerMeterSweepSingle');
closeMeter = onCleanup(@() closeIfOwned(meter, ownsMeter));

% --- consent once, for the envelope ---
laser.beginStep('power_sweep');
if ~isempty(patterns)
    laser.notePattern(patterns);
end
laser.authoriseUpTo(max(voltageSteps), struct('step', 'power_sweep'));

% --- ramp ---
sweepOpts = struct( ...
    'setVoltsFcn', @(v) laser.setVolts(v, struct('step', 'power_sweep')), ...
    'zeroFcn',     @() laser.zeroQuiet(), ...
    'settleTimeS', settleTimeS, ...
    'warmupTimeS', warmupTimeS, ...
    'nAverages',   nAverages, ...
    'readPauseS',  readPauseS, ...
    'label',       'CARBIDE', ...
    'onStep',      onStep, ...
    'verbose',     verbose);

[powerMw, powerStd] = runPowerSweepPhase(meter, voltageSteps, sweepOpts);

laser.zero();

% --- assemble ---
laserState = laser.getLaserState();
raw = struct( ...
    'voltageV',     voltageSteps, ...
    'powerMw',      powerMw, ...
    'powerStdMw',   powerStd, ...
    'dmdActivePx',  dmdActivePx, ...
    'fovAreaUm2',   fovAreaUm2, ...
    'wavelengthNm', wavelengthNm, ...
    'aoChannel',    laser.aoChannel, ...
    'settleTimeS',  settleTimeS, ...
    'warmupTimeS',  warmupTimeS, ...
    'timestamp',    datetime('now'), ...
    'notes',        buildNotes(laser, wavelengthNm, laserState, notes));

curve = tfp.calibration.normalizePowerCurve(raw, ...
    struct('laserState', laserState, 'requireBranch', 'voltage'));
end

% ---------------------------------------------------------------------------
function closeIfOwned(meter, owned)
if owned
    try, meter.close(); catch, end
end
end

% ---------------------------------------------------------------------------
function s = buildNotes(laser, wavelengthNm, laserState, extra)
if isstruct(laserState) && isfield(laserState, 'repRateKhz')
    rep = sprintf('%g kHz / %g', laserState.repRateKhz, laserState.pulsePickerDivision);
else
    rep = 'rep rate unknown';
end
s = sprintf('CARBIDE single-phase sweep on %s, %s, %g nm', ...
    laser.aoChannel, rep, wavelengthNm);
if ~isempty(extra)
    s = sprintf('%s. %s', s, extra);
end
end
