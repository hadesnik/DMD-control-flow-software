function info = wireMockRig(dmd, camera, zstage, options)
%wireMockRig Connect mock devices so a mock session actually simulates a rig.
%
%   info = tfp.sim.wireMockRig(dmd, camera, zstage)
%   info = tfp.sim.wireMockRig(dmd, camera, zstage, options)
%
%   WHY THIS EXISTS. A MockSubstageCamera constructed from YAML alone has no
%   reference to the DMD and no truth affine, so snap() returns PURE NOISE.
%   That is worse than an obvious failure: tfp.calibration.alignDMDtoCamera
%   happily thresholds the noise, finds blobs, and fits an affine to them —
%   producing a plausible-looking residual from a measurement of nothing. A
%   demo session that appears to work while measuring noise is a trap, so this
%   function wires the mock devices into a self-consistent optical model:
%
%     * the camera sees the DMD's active pattern through a known truth affine,
%       scaled so the usable patch fills most of the sensor;
%     * the spot's blur follows the z stage, so through-focus sweeps work;
%     * the excitation plane is TILTED along the dispersion diagonal, so
%       tfp.calibration.measureFieldTilt has something real to recover.
%
%   The affine is derived from the actual device sizes rather than pasted, so
%   this works for the DLP650LNIR (800x1280) and the borrowed DLP7000
%   (768x1024) alike.
%
%   options:
%     .fillFraction   how much of the shorter sensor axis the usable patch
%                     should span (default 0.85)
%     .truthGradientUmPerUm  dispersion-axis tilt; default is the handoff's
%                     design value, so a demo field-tilt run lands in band
%     .truthGrooveUmPerUm    default 0
%     .noiseLevel     default 0.01
%     .spotSigmaPx    default 4
%     .zRUm           blur Rayleigh range (default 10)
%
%   Returns info with the truth values a caller may want to compare against:
%     .truthAffine .scale .truthGradientUmPerUm .truthGrooveUmPerUm .dmdSize
%
%   Only touches mock devices; anything else is left alone and reported as
%   .wired = false.
%
%   See also tfp.hardware.MockSubstageCamera, tfp.gui.CalibrationSession.

if nargin < 4 || isempty(options), options = struct(); end

info = struct('wired', false, 'truthAffine', [], 'scale', NaN, ...
    'truthGradientUmPerUm', 0, 'truthGrooveUmPerUm', 0, 'dmdSize', []);

if ~isa(camera, 'tfp.hardware.MockSubstageCamera') || ~isa(dmd, 'tfp.hardware.MockDMD')
    return
end

fillFraction = tfp.util.configField(options, 'fillFraction', 0.85);
noiseLevel   = tfp.util.configField(options, 'noiseLevel',   0.01);
spotSigmaPx  = tfp.util.configField(options, 'spotSigmaPx',  4);
zRUm         = tfp.util.configField(options, 'zRUm',         10);

consts    = tfp.util.readHandoffConstants();
gradient  = tfp.util.configField(options, 'truthGradientUmPerUm', ...
                consts.depth_gradient_um_per_um);
groove    = tfp.util.configField(options, 'truthGrooveUmPerUm',   0);

dmdSize = [dmd.nRows, dmd.nCols];
camRows = camera.nRows;
camCols = camera.nCols;

% Scale so the usable patch spans fillFraction of the shorter sensor axis.
scale = fillFraction * min(camRows, camCols) / consts.patch_diameter_px;

% Centre the chip on the sensor: camX = scale*dmdCol + tx, and the chip centre
% must land on the sensor centre.
tx = (camCols + 1) / 2 - scale * (dmdSize(2) + 1) / 2;
ty = (camRows + 1) / 2 - scale * (dmdSize(1) + 1) / 2;
truthAffine = [scale 0 tx; 0 scale ty; 0 0 1];

camera.initialize(struct( ...
    'nRows', camRows, 'nCols', camCols, ...
    'noiseLevel', noiseLevel, 'spotSigmaPx', spotSigmaPx, ...
    'dmd', dmd, 'truthAffine', truthAffine, ...
    'zstage', zstage, 'filmZUm', 0, 'zRUm', zRUm, ...
    'tiltGradientUmPerUm', gradient, ...
    'tiltGrooveUmPerUm',   groove, ...
    'dmdSize', dmdSize));

info = struct('wired', true, 'truthAffine', truthAffine, 'scale', scale, ...
    'truthGradientUmPerUm', gradient, 'truthGrooveUmPerUm', groove, ...
    'dmdSize', dmdSize);
end
