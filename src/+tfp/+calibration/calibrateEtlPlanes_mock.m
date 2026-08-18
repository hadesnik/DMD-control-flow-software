function [calib, truth] = calibrateEtlPlanes_mock(options)
%calibrateEtlPlanes_mock Run the REAL ETL-plane z-calibration against mocks.
%
%   [calib, truth] = tfp.calibration.calibrateEtlPlanes_mock()
%   [calib, truth] = tfp.calibration.calibrateEtlPlanes_mock(options)
%
%   MockZStage supplies the ruler; the plane-brightness function is
%   synthetic — each imaging plane's mean brightness is a Gaussian in
%   (stageZ - truthPlaneZ) with the configured axial width, exactly the
%   thin-film physics the real measurement sees.
%
%   options:
%     .truthPlaneZUm — ground-truth plane depths (default [-17, 0.5, 18])
%     .axialSigmaUm  — brightness profile sigma (default 6)
%     .zPositionsUm  — stage grid (default -35:2.5:35)

if nargin < 1 || isempty(options)
    options = struct();
end
truthZ  = double(tfp.util.configField(options, 'truthPlaneZUm', [-17, 0.5, 18]));
sigmaUm = double(tfp.util.configField(options, 'axialSigmaUm', 6));
zGrid   = double(tfp.util.configField(options, 'zPositionsUm', -35:2.5:35));

zstage = tfp.hardware.MockZStage();
zstage.initialize(struct('startZUm', 0));

brightnessFcn = @() exp(-(zstage.getPositionUm() - truthZ).^2 / (2 * sigmaUm^2));

config.etl = struct('n_planes', numel(truthZ));
calib = tfp.calibration.calibrateEtlPlanes(zstage, config, struct( ...
    'planeBrightnessFcn', brightnessFcn, 'zPositionsUm', zGrid));

truth.planeZUm = truthZ;
end
