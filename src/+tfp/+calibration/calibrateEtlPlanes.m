function calib = calibrateEtlPlanes(zstage, config, options)
%calibrateEtlPlanes Map Optotune ETL imaging planes to physical um.
%
%   calib = tfp.calibration.calibrateEtlPlanes(zstage, config, options)
%
%   The ETL's um scale in ScanImage is NOT trusted, so each imaging plane
%   is put on the same MP-285 ruler the SLM calibration used: with a THIN
%   fluorescent film on the stage and ScanImage free-running its
%   n_planes ETL volume, the objective is stepped through z. Each imaging
%   plane p lights up (max mean brightness) when the objective puts the
%   film at that plane's focal depth — so the brightness(z) peak per plane
%   IS that plane's physical z.
%
%       planeZUm(p) = argmax_z brightness_p(z)      (moment/parabola fit)
%
%   How brightness is obtained is abstracted behind
%   options.planeBrightnessFcn (REQUIRED):
%       B = planeBrightnessFcn()   % 1 x nPlanes mean brightness, called
%                                  % after each z move
%   Real-rig implementations:
%     - live: per-plane channel means over the F-stream / helper socket
%       (see scripts/imaging_pc_setup/si_motor_helper.m port pattern);
%     - offline: operator acquires one SI stack per z position and a
%       wrapper reads the means back (slower, zero new plumbing).
%   The mock harness (calibrateEtlPlanes_mock) supplies a synthetic one.
%
%   options:
%     .planeBrightnessFcn  REQUIRED (see above)
%     .zPositionsUm        stage grid (default -40:2:40, relative to start)
%     .nPlanes             default config.etl.n_planes (default 3)
%
%   Output calib struct:
%     .kind = 'etl_planes', .planeZUm (1 x nPlanes, relative to the sweep
%     start position), .nPlanes, .zPositionsUm, .brightness (nZ x nPlanes),
%     .zRuler, .timestamp, .notes
%
%   Compose with the SLM calibration via
%   tfp.calibration.composeZCalibration — both must use the SAME zstage
%   axis and sign convention.

if nargin < 3 || isempty(options)
    options = struct();
end
if ~isa(zstage, 'tfp.hardware.ZStage')
    error('tfp:calibration:calibrateEtlPlanes:badZStage', ...
        'zstage must be a tfp.hardware.ZStage.');
end
if ~isfield(options, 'planeBrightnessFcn') || ...
        ~isa(options.planeBrightnessFcn, 'function_handle')
    error('tfp:calibration:calibrateEtlPlanes:missingBrightnessFcn', ...
        ['options.planeBrightnessFcn is required — a fcn returning the ' ...
         '1 x nPlanes mean brightness after each z move (see help).']);
end
brightnessFcn = options.planeBrightnessFcn;

etlCfg  = tfp.util.configField(config, 'etl', struct());
nPlanes = double(tfp.util.configField(options, 'nPlanes', ...
          tfp.util.configField(etlCfg, 'n_planes', 3)));
zGrid   = double(tfp.util.configField(options, 'zPositionsUm', -40:2:40));
zGrid   = zGrid(:)';
nZ      = numel(zGrid);
if nZ < 5
    error('tfp:calibration:calibrateEtlPlanes:tooFewSteps', ...
        'Need at least 5 z steps to localise plane peaks (got %d).', nZ);
end

z0 = zstage.getPositionUm();
brightness = nan(nZ, nPlanes);
for k = 1:nZ
    zstage.moveToUm(z0 + zGrid(k));
    B = brightnessFcn();
    if numel(B) ~= nPlanes
        error('tfp:calibration:calibrateEtlPlanes:badBrightness', ...
            'planeBrightnessFcn returned %d values (expected %d planes).', ...
            numel(B), nPlanes);
    end
    brightness(k, :) = double(B(:)');
end
zstage.moveToUm(z0);

planeZUm = nan(1, nPlanes);
for p = 1:nPlanes
    planeZUm(p) = peakZ(zGrid, brightness(:, p)');
    fprintf('[calibrateEtlPlanes] plane %d -> z = %+7.2f um\n', p, planeZUm(p));
end
if any(~isfinite(planeZUm))
    error('tfp:calibration:calibrateEtlPlanes:peakNotFound', ...
        ['Could not localise a brightness peak for every plane — widen ' ...
         'options.zPositionsUm or check the film.']);
end

calib.kind         = 'etl_planes';
calib.planeZUm     = planeZUm;
calib.nPlanes      = nPlanes;
calib.zPositionsUm = zGrid;
calib.brightness   = brightness;
calib.zRuler       = zstage.rulerId();
calib.timestamp    = datetime('now');
calib.notes        = sprintf('%d planes over %d z steps [%g..%g] um', ...
    nPlanes, nZ, zGrid(1), zGrid(end));
end

% --- Local helper ---

function zPk = peakZ(zUm, b)
%peakZ Parabolic vertex around the sampled brightness maximum.
valid = isfinite(b);
if nnz(valid) < 3
    zPk = NaN;
    return
end
[~, iMax] = max(b);
lo  = max(1, iMax - 2);
hi  = min(numel(zUm), iMax + 2);
sel = lo:hi;
sel = sel(isfinite(b(sel)));
if numel(sel) < 3
    zPk = zUm(iMax);
    return
end
p = polyfit(zUm(sel), b(sel), 2);
if p(1) >= 0
    zPk = zUm(iMax);   % no downward curvature: take the sampled max
    return
end
zPk = -p(2) / (2 * p(1));
if zPk < min(zUm) || zPk > max(zUm)
    zPk = zUm(iMax);
end
end
