%run_calibrationGUI Launch the calibration GUI on the DAQ PC.
%
%   Run this from the repo root:
%       >> run_calibrationGUI
%
%   Edit CONFIG_PATH below for the rig you are on:
%     configs/real.yaml     build B — CARBIDE + DLP650LNIR (the default)
%     configs/dli4130.yaml  the borrowed DLP7000 on ALP-4.1
%     configs/mock.yaml     no hardware at all, for a dry run
%
%   Everything this app does is also available from the command line with the
%   same interlocks and the same provenance — the GUI is a view over
%   tfp.gui.CalibrationSession, not a separate implementation:
%
%       config = tfp.io.loadConfig('configs/real.yaml');
%       s = tfp.gui.CalibrationSession(config, struct('configPath','configs/real.yaml'));
%       s.setLaserState(struct('repRateKhz',100,'pulsePickerDivision',1, ...
%                              'frontPanelPowerW',8.5));
%       disp(struct2table(s.preflight()));
%       curve = s.runPowerSweep();
%       s.shutdown();
%
%   BEFORE YOU START, see docs/CALIBRATION_GUI.md. In short:
%     * the CARBIDE modulator BNC must be wired and recorded in docs/WIRING.md,
%       and laser.carbide_modulator_ao_channel set — until then the power tab
%       refuses to output;
%     * enter the laser state (rep rate, pulse-picker division, front-panel
%       power) FIRST: the pulse-energy interlock is fail-closed on rep rate;
%     * for the field-tilt tab, si_motor_helper must be running in the
%       ScanImage MATLAB on the imaging PC (port 3047).

CONFIG_PATH  = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                        'configs', 'real.yaml');
ALLOW_CONFIG_WRITE = false;   % set true on the RIG to persist results to YAML

repoRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(repoRoot, 'src'));

tfp.util.safetyChecks('arm');

config = tfp.io.loadConfig(CONFIG_PATH);

app = tfp.gui.CalibrationApp(config, struct( ...
    'configPath',       CONFIG_PATH, ...
    'allowConfigWrite', ALLOW_CONFIG_WRITE, ...
    'sessionName',      'bringup'));   %#ok<NASGU>

fprintf(['\n[run_calibrationGUI] Session directory: %s\n' ...
         '[run_calibrationGUI] Close the window (or press BEAM OFF) to stop.\n'], ...
    app.session.sessionId);
