%generate_plm_single_spot_validation  PLM remote-focus validation patterns.
%
%   Generates three phase patterns demonstrating remote focusing of a single
%   diffraction-limited spot. Each pattern is the sum of a blazed grating
%   tilt (producing a 100 µm lateral offset at the sample, to avoid the
%   zero-order block on the optical axis) and a paraxial defocus phase.
%
%   Three axial planes:  dz = -150, 0, +150 µm.
%
%   The combined unwrapped phase is wrapped mod max_phase = 2*pi*(N-1)/N
%   (N = 32 states), pupil-masked, and quantized to uint8 in 0..N-1.
%
%   Outputs (under data/plm_patterns/validation/):
%     pattern_dz_neg150.mat   (struct: pattern, dz_um, sys, x_offset_um, y_offset_um)
%     pattern_dz_000.mat
%     pattern_dz_pos150.mat
%     preview_montage.png     (3-panel grayscale montage, scaled state*8)
%
%   Geometry conventions (match tfp.hardware.PLM.computeDefocusPattern):
%     - Relay magnification M_relay maps PLM radius to BFP radius:
%         r_BFP = M_relay * r_PLM
%     - Lateral position at sample focal plane from a BFP tilt:
%         x_sample = f_obj * theta_BFP
%     - Required PLM phase gradient for x_offset at sample:
%         dphi/dx_PLM = (2*pi/lambda) * (M_relay / f_obj) * x_offset
%
%   Usage (from repo root):
%     >> run scripts/generate_plm_single_spot_validation

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% --- PLM device (mock; geometry only) ---
plm = tfp.hardware.MockPLM();
plm.initialize(struct());   % defaults: 800x904, pitch 10.8x16.2 µm, N=32, 1030 nm

% --- Optical system (Avocado 10x 0.6 NA, water) ---
sys = struct( ...
    'M_relay',  2.4, ...
    'n',        1.33, ...
    'f_obj_um', 16800, ...
    'NA',       0.6);

% --- Tilt: 100 µm lateral offset along +x at the sample plane ---
x_offset_um = 100;
y_offset_um = 0;

% --- Axial planes ---
dz_list_um = [-150, 0, 150];
labels     = {'neg150', '000', 'pos150'};

% --- Output directory ---
repoRoot   = fullfile(fileparts(mfilename('fullpath')), '..');
outputDir  = fullfile(repoRoot, 'data', 'plm_patterns', 'validation');
if ~isfolder(outputDir)
    mkdir(outputDir);
end

% --- Pixel coordinate grid at the PLM (µm, centred) ---
nRows = plm.nRows;
nCols = plm.nCols;
cx = (nCols + 1) / 2;
cy = (nRows + 1) / 2;
[jj, ii] = meshgrid(1:nCols, 1:nRows);
x_um = (jj - cx) * plm.pitchX_um;
y_um = (ii - cy) * plm.pitchY_um;
r2   = x_um.^2 + y_um.^2;

% --- Pupil radius at the PLM plane ---
r_BFP_um = sys.f_obj_um * sys.NA / sys.n;
r_PLM_um = r_BFP_um / sys.M_relay;
pupilMask = (r2 <= r_PLM_um^2);

% --- Phase scaling factors ---
lambda_um = plm.lambda_nm / 1000;

% Defocus: phi_def(r) = (pi * n * dz * M^2) / (lambda * f^2) * r^2
defocusCoeff = (pi * sys.n * sys.M_relay^2) / (lambda_um * sys.f_obj_um^2);

% Tilt:    dphi/dx_PLM = (2*pi/lambda) * (M_relay / f_obj) * x_offset
tiltKx = (2 * pi / lambda_um) * (sys.M_relay / sys.f_obj_um) * x_offset_um;
tiltKy = (2 * pi / lambda_um) * (sys.M_relay / sys.f_obj_um) * y_offset_um;
phi_tilt = tiltKx * x_um + tiltKy * y_um;

% --- Quantization parameters ---
N         = plm.nPhaseStates;
max_phase = 2 * pi * (N - 1) / N;

% --- Generate, save, and collect for montage ---
patterns = zeros(nRows, nCols, numel(dz_list_um), 'uint8');

fprintf('\nPLM single-spot validation patterns\n');
fprintf('PLM pupil radius: %.1f µm   (r_BFP %.1f µm, M_relay %.1f)\n', ...
        r_PLM_um, r_BFP_um, sys.M_relay);
fprintf('Lateral offset:   (%.0f, %.0f) µm at sample plane\n', ...
        x_offset_um, y_offset_um);
fprintf('Tilt gradient:    %.4f rad/µm at PLM  (%.3f rad/pixel along x)\n', ...
        tiltKx, tiltKx * plm.pitchX_um);

for k = 1:numel(dz_list_um)
    dz = dz_list_um(k);

    phi_defocus = defocusCoeff * dz * r2;
    phi_total   = phi_defocus + phi_tilt;

    phi_wrap = mod(phi_total, max_phase);
    phi_wrap(~pupilMask) = 0;

    state   = uint8(floor(phi_wrap * N / max_phase));
    pattern = min(state, uint8(N - 1));
    patterns(:,:,k) = pattern;

    fname = fullfile(outputDir, sprintf('pattern_dz_%s.mat', labels{k}));
    saveStruct = struct( ...
        'pattern',      pattern, ...
        'dz_um',        dz, ...
        'x_offset_um',  x_offset_um, ...
        'y_offset_um',  y_offset_um, ...
        'sys',          sys, ...
        'nPhaseStates', N, ...
        'lambda_nm',    plm.lambda_nm, ...
        'nRows',        nRows, ...
        'nCols',        nCols, ...
        'pitchX_um',    plm.pitchX_um, ...
        'pitchY_um',    plm.pitchY_um, ...
        'r_PLM_um',     r_PLM_um, ...
        'timestamp',    datetime('now'));   %#ok<NASGU>
    save(fname, '-struct', 'saveStruct');
    fprintf('  dz = %+5.0f µm   →  %s\n', dz, fname);
end

% --- Preview montage: 3 panels side-by-side, gray = state*8 ---
gap = 16;
panelGray = uint8(zeros(nRows, nCols * 3 + gap * 2));
for k = 1:numel(dz_list_um)
    gray = min(uint8(255), patterns(:,:,k) .* uint8(8));
    col0 = (k - 1) * (nCols + gap) + 1;
    panelGray(:, col0:col0 + nCols - 1) = gray;
end
montagePath = fullfile(outputDir, 'preview_montage.png');
imwrite(panelGray, montagePath);
fprintf('Montage written: %s\n', montagePath);

plm.cleanup();
fprintf('Done.\n');
