function model = opticalModel(config)
%opticalModel Design constants for the bring-up temporal-focusing optical path.
%
%   model = tfp.util.opticalModel(config)
%   model = tfp.util.opticalModel()          % all defaults
%
%   This is the SINGLE place the bring-up optical constants appear in code.
%   Nothing else in the codebase should hardcode 1.1250, 1.4162, 45, 278 or 68 —
%   read them from here so that one config edit propagates everywhere.
%
%   Source: docs/dmd_control_handoff.md, generated from the TF optics simulator
%   for build `33010FL01-530R 6.0mm 80/300 150/80`:
%     CARBIDE 1030 nm -> DMD -> 4f (80/300) -> 1200 g/mm grating -> 4f (150/80)
%     -> periscope / PBS / Olympus 180 mm tube / Nikon CFI75 LWD 16x/0.8 W.
%   No PLM, no piShaper.
%
%   EVERY VALUE HERE IS DESIGN INTENT, NOT CALIBRATION. Per §9 of the handoff,
%   the control code fits its own affine from a measured grid and uses these
%   only as an expected starting point and a sanity check. If a fitted scale
%   disagrees with umPerPixelGroove / umPerPixelDispersion by more than a few
%   percent, something is installed differently from the document. The single
%   largest risk is the periscope, whose 200/150 lens order is unconfirmed:
%   reversing it scales every um/px figure by periscopeReversalFactor (1.778).
%
%   Input:
%     config - struct. Either a full loaded config (with .dmd and/or .laser
%              sub-structs) or a bare struct of the fields below. Missing
%              fields take the documented defaults. Pass [] or omit for
%              all-defaults.
%
%   Output struct `model`:
%     Geometry
%       .clockingDeg           Chip clocking about its own normal (45). The
%                              optical axes are the chip DIAGONALS.
%       .umPerPixelGroove      Sample um per DMD px along the grooves (1.1250).
%       .umPerPixelDispersion  Sample um per DMD px along dispersion (1.4162).
%       .anisotropy            dispersion/groove (1.2588). A circle drawn in DMD
%                              pixels lands as an ellipse this much longer along
%                              the dispersion axis.
%       .dispersionAxisSign    +/-1, %VERIFY — which chip diagonal is +dispersion.
%       .pitchUm               DMD mirror pitch (10.8).
%       .fieldExtentUm         [groove dispersion] addressable ellipse at the
%                              sample ([625 787]).
%     Patch
%       .patchCenterPx         [col row] ILLUMINATION centroid, not necessarily
%                              the chip centre. %VERIFY on the rig.
%       .patchRadiusPx         Design patch radius (278 px = 6.0 mm diameter).
%       .patchMaxRadiusPx      Hard limit (329 px = 7.12 mm); beyond this the
%                              beam clips lens La and the grating ruling.
%       .gaussianWaistPx       w in I(r)/I0 = exp(-2*r^2/w^2)   (555.6).
%     Depth
%       .depthGradientUmPerUm  z_um ~= x_disp * this (0.02174), dispersion axis
%                              only — the design has no groove-axis component.
%       .depthGradientSign     +/-1, %VERIFY.
%       .focalPlaneTiltDeg     Surface tilt (1.245).
%       .axialFwhmUm           Axial FWHM (17.7) [LOW +/-40%].
%     Timing
%       .binaryFrameRateHz     12500.
%       .frameDurationS        1/binaryFrameRateHz (80 us).
%     Laser (for the pupil interlock; see tfp.util.assertPulseEnergySafe)
%       .repRateHz                    (1e5)
%       .maxPowerW                    (40 — the handoff's §7 "80 W" is an error)
%       .maxPulseEnergyUjPupil        (68) air-ionisation limit at the pupil.
%                                     A property of the OPTICS, so the 80->40 W
%                                     correction does not change it.
%       .pupilInterlockFillFraction   (0.2)
%       .maxDeliverablePulseEnergyUj  derived: 1e6*maxPowerW/repRateHz (400 uJ).
%     Derived helpers
%       .umPerPixel                   geometric mean of the two axis scales.
%                                     A convenience for order-of-magnitude use
%                                     ONLY — never for placing a target.
%       .periscopeReversalFactor      1.778 (see above).
%
%   Errors: tfp:util:opticalModel:<reason>
%
%   See also tfp.patterns.sampleToDmdOffset, tfp.util.assertPatternInPatch,
%            tfp.util.assertPulseEnergySafe, tfp.patterns.somaSpotGeometry.

if nargin < 1 || isempty(config)
    config = struct();
end
if ~isstruct(config)
    error('tfp:util:opticalModel:badConfig', ...
        'config must be a struct or empty; got %s.', class(config));
end

% Accept either a full loaded config or a bare struct of the fields themselves,
% so callers holding only a sub-struct do not have to re-wrap it.
dmdCfg   = subStruct(config, 'dmd');
laserCfg = subStruct(config, 'laser');

% --- Geometry ------------------------------------------------------------
model.clockingDeg          = configField(dmdCfg, 'clockingDeg',          45);
model.umPerPixelGroove     = configField(dmdCfg, 'umPerPixelGroove',     1.1250);
model.umPerPixelDispersion = configField(dmdCfg, 'umPerPixelDispersion', 1.4162);
model.dispersionAxisSign   = configField(dmdCfg, 'dispersionAxisSign',   1);
model.pitchUm              = configField(dmdCfg, 'pitchUm',              10.8);
model.fieldExtentUm        = configField(dmdCfg, 'fieldExtentUm',        [625 787]);

% --- Patch ---------------------------------------------------------------
model.patchCenterPx    = configField(dmdCfg, 'patchCenterPx',    [640 400]);
% roiHalfWidthPx is the legacy alias; honour it when patchRadiusPx is absent so
% existing rig configs keep working.
model.patchRadiusPx    = configField(dmdCfg, 'patchRadiusPx', ...
                             configField(dmdCfg, 'roiHalfWidthPx', 278));
model.patchMaxRadiusPx = configField(dmdCfg, 'patchMaxRadiusPx', 329);
model.gaussianWaistPx  = configField(dmdCfg, 'gaussianWaistPx',  555.6);

% --- Depth ---------------------------------------------------------------
model.depthGradientUmPerUm = configField(dmdCfg, 'depthGradientUmPerUm', 0.02174);
model.depthGradientSign    = configField(dmdCfg, 'depthGradientSign',    1);
model.focalPlaneTiltDeg    = configField(dmdCfg, 'focalPlaneTiltDeg',    1.245);
model.axialFwhmUm          = configField(dmdCfg, 'axialFwhmUm',          17.7);

% --- Timing --------------------------------------------------------------
model.binaryFrameRateHz = configField(dmdCfg, 'binaryFrameRateHz', 12500);

% --- Laser (pupil interlock) ---------------------------------------------
model.repRateHz                  = configField(laserCfg, 'rep_rate_hz',                   1e5);
model.maxPowerW                  = configField(laserCfg, 'max_power_w',                   40);
model.maxPulseEnergyUjPupil      = configField(laserCfg, 'max_pulse_energy_uj_pupil',     68);
model.pupilInterlockFillFraction = configField(laserCfg, 'pupil_interlock_fill_fraction', 0.2);

% --- Validate ------------------------------------------------------------
% Cheap checks that catch a mistyped config before it silently mis-places every
% target on the rig.
checkPositiveScalar(model.umPerPixelGroove,     'umPerPixelGroove');
checkPositiveScalar(model.umPerPixelDispersion, 'umPerPixelDispersion');
checkPositiveScalar(model.pitchUm,              'pitchUm');
checkPositiveScalar(model.patchRadiusPx,        'patchRadiusPx');
checkPositiveScalar(model.patchMaxRadiusPx,     'patchMaxRadiusPx');
checkPositiveScalar(model.gaussianWaistPx,      'gaussianWaistPx');
checkPositiveScalar(model.binaryFrameRateHz,    'binaryFrameRateHz');
checkPositiveScalar(model.repRateHz,            'repRateHz');
checkPositiveScalar(model.maxPowerW,            'maxPowerW');
checkPositiveScalar(model.maxPulseEnergyUjPupil,'maxPulseEnergyUjPupil');
checkSign(model.dispersionAxisSign, 'dispersionAxisSign');
checkSign(model.depthGradientSign,  'depthGradientSign');

if numel(model.patchCenterPx) ~= 2 || ~all(isfinite(model.patchCenterPx))
    error('tfp:util:opticalModel:badPatchCenter', ...
        'dmd.patchCenterPx must be a finite 1x2 [col row].');
end
model.patchCenterPx = double(model.patchCenterPx(:))';

if numel(model.fieldExtentUm) ~= 2 || any(~isfinite(model.fieldExtentUm)) ...
        || any(model.fieldExtentUm <= 0)
    error('tfp:util:opticalModel:badFieldExtent', ...
        'dmd.fieldExtentUm must be a finite positive 1x2 [groove dispersion].');
end
model.fieldExtentUm = double(model.fieldExtentUm(:))';

if model.patchRadiusPx > model.patchMaxRadiusPx
    error('tfp:util:opticalModel:patchExceedsMax', ...
        ['dmd.patchRadiusPx (%g) exceeds dmd.patchMaxRadiusPx (%g). Beyond the ' ...
         'max the beam clips lens La and the grating ruling — the design patch ' ...
         'cannot legitimately be larger than the hard limit.'], ...
        model.patchRadiusPx, model.patchMaxRadiusPx);
end

if model.pupilInterlockFillFraction < 0 || model.pupilInterlockFillFraction > 1
    error('tfp:util:opticalModel:badFillFraction', ...
        'laser.pupil_interlock_fill_fraction must be in [0, 1]; got %g.', ...
        model.pupilInterlockFillFraction);
end

% --- Derived -------------------------------------------------------------
model.anisotropy = model.umPerPixelDispersion / model.umPerPixelGroove;

% If the config states an anisotropy explicitly, it is redundant with the two
% axis scales — disagreement means someone edited one and forgot the other.
if isfield(dmdCfg, 'anisotropy')
    stated = double(dmdCfg.anisotropy);
    if abs(stated - model.anisotropy) > 1e-3 * max(1, abs(model.anisotropy))
        error('tfp:util:opticalModel:anisotropyMismatch', ...
            ['dmd.anisotropy (%g) disagrees with ' ...
             'umPerPixelDispersion/umPerPixelGroove (%g/%g = %g). These are ' ...
             'redundant; fix whichever is stale.'], ...
            stated, model.umPerPixelDispersion, model.umPerPixelGroove, ...
            model.anisotropy);
    end
end

model.frameDurationS = 1 / model.binaryFrameRateHz;

% Worst-case pulse energy the laser can deliver at the configured rep rate.
% 1e6 converts J -> uJ.
model.maxDeliverablePulseEnergyUj = 1e6 * model.maxPowerW / model.repRateHz;

% Order-of-magnitude convenience only. Placing a target with this instead of the
% two axis scales reintroduces exactly the bug TASK-BU exists to fix.
model.umPerPixel = sqrt(model.umPerPixelGroove * model.umPerPixelDispersion);

% (200/150 periscope installed in the reverse order) / (as documented).
model.periscopeReversalFactor = (200 / 150)^2;
end

% =========================================================================

function s = subStruct(config, name)
%subStruct Return config.(name) if present, else config itself.
%   Lets callers pass either a full loaded config or a bare field struct.
if isfield(config, name) && isstruct(config.(name))
    s = config.(name);
else
    s = config;
end
end

function checkPositiveScalar(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
    error('tfp:util:opticalModel:badValue', ...
        '%s must be a positive finite scalar.', name);
end
end

function checkSign(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~ismember(v, [-1 1])
    error('tfp:util:opticalModel:badSign', ...
        '%s must be +1 or -1 (it is an unresolved bench convention); got %s.', ...
        name, mat2str(v));
end
end

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
