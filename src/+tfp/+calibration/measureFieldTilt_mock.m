function [calib, truth] = measureFieldTilt_mock(options)
%measureFieldTilt_mock Drive the REAL field-tilt measurement on mock hardware.
%
%   [calib, truth] = tfp.calibration.measureFieldTilt_mock()
%   [calib, truth] = tfp.calibration.measureFieldTilt_mock(options)
%
%   Builds a MockDMD + MockZStage + MockSubstageCamera whose defocus-blur model
%   carries a known tilted excitation plane, then runs
%   tfp.calibration.measureFieldTilt against it. A correct implementation
%   recovers the injected gradients.
%
%   options:
%     .truthGradientUmPerUm  dispersion-axis gradient (default 0.03 —
%                            deliberately NOT the handoff's 0.02929, so a fit
%                            cannot pass by accidentally returning the design
%                            value)
%     .truthGrooveUmPerUm    groove-axis gradient (default 0)
%     .nRing                 field points per ring (default 8)
%     .zSearchHalfUm         (default 40) .zStepUm (default 2)
%     .zRUm                  mock blur Rayleigh range (default 10)
%     .noiseLevel            (default 0.002)
%     .dmdSize               [nRows nCols] (default [800 1280], DLP650LNIR)
%
%   truth carries .gradient, .groove, .dmd, .camera, .zstage, .config.

if nargin < 1 || isempty(options), options = struct(); end

truthGrad   = tfp.util.configField(options, 'truthGradientUmPerUm', 0.03);
truthGroove = tfp.util.configField(options, 'truthGrooveUmPerUm',   0);
nRing       = tfp.util.configField(options, 'nRing',                8);
zHalf       = tfp.util.configField(options, 'zSearchHalfUm',        40);
zStep       = tfp.util.configField(options, 'zStepUm',              2);
zRUm        = tfp.util.configField(options, 'zRUm',                 10);
noiseLevel  = tfp.util.configField(options, 'noiseLevel',           0.002);
dmdSize     = tfp.util.configField(options, 'dmdSize',              [800 1280]);

dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', dmdSize(1), 'nCols', dmdSize(2)));

zstage = tfp.hardware.MockZStage();
zstage.initialize(struct('startZUm', 0));

% The camera sees a spot whose blur is set by the distance between the tilted
% excitation surface at that field point and the stage's z. Best focus at a
% point therefore sits at filmZUm + tilt(point) — which is precisely the
% quantity measureFieldTilt fits a plane through.
camera = tfp.hardware.MockSubstageCamera();
camera.initialize(struct( ...
    'nRows', 512, 'nCols', 512, ...
    'noiseLevel', noiseLevel, 'spotSigmaPx', 4, ...
    'dmd', dmd, ...
    'truthAffine', [0.30 0 256; 0 0.30 256; 0 0 1], ...
    'zstage', zstage, ...
    'filmZUm', 0, 'zRUm', zRUm, ...
    'tiltGradientUmPerUm', truthGrad, ...
    'tiltGrooveUmPerUm',   truthGroove, ...
    'dmdSize', dmdSize));

config = struct();
config.slm    = struct('enabled', false);
config.zstage = struct('mount', 'objective', 'direction_sign', 1);

calib = tfp.calibration.measureFieldTilt(dmd, camera, zstage, config, struct( ...
    'nRing',         nRing, ...
    'zSearchHalfUm', zHalf, ...
    'zStepUm',       zStep, ...
    'zPredictClampUm', tfp.util.configField(options, 'zPredictClampUm', 4 * zHalf), ...
    'exposureS',     0, ...
    'verbose',       false, ...
    'notes',         'measureFieldTilt_mock'));

truth = struct('gradient', truthGrad, 'groove', truthGroove, ...
    'dmd', dmd, 'camera', camera, 'zstage', zstage, 'config', config, ...
    'dmdSize', dmdSize);
end
