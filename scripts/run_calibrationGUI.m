function app = run_calibrationGUI(configPath, varargin)
%run_calibrationGUI Launch the calibration GUI.
%
%   app = run_calibrationGUI()                      % configs/real.yaml (the rig)
%   app = run_calibrationGUI('configs/mock.yaml')   % DEMO — no hardware at all
%   app = run_calibrationGUI(path, 'allowConfigWrite', true)
%
%   Config choices:
%     configs/real.yaml     build B — CARBIDE + DLP650LNIR (default)
%     configs/dli4130.yaml  the borrowed DLP7000 on ALP-4.1
%     configs/mock.yaml     DEMO: every device simulated, runs on any machine
%
%   DEMO MODE. With configs/mock.yaml the whole app runs with no hardware and
%   no drivers — useful on a laptop to learn the workflow before the bench
%   session. tfp.sim.wireMockRig connects the mock camera to the mock DMD
%   through a known truth affine and a tilted excitation plane, and the power
%   sweep uses tfp.sim.SyntheticPowerMeter, so every step produces a real
%   measurement OF A SIMULATION rather than a plausible fit to noise. A red
%   banner names every simulated device, and `app.session.mockTruth()` returns
%   the injected ground truth to compare a result against.
%
%   Name-value options are forwarded to tfp.gui.CalibrationApp:
%     'allowConfigWrite'  persist results into the YAML (rig only; always
%                         refused for a mock session). Default false.
%     'sessionName'       suffix for the session directory
%     'visible'           false to build the window hidden (smoke tests)
%
%   BEFORE A REAL RUN, see docs/CALIBRATION_GUI.md. In short:
%     * the CARBIDE modulator BNC must be wired and recorded in docs/WIRING.md,
%       and laser.carbide_modulator_ao_channel set — until then the power tab
%       refuses to output;
%     * enter the laser state FIRST: the pulse-energy interlock is fail-closed
%       on rep rate;
%     * for the field-tilt tab, si_motor_helper must be running in the
%       ScanImage MATLAB on the imaging PC (port 3047).
%
%   Everything the app does is also available from the command line with the
%   same interlocks and the same provenance — see docs/CALIBRATION_GUI.md,
%   "Running without the GUI".

repoRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(repoRoot, 'src'));

if nargin < 1 || isempty(configPath)
    configPath = fullfile(repoRoot, 'configs', 'real.yaml');
elseif ~isfile(configPath)
    % Accept a repo-relative path from any working directory.
    candidate = fullfile(repoRoot, configPath);
    if isfile(candidate)
        configPath = candidate;
    end
end

tfp.util.safetyChecks('arm');

config = tfp.io.loadConfig(configPath);

opts = struct('configPath', configPath, 'sessionName', 'bringup', ...
    'allowConfigWrite', false);
for k = 1:2:numel(varargin)
    opts.(varargin{k}) = varargin{k+1};
end

app = tfp.gui.CalibrationApp(config, opts);

isDemo = strcmpi(char(tfp.util.configField(config, 'hardwareKind', '')), 'mock');
fprintf('\n[run_calibrationGUI] config  : %s%s\n', configPath, ...
    ternary(isDemo, '   *** DEMO — every device simulated ***', ''));
fprintf('[run_calibrationGUI] session : %s\n', app.session.sessionId);
if isDemo
    fprintf(['[run_calibrationGUI] Start on the Laser state tab, apply it, then ' ...
             'work left to right.\n' ...
             '[run_calibrationGUI] Ground truth of the simulation: ' ...
             'app.session.mockTruth()\n']);
end
fprintf('[run_calibrationGUI] Close the window (or press BEAM OFF) to stop.\n');
end

% ---------------------------------------------------------------------------
function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end
