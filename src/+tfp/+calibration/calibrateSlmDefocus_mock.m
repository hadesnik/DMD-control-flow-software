function [calib, truth] = calibrateSlmDefocus_mock(options)
%calibrateSlmDefocus_mock Run the REAL SLM z-calibration against mocks.
%
%   [calib, truth] = tfp.calibration.calibrateSlmDefocus_mock()
%   [calib, truth] = tfp.calibration.calibrateSlmDefocus_mock(options)
%
%   Builds a self-consistent mock rig — MockDMD (spot), MockSLM (defocus
%   command), MockZStage (ruler), MockSubstageCamera (defocus-blur model
%   with a known truth slope) — and runs tfp.calibration.calibrateSlmDefocus
%   against it. The returned truth struct carries the ground-truth
%   slmUmPerCmd wired into the camera so tests can assert recovery.
%
%   options:
%     .truthSlmUmPerCmd — ground-truth um focal shift per commanded um
%                         (default 0.9 — deliberately not 1.0 so tests
%                         cannot pass by accident)
%     .dzCmdUm          — command list (default -60:20:60, small for speed)
%     .mRelay           — config m_relay (default 1.2)
%     .cameraNoise      — mock camera noise level (default 0.005)
%     .zstage           — an already-initialized tfp.hardware.ZStage to use
%                         as the ruler instead of a fresh MockZStage (lets
%                         tests drive the real calibration through another
%                         backend, e.g. a mock-transport MP285ZStage)

if nargin < 1 || isempty(options)
    options = struct();
end
truthSlope = double(tfp.util.configField(options, 'truthSlmUmPerCmd', 0.9));
dzCmdUm    = double(tfp.util.configField(options, 'dzCmdUm', -60:20:60));
mRelay     = double(tfp.util.configField(options, 'mRelay', 1.2));
camNoise   = double(tfp.util.configField(options, 'cameraNoise', 0.005));

% --- Mock rig ---------------------------------------------------------
dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', 800, 'nCols', 1280, ...
    'loadLatencyMsPerPattern', 0, 'debugFigure', false));

slm = tfp.hardware.MockSLM();
% Small SLM array keeps computeDefocusStack fast; the physics scale is
% carried by sys, not by the array size.
slm.initialize(struct('nRows', 128, 'nCols', 128, 'settle_s', 0));

zstage = tfp.util.configField(options, 'zstage', []);
if isempty(zstage)
    zstage = tfp.hardware.MockZStage();
    zstage.initialize(struct('startZUm', 0));
end

camera = tfp.hardware.MockSubstageCamera();
camera.initialize(struct( ...
    'nRows', 512, 'nCols', 512, ...
    'noiseLevel', camNoise, 'spotSigmaPx', 4, ...
    'dmd', dmd, ...
    'truthAffine', [0.35 0 40; 0 0.35 30; 0 0 1], ...
    'slm', slm, 'zstage', zstage, ...
    'slmUmPerCmd', truthSlope, 'filmZUm', 0, 'zRUm', 10));

config.objective = struct('name', 'nikon10x045');
config.slm       = struct('enabled', true, 'm_relay', mRelay, ...
                          'nStates', 256, 'pitch_um', 17.0, ...
                          'lambda_nm', 1038);

calOpts = struct('dzCmdUm', dzCmdUm, 'zStepUm', 4, 'zSearchHalfUm', 24, ...
    'sweepOptions', struct('nAverages', 2, 'threshFrac', 0.3));
calib = tfp.calibration.calibrateSlmDefocus(dmd, slm, camera, zstage, ...
    config, calOpts);

truth.slmUmPerCmd = truthSlope;
truth.interceptUm = 0;
end
