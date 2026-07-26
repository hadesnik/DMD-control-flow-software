function geom = somaSpotGeometry(diameterUm, config)
%somaSpotGeometry DMD pixel geometry for a round spot of a stated SAMPLE size.
%
%   geom = tfp.patterns.somaSpotGeometry()                  % 12.7 um soma
%   geom = tfp.patterns.somaSpotGeometry(diameterUm)
%   geom = tfp.patterns.somaSpotGeometry(diameterUm, config)
%
%   ASK FOR MICRONS, NOT PIXELS. Every spot size in this repo should be
%   expressed as a sample-plane diameter and converted here, so that the next
%   optics change updates every call site at once. Picking a `radiusPx` by
%   hand is exactly how the repo ended up with `radiusPx = 15` — chosen
%   against the pre-optics 0.270 um/px guess, and a 34 x 42 um blob at the
%   real scale, i.e. three to four cells wide.
%
%   Why the answer is an ELLIPSE. Per docs/dmd_control_handoff.md §5 the chip
%   is clocked 45 deg, so the optical axes are the chip DIAGONALS, and the
%   sample scale differs along them: 1.1250 um per pixel along the grating
%   grooves versus 1.4162 um per pixel along the dispersion axis. A round
%   spot of radius R um at the sample therefore needs semi-axes
%
%       aGroove     = R / umPerPixelGroove       (px, along (1,-1)/sqrt(2))
%       aDispersion = R / umPerPixelDispersion   (px, along (1, 1)/sqrt(2))
%
%   so aGroove is the LONGER one (the groove axis is more finely sampled) and
%   the ellipse area is pi*R^2 / (umPerPixelGroove * umPerPixelDispersion)
%   = pi*R^2 / 1.5932 pixels. Drawing an isotropic pixel circle instead gives
%   a sample spot 1.2588x longer along the dispersion axis.
%
%   Reference sizes at the design constants:
%
%     Sample diameter | semi-axes (groove x disp, px) | ellipse pixels
%     ----------------+-------------------------------+---------------
%      10.0 um        |  4.4 x 3.5                    |  ~47
%      12.7 um (soma) |  5.6 x 4.5                    |  ~81
%      15.0 um        |  6.7 x 5.3                    |  ~111
%
%   A soma is therefore about 80 DMD pixels, not the ~900 the pilot assumed.
%   That number is also the per-neuron power resolution available to
%   tfp.patterns.fillFactorEnsemble: ~80 levels, 1.25% steps.
%
%   These are DESIGN constants, not calibration (see §9 of the handoff and
%   tfp.util.opticalModel). Once a rig affine has been fitted, prefer the
%   fitted scales; pass them in via `config`.
%
%   Inputs:
%     diameterUm - positive finite scalar, desired spot DIAMETER at the
%                  sample in um. Default 12.7 (soma-sized; see TASKS.md
%                  TASK-BU). Pass [] for the default.
%     config     - optional config struct forwarded to tfp.util.opticalModel
%                  (either a full loaded config or a bare dmd sub-struct).
%                  Omit for the documented design defaults.
%
%   Output struct `geom`:
%     Requested size
%       .diameterUm            as requested.
%       .radiusUm              diameterUm/2.
%     Anisotropic DMD geometry (what you actually want to draw)
%       .semiAxisGroovePx      R / umPerPixelGroove.
%       .semiAxisDispersionPx  R / umPerPixelDispersion.
%       .semiAxesPx            [groove dispersion], for convenience.
%       .offsetsPx             K x 2 [dCol dRow] integer offsets of the ON
%                              pixels relative to the spot centre — stamp
%                              these at a centroid to draw the ellipse
%                              without re-deriving the geometry.
%       .localMask             logical, the same ellipse rasterized in its own
%                              bounding box (centre at the middle pixel).
%     Isotropic fallback (for call sites that are still circle-only)
%       .radiusPx              AREA-MATCHED isotropic radius,
%                              R / sqrt(umPerPixelGroove*umPerPixelDispersion).
%                              Same pixel count (hence same power resolution
%                              and same delivered energy) as the ellipse, but
%                              the sample spot is 1.2588x elongated along the
%                              dispersion axis.
%       .isotropicExtentUm     [groove dispersion] sample-plane DIAMETERS you
%                              actually get from that circle — quote this when
%                              a caller cannot draw an ellipse yet.
%     Pixel budget / power quantization
%       .areaPx                analytic ellipse area, pi*aG*aD.
%       .nPixels               EXACT rasterized pixel count for a spot centred
%                              on a pixel. This is what the hardware gets;
%                              +/- a few pixels as the centroid moves within a
%                              pixel, so treat it as the nominal value.
%       .nPowerLevels          = .nPixels. Number of distinct non-zero ON
%                              counts, i.e. fill-factor power levels.
%       .powerStepPct          100 / .nPixels, the finest power step.
%       .minFillFractionStep   1 / .nPixels.
%     Optics constants used (echoed so callers need not re-read the model)
%       .umPerPixelGroove, .umPerPixelDispersion, .anisotropy, .clockingDeg
%       .model                 the full tfp.util.opticalModel struct.
%     Hand-off
%       .spotOptions           struct ready to pass to the anisotropic mode of
%                              tfp.patterns.singleSpot / multiSpot, carrying
%                              both the ellipse semi-axes and the isotropic
%                              .radiusPx fallback.
%       .description           one-line human-readable summary, for logs and
%                              figure titles.
%
%   Warnings:
%     tfp:patterns:somaSpotGeometry:belowRasterFloor  - a semi-axis is under
%       1 px, so the rasterized spot is a handful of mirrors and its true size
%       is set by the pixel grid, not by the request. Legitimate for
%       tfp.calibration.measurePSF, which deliberately wants a minimal spot.
%     tfp:patterns:somaSpotGeometry:largerThanPatch   - the spot alone exceeds
%       the illuminated patch radius; it cannot be written (see §4).
%
%   Errors: tfp:patterns:somaSpotGeometry:<reason>
%
%   See also tfp.util.opticalModel, tfp.patterns.fillFactorEnsemble,
%            tfp.patterns.singleSpot, tfp.patterns.multiSpot.

% Default soma diameter in um. Stated once here; TASKS.md TASK-BU calls this
% "soma-sized" and every downstream default should reference it rather than
% re-guessing a pixel radius.
SOMA_DIAMETER_UM = 12.7;   %ASSUMED nominal cortical soma; %VERIFY per prep.

if nargin < 1 || isempty(diameterUm)
    diameterUm = SOMA_DIAMETER_UM;
end
if nargin < 2
    config = struct();
end

if ~isnumeric(diameterUm) || ~isscalar(diameterUm) ...
        || ~isfinite(diameterUm) || diameterUm <= 0
    if isnumeric(diameterUm)
        got = mat2str(diameterUm);
    else
        got = sprintf('a %s of size [%s]', class(diameterUm), ...
            num2str(size(diameterUm)));
    end
    error('tfp:patterns:somaSpotGeometry:badDiameter', ...
        ['diameterUm must be a positive finite scalar SAMPLE-plane diameter ' ...
         'in um (e.g. %g for a soma); got %s.'], SOMA_DIAMETER_UM, got);
end
diameterUm = double(diameterUm);

% Single source of truth for the optical constants — never hardcode 1.1250 /
% 1.4162 / 45 here (TASK-BU T-BU-0).
model = tfp.util.opticalModel(config);

radiusUm = diameterUm / 2;

% --- Semi-axes -----------------------------------------------------------
% Divide the desired sample radius by the um-per-pixel of each optical axis.
% The groove axis is more finely sampled (1.1250 < 1.4162 um/px), so it needs
% MORE pixels to span the same micron distance and is the longer semi-axis.
aGroove = radiusUm / model.umPerPixelGroove;
aDisp   = radiusUm / model.umPerPixelDispersion;

geom.diameterUm           = diameterUm;
geom.radiusUm             = radiusUm;
geom.semiAxisGroovePx     = aGroove;
geom.semiAxisDispersionPx = aDisp;
geom.semiAxesPx           = [aGroove, aDisp];

% --- Rasterize -----------------------------------------------------------
% At soma size the ellipse is only ~11 px across, so the analytic area is a
% poor predictor of what the mirrors actually do: count the pixels instead.
% Centre on a pixel (offset 0,0) for a canonical, reproducible count.
halfBox = ceil(max(aGroove, aDisp)) + 1;
[dCol, dRow] = meshgrid(-halfBox:halfBox, -halfBox:halfBox);

% Rotate the pixel offsets into the optical axes (handoff §5). The chip is
% clocked 45 deg, so these are the chip diagonals.
dDisp   = (dCol + dRow) / sqrt(2);
dGroove = (dCol - dRow) / sqrt(2);

inEllipse = (dGroove / aGroove).^2 + (dDisp / aDisp).^2 <= 1;

geom.localMask = inEllipse;
geom.offsetsPx = [dCol(inEllipse), dRow(inEllipse)];

geom.areaPx  = pi * aGroove * aDisp;
geom.nPixels = nnz(inEllipse);

% --- Isotropic fallback --------------------------------------------------
% Area-matched, so a circle-only call site keeps the correct pixel budget
% (and therefore the correct power quantization and delivered energy) even
% though its sample spot is elongated by `anisotropy` along the dispersion
% axis.
geom.radiusPx = radiusUm / sqrt(model.umPerPixelGroove * model.umPerPixelDispersion);
geom.isotropicExtentUm = 2 * geom.radiusPx * ...
    [model.umPerPixelGroove, model.umPerPixelDispersion];

% --- Power quantization --------------------------------------------------
% Fill-factor power control turns ON n of the nPixels mirrors in the spot, so
% the spot's pixel count IS its power resolution.
geom.nPowerLevels        = geom.nPixels;
geom.powerStepPct        = 100 / max(1, geom.nPixels);
geom.minFillFractionStep = 1 / max(1, geom.nPixels);

% --- Echo the constants used ---------------------------------------------
geom.umPerPixelGroove     = model.umPerPixelGroove;
geom.umPerPixelDispersion = model.umPerPixelDispersion;
geom.anisotropy           = model.anisotropy;
geom.clockingDeg          = model.clockingDeg;
geom.model                = model;

% --- Hand-off struct for the pattern builders ----------------------------
geom.spotOptions = struct( ...
    'anisotropic',          true, ...
    'semiAxisGroovePx',     aGroove, ...
    'semiAxisDispersionPx', aDisp, ...
    'anisotropy',           model.anisotropy, ...
    'clockingDeg',          model.clockingDeg, ...
    'radiusPx',             geom.radiusPx);

geom.description = sprintf( ...
    ['%.3g um sample spot = %.2f x %.2f px (groove x dispersion) ' ...
     '= %d DMD pixels = %d power levels (%.2f%% steps)'], ...
    diameterUm, aGroove, aDisp, geom.nPixels, geom.nPowerLevels, ...
    geom.powerStepPct);

% --- Advisories ----------------------------------------------------------
if min(aGroove, aDisp) < 1
    warning('tfp:patterns:somaSpotGeometry:belowRasterFloor', ...
        ['Requested %.3g um spot has semi-axes %.2f x %.2f px — below the ' ...
         '1 px rasterization floor, so the delivered spot is %d mirror(s) ' ...
         'and its true size is set by the pixel grid (~%.2f x %.2f um), not ' ...
         'by the request. Fine for a deliberately minimal PSF spot; ' ...
         'otherwise ask for a larger diameter.'], ...
        diameterUm, aGroove, aDisp, geom.nPixels, ...
        model.umPerPixelGroove, model.umPerPixelDispersion);
end

if max(aGroove, aDisp) > model.patchRadiusPx
    warning('tfp:patterns:somaSpotGeometry:largerThanPatch', ...
        ['Requested %.3g um spot needs a %.1f px semi-axis but the ' ...
         'illuminated patch radius is only %g px (handoff §4). The spot ' ...
         'cannot be written even at the patch centre — mirrors outside the ' ...
         'patch must stay OFF.'], ...
        diameterUm, max(aGroove, aDisp), model.patchRadiusPx);
end
end
