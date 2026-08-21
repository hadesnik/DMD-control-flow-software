function fcn = syntheticPlaneBrightness(zstage, config, options)
%syntheticPlaneBrightness A stand-in for the imaging PC's per-plane means.
%
%   fcn = tfp.sim.syntheticPlaneBrightness(zstage, config)
%   fcn = tfp.sim.syntheticPlaneBrightness(zstage, config, options)
%
%   tfp.calibration.calibrateEtlPlanes REQUIRES a planeBrightnessFcn and
%   deliberately has no default: on the rig the brightness comes from
%   ScanImage, and inventing a silent one would let a session fit plane
%   depths out of nothing. For a mock session there is no ScanImage, so this
%   supplies the honest simulation instead — the same reason
%   tfp.sim.wireMockRig exists rather than letting the mock camera return
%   noise into an affine fit.
%
%   THE MODEL. Each imaging plane p sits at a fixed depth planeZUm(p). A thin
%   film is brightest in plane p when the objective puts the film at that
%   plane's focal depth, so brightness falls off as a Gaussian in the
%   distance between the current stage position and that plane:
%
%       b_p(z) = exp(-((z - planeZUm(p))^2) / (2 * sigma^2)) + noise
%
%   Reading the stage each call is what makes it a simulation of the
%   measurement rather than a lookup: calibrateEtlPlanes moves the stage and
%   then asks, exactly as it would on the rig.
%
%   options:
%     .planeZUm   plane depths (default: n_planes evenly spaced by
%                 etl.plane_spacing_um, centred on zero)
%     .sigmaUm    depth of field of one plane (default 8)
%     .noise      fractional noise (default 0.01)
%     .seed       rng seed for reproducibility (default 7)
%
%   See also tfp.calibration.calibrateEtlPlanes, tfp.sim.wireMockRig.

if nargin < 3 || isempty(options), options = struct(); end
if nargin < 2 || isempty(config),  config  = struct(); end

etlCfg   = tfp.util.configField(config, 'etl', struct());
nPlanes  = double(tfp.util.configField(etlCfg, 'n_planes', 3));
spacing  = double(tfp.util.configField(etlCfg, 'plane_spacing_um', 20));

defaultZ = ((1:nPlanes) - (nPlanes + 1) / 2) * spacing;
planeZUm = double(tfp.util.configField(options, 'planeZUm', defaultZ));
sigmaUm  = double(tfp.util.configField(options, 'sigmaUm', 8));
noise    = double(tfp.util.configField(options, 'noise', 0.01));
seed     = double(tfp.util.configField(options, 'seed', 7));

stream = RandStream('twister', 'Seed', seed);
z0     = zstage.getPositionUm();

fcn = @brightness;

    function b = brightness()
        z = zstage.getPositionUm() - z0;
        b = exp(-((z - planeZUm).^2) / (2 * sigmaUm^2));
        b = b + noise * stream.randn(size(b));
    end
end
