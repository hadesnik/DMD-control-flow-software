function info = slm_first_light(spots_xy_um, opts)
%slm_first_light SLM-PC first-light bring-up: display a multi-spot 2D hologram.
%
%   info = slm_first_light()                  % default 3x3 grid, config backend
%   info = slm_first_light(spots_xy_um)        % N x 2 [x y] spots, SLM sample um
%   info = slm_first_light(spots_xy_um, opts)
%
%   Run ON the SLM PC (after `addpath('src')` and `addpath('scripts/slm_pc_setup')`).
%   Computes a 3D-SHOT replication hologram for a set of 2D spot locations
%   (SLM sample-plane micrometres, z = 0) and displays it on the Meadowlark
%   (or a MockSLM dry-run).  Pair it with the substage-camera live preview
%   (scripts/basler_live_preview on the DAQ PC) to confirm the spots illuminate
%   a thin fluorescent slide.  The pattern is held until you press Enter (or
%   opts.holdSeconds elapses); on any exit the SLM is blanked and powered off.
%
%   This is a STANDALONE bring-up tool: no msocket, no DAQ, no ScanImage. It
%   isolates the hologram -> optics -> spots path so first light is easy to
%   debug.  Once it works, the integrated path is slm_pc_server (on this PC),
%   driven by tfp.hardware.RemoteSLM from the DAQ PC.
%
%   First-light %VERIFY checklist (this test resolves these against the slide):
%     - axis signs / orientation: do spots land where predicted, or mirrored /
%       transposed?  (lateralGratingPhase sign; x<->y).  Note it, then set the
%       SI<->SLM calibration accordingly.
%     - lateral scale: spot spacing vs commanded um confirms f_ft_um / mag /
%       pitch_um (i.e. dx_focal_um).
%     - phase LUT: a wrong cfg.slmConfig.lutFile shows as ghost orders / low
%       efficiency.  Set lutFile for your wavelength before trusting brightness.
%
%   Inputs:
%     spots_xy_um  N x 2 [x y] target positions, SLM sample um.  Default: a 3x3
%                  grid at -60/0/+60 um (9 spots, inside addressableRadiusUm).
%     opts (optional struct):
%       .backend      'meadowlark' | 'mock'    (default: cfg.backend)
%       .efficiency   N x 1 GSW weights        (default: from efficiency map,
%                                               else uniform)
%       .applyEffMap  logical, use the efficiency-map file if set (default true)
%       .holdSeconds  hold time before blank   (default: [] = wait for Enter)
%
%   Output:
%     info  struct with .targets (Nx3), .predCol/.predRow (predicted focal
%           pixels), .etaEffective, .mask (uint8), .backend.
%
%   See also: slm_pc_config, slm_pc_server, tfp.patterns.threeDShot.composeHologram,
%             tfp.hardware.Meadowlark1024_SLM, scripts/basler_live_preview.

if nargin < 1 || isempty(spots_xy_um)
    g = [-60, 0, 60];
    [gx, gy] = meshgrid(g, g);
    spots_xy_um = [gx(:), gy(:)];          % default 3x3 grid (9 spots)
end
if nargin < 2 || isempty(opts)
    opts = struct();
end

cfg     = slm_pc_config();
backend = cfg.backend;
if isfield(opts, 'backend') && ~isempty(opts.backend)
    backend = opts.backend;
end

% --- CGH params (merge the validation fields the dispatcher/server also add) ---
params = tfp.patterns.threeDShot.defaultParams(cfg.slmConfig);
params.maxCells            = cfg.slmConfig.maxCells;
params.addressableRadiusUm = cfg.slmConfig.addressableRadiusUm;
params.minSpacingUm        = cfg.slmConfig.minSpacingUm;

% --- Targets (SLM sample um, z=0 for 2D), validated (cap/radius/spacing) ---
targets = [double(spots_xy_um), zeros(size(spots_xy_um, 1), 1)];
targets = tfp.util.validateSLMTargets(targets, params, 'slm_first_light');
N = size(targets, 1);

% --- Per-spot efficiency weights ---
applyEff = ~isfield(opts, 'applyEffMap') || opts.applyEffMap;
if isfield(opts, 'efficiency') && ~isempty(opts.efficiency)
    eta = double(opts.efficiency(:));
elseif applyEff
    effMap = tfp.patterns.threeDShot.loadEfficiencyMap(cfg.efficiencyMap_file);
    eta    = tfp.patterns.threeDShot.efficiencyAtTargets(targets, effMap);
else
    eta = ones(N, 1);
end

% --- Compute the hologram ---
[mask, ~, gsInfo] = tfp.patterns.threeDShot.composeHologram( ...
    targets, params, struct('efficiency', eta));

% --- Build the SLM device ---
switch lower(char(backend))
    case 'meadowlark'
        slm = tfp.hardware.Meadowlark1024_SLM(cfg.slmConfig);
    case 'mock'
        slm = tfp.hardware.MockSLM();
        slm.initialize(cfg.slmConfig);
    otherwise
        error('slm_first_light:badBackend', ...
            'backend must be ''meadowlark'' or ''mock''; got ''%s''.', backend);
end

% --- Predicted focal-plane spot pixels (for the operator) ---
cx = (params.Nx + 1) / 2;
cy = (params.Ny + 1) / 2;
predCol = round(cx + targets(:, 1) / params.dx_focal_um);
predRow = round(cy + targets(:, 2) / params.dy_focal_um);

fprintf('\n=== slm_first_light ===\n');
fprintf('backend: %s | %d spot(s) | etaEffective=%.3f | dx_focal=%.3f um/px\n', ...
    char(backend), N, gsInfo.etaEffective, params.dx_focal_um);
fprintf(' spot   x_um   y_um  -> focal pixel (col,row)   [%%VERIFY axis signs on slide]\n');
for k = 1:N
    fprintf('  %2d  %6.1f %6.1f  -> (%4d, %4d)\n', ...
        k, targets(k, 1), targets(k, 2), predCol(k), predRow(k));
end

% Blank + power off on any exit (error, Ctrl-C, normal return).
cleanup = onCleanup(@() localTeardown(slm)); %#ok<NASGU>

% --- Display and hold ---
slm.slmPower(true);
slm.displayPhase(mask);
fprintf(['\nPattern displayed on the SLM. View the slide on the substage camera\n' ...
         '(run basler_live_preview on the DAQ PC).\n']);

if isfield(opts, 'holdSeconds') && ~isempty(opts.holdSeconds)
    pause(opts.holdSeconds);
else
    input('Press Enter to blank and power off the SLM... ', 's');
end

info = struct('targets', targets, 'predCol', predCol, 'predRow', predRow, ...
              'etaEffective', gsInfo.etaEffective, 'mask', mask, ...
              'backend', char(backend));
end

% --- Local helper ---
function localTeardown(slm)
try, slm.blank();        catch, end %#ok<CTCH>
try, slm.slmPower(false); catch, end %#ok<CTCH>
try, slm.cleanup();      catch, end %#ok<CTCH>
end
