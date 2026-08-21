function stack = syntheticMarkStack(ledger, zcal, options)
%syntheticMarkStack A simulated ETL z-stack of burn/bleach marks.
%
%   stack = tfp.sim.syntheticMarkStack(ledger, zcal, options)
%
%   The section 7 direct verify needs pixel data from the imaging PC. On a
%   mock session there is none, so rather than stopping the demo halfway
%   through the procedure this renders the stack the marks WOULD have
%   produced — dark discs on a bright slab, each darkest in the plane its
%   commanded defocus actually reaches.
%
%   It is a simulation of the sample, not of the answer. The depth of each
%   mark is computed forwards through the physics —
%
%       depth = slmUmPerCmd * dzCmd + intercept + gradient * x_disp
%
%   — and the plane it lands in falls out of the composed plane depths. So
%   tfp.calibration.locateMarksInStack and verifyZCalibration do real work
%   on it, and a WRONG composed calibration produces disagreement here just
%   as it would on the bench. The tilt term is what makes the section 7.4
%   sign row work at all: every mark there is commanded to dz = 0, and only
%   the tilted excitation plane puts them at different depths.
%
%   options:
%     .calibration  lateral calibration carrying dmdToScan_affine (REQUIRED
%                   in spirit — marks are placed exactly where
%                   locateMarksInStack will look for them)
%     .nPlanes      planes per volume (default from zcal.nPlanes, else 3)
%     .nVolumes     volumes to render (default 1)
%     .markRadiusPx radius of a mark at best focus (default 6)
%     .gradientUmPerUm  dispersion tilt (default: the handoff design value)
%     .umPerPxDisp  sample um per DMD px along dispersion (default: handoff)
%     .background   slab brightness (default 1000)
%     .noise        fractional noise (default 0.02)
%     .seed         rng seed (default 11)
%
%   See also tfp.calibration.locateMarksInStack, tfp.sim.wireMockRig.

if nargin < 3 || isempty(options), options = struct(); end

nPlanes = double(tfp.util.configField(options, 'nPlanes', ...
    tfp.util.configField(zcal, 'nPlanes', 3)));
nVolumes = double(tfp.util.configField(options, 'nVolumes', 1));
markR    = double(tfp.util.configField(options, 'markRadiusPx', 6));
bg       = double(tfp.util.configField(options, 'background', 1000));
noise    = double(tfp.util.configField(options, 'noise', 0.02));
seed     = double(tfp.util.configField(options, 'seed', 11));

h = handoff();
gradient   = double(tfp.util.configField(options, 'gradientUmPerUm', ...
    getfielddef(h, 'depth_gradient_um_per_um', 0.02843)));
umPerPxDisp = double(tfp.util.configField(options, 'umPerPxDisp', ...
    getfielddef(h, 'um_per_px_disp', 2.6528)));

calib = tfp.util.configField(options, 'calibration', []);
if isempty(calib) || ~isfield(calib, 'dmdToScan_affine')
    error('tfp:sim:syntheticMarkStack:noCalibration', ...
        ['options.calibration must carry dmdToScan_affine: the marks have ' ...
         'to be rendered where locateMarksInStack will look for them, or ' ...
         'the simulation is testing nothing.']);
end
A = calib.dmdToScan_affine;

planeZ = tfp.util.configField(zcal, 'etlPlaneZUm', ...
    ((1:nPlanes) - (nPlanes + 1) / 2) * 20);
slope     = double(tfp.util.configField(zcal, 'slmUmPerCmd', 1));
intercept = double(tfp.util.configField(zcal, 'slmInterceptUm', 0));

% --- where each mark lands, laterally and in depth ---------------------
n = numel(ledger);
xy    = zeros(n, 2);
depth = zeros(n, 1);
coords = vertcat(ledger.dmdCoords);
centre = mean(coords, 1);
for m = 1:n
    p = A * [coords(m, 1); coords(m, 2); 1];
    xy(m, :) = p(1:2)';
    % Position along the dispersion diagonal, in sample um. The 45 degree
    % clocking is why this is (dc + dr)/sqrt(2) and not simply dc.
    dc = coords(m, 1) - centre(1);
    dr = coords(m, 2) - centre(2);
    xDispUm = (dc + dr) / sqrt(2) * umPerPxDisp;
    depth(m) = slope * ledger(m).dzCmdUm + intercept + gradient * xDispUm;
end

% --- size the frame to hold the marks IN SCAN-FIELD COORDINATES --------
% Deliberately NOT re-centred. locateMarksInStack looks for each mark at
% dmdToScan_affine * [col;row;1] with no offset, so the rendered frame has
% to be in that same coordinate system with its origin at pixel 1. Shifting
% the marks to fit a tighter frame would make the simulation internally
% consistent and unrelated to what the locator does — the exact failure this
% file exists to avoid.
pad   = max(6 * markR, 40);
nCols = max(64, ceil(max(xy(:, 1)) + pad));
nRows = max(64, ceil(max(xy(:, 2)) + pad));
% A mark whose predicted position falls outside the frame is simply NOT
% RENDERED — which is the truth of the bench: the imaging field does not
% cover the whole DMD field, and a mark grid wider than the raster leaves
% its outer marks unimaged. Silently shrinking the grid to fit would hide a
% real geometry problem the operator needs to see as a failed verification.
inField = xy(:, 1) >= 1 & xy(:, 2) >= 1 & ...
          xy(:, 1) <= nCols & xy(:, 2) <= nRows;

% --- render -------------------------------------------------------------
stream = RandStream('twister', 'Seed', seed);
[X, Y] = meshgrid(1:nCols, 1:nRows);
stack  = zeros(nRows, nCols, nPlanes * nVolumes);

% Plane spacing sets how sharply a mark fades out of its neighbours. Using
% the real spacing keeps "darkest plane" a genuine argmax rather than a
% one-hot lookup.
if numel(planeZ) > 1
    planeSigma = max(abs(mean(diff(planeZ))), eps);
else
    planeSigma = 20;
end

for v = 1:nVolumes
    for p = 1:nPlanes
        img = bg * ones(nRows, nCols);
        for m = find(inField(:))'
            % How strongly this mark shows in this plane: a Gaussian in the
            % distance between where it burned and where the plane images.
            w = exp(-((depth(m) - planeZ(min(p, numel(planeZ))))^2) / ...
                    (2 * planeSigma^2));
            r2 = (X - xy(m, 1)).^2 + (Y - xy(m, 2)).^2;
            disc = exp(-r2 / (2 * markR^2));
            img = img - 0.8 * bg * w * disc;      % marks are DARK
        end
        img = img .* (1 + noise * stream.randn(nRows, nCols));
        stack(:, :, (v - 1) * nPlanes + p) = max(img, 0);
    end
end
end

% ===========================================================================

function h = handoff()
try
    h = tfp.util.readHandoffConstants();
catch
    h = struct();
end
end

function v = getfielddef(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
