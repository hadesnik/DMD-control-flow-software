function patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration, spotOptions)
%ppsfPattern Stack of masks for PPSF — one spot at each offset from centerTarget.
%
%   patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration)
%   patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration, spotOptions)
%
%   The offsets are the DISTANCE AXIS of the lateral-PPSF figure, so getting
%   the um -> pixel conversion wrong corrupts the headline result directly.
%   Until T-BU-2b this function multiplied both the row and the column offset
%   by a single scalar `calibration.pixelsPerUm`. That was wrong three ways:
%     * wrong magnitude   — the scalar was derived from a pre-optics guess of
%                           0.270 um/px; the real sample scale is ~4x larger;
%     * wrong anisotropy  — the two optical axes differ by 1.2588x, so a fixed
%                           scalar mis-places a sweep by up to 26% depending on
%                           which way it points;
%     * wrong axes        — the chip is clocked 45 deg, so the optical axes are
%                           the chip DIAGONALS, not its rows and columns.
%   Conversion now goes through tfp.patterns.sampleToDmdOffset (handoff §5),
%   which is the single implementation of that map.
%
%   Inputs:
%     dmd          - object/struct with .nRows and .nCols.
%     centerTarget - 1x2 numeric [col row] in DMD pixel coords.
%     offsetsUm    - N x 2 numeric SAMPLE-PLANE offsets in um. Column 1 is the
%                    grating's DISPERSION axis, column 2 the GROOVE axis —
%                    the same [x_disp y_groove] ordering as
%                    tfp.patterns.sampleToDmdOffset. (Which physical direction
%                    each corresponds to at the sample is a bench question;
%                    %VERIFY per TASKS.md T-BU-M4.)
%     radiusPx     - scalar positive spot radius in DMD pixels. In the default
%                    isotropic mode this is the circle radius; when spotOptions
%                    requests anisotropic mode it is the GROOVE-axis (long)
%                    semi-axis, and an explicit spotOptions.semiAxisGroovePx
%                    overrides it. Prefer sizing this with
%                    tfp.patterns.somaSpotGeometry rather than by hand.
%     calibration  - struct (or [] for the design constants) describing how to
%                    turn sample um into DMD pixels. Recognised fields, in
%                    order of precedence:
%                      .dmdToSampleLinear - 2x2 or 3x3 linear part of a FITTED
%                                           DMD px -> sample um affine. Wins
%                                           over everything else (handoff §9:
%                                           a measured fit always beats design
%                                           intent).
%                      .model             - an optical-model struct from
%                                           tfp.util.opticalModel, or any
%                                           config struct it accepts.
%                      .dmdPixelsPerUm    - scalar ISOTROPIC DMD px per um.
%                                           An explicit escape hatch for test
%                                           math and for simulated rigs where
%                                           the scale really is isotropic; it
%                                           is NOT correct for this rig.
%                      (none of the above) - the design constants from
%                                           tfp.util.opticalModel().
%     spotOptions  - optional struct forwarded to tfp.patterns.singleSpot, e.g.
%                    tfp.patterns.somaSpotGeometry(...).spotOptions to draw a
%                    spot that is ROUND at the sample.
%
%   Output:
%     patterns     - logical(nRows, nCols, N). Slice k has one spot at
%                    centerTarget + sampleToDmdOffset(offsetsUm(k,:), ...).
%
%   Deprecated / rejected calibration fields:
%     .pixelsPerUm       - DEPRECATED and ambiguous: it means CAMERA px per um
%                          when it comes from tfp.calibration.alignDMDtoCamera
%                          but was read here as DMD px per um, a ~5.8x error.
%                          Still honoured (as DMD px per um, the historical
%                          reading) with a
%                          tfp:patterns:ppsfPattern:deprecatedPixelsPerUm
%                          warning. Rename it to .dmdPixelsPerUm (or supply a
%                          .model) to silence it.
%     .cameraPixelsPerUm - a CAMERA-plane scale. Supplying only this is a hard
%                          error (:cameraCalibration): a camera scale cannot
%                          place a DMD target, and silently using it would
%                          scale every offset by ~5.8x.
%
%   Errors: tfp:patterns:ppsfPattern:<reason>
%
%   See also tfp.patterns.sampleToDmdOffset, tfp.patterns.somaSpotGeometry,
%            tfp.patterns.singleSpot, tfp.util.opticalModel.

if nargin < 6
    spotOptions = struct();
end
if nargin < 5
    calibration = [];
end

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:ppsfPattern:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(centerTarget) || numel(centerTarget) ~= 2
    error('tfp:patterns:ppsfPattern:badCenter', ...
        'centerTarget must be 1x2 numeric [col row].');
end

if ~isnumeric(offsetsUm) || ndims(offsetsUm) > 2 || size(offsetsUm, 2) ~= 2
    error('tfp:patterns:ppsfPattern:badOffsets', ...
        'offsetsUm must be N x 2 numeric [dx_um dy_um]; got size [%s].', ...
        num2str(size(offsetsUm)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:ppsfPattern:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

% um -> DMD px for the whole sweep at once. This is the line the task exists
% to fix; everything anisotropic/45-degree lives inside sampleToDmdOffset.
offsetsPx = resolveOffsetsPx(offsetsUm, calibration);

nOffsets = size(offsetsUm, 1);
patterns = false(nRows, nCols, nOffsets);

for k = 1:nOffsets
    target = double(centerTarget(:)') + offsetsPx(k, :);
    patterns(:, :, k) = tfp.patterns.singleSpot(dmd, target, radiusPx, spotOptions);
end
end

% =========================================================================

function offsetsPx = resolveOffsetsPx(offsetsUm, calibration)
%resolveOffsetsPx Convert sample-um offsets to DMD [dCol dRow] pixel offsets.
%   Precedence is documented in the header. The isotropic branches exist only
%   for backward compatibility and for deliberately isotropic test rigs.

if isempty(calibration)
    offsetsPx = tfp.patterns.sampleToDmdOffset(offsetsUm, []);
    return;
end

if ~isstruct(calibration) || ~isscalar(calibration)
    error('tfp:patterns:ppsfPattern:badCalibration', ...
        ['calibration must be a scalar struct or [] (see the header for the ' ...
         'recognised fields); got %s of size [%s].'], ...
        class(calibration), num2str(size(calibration)));
end

% 1. A fitted, um-valued DMD->sample map always wins (handoff §9).
if hasValue(calibration, 'dmdToSampleLinear')
    offsetsPx = tfp.patterns.sampleToDmdOffset(offsetsUm, ...
        calibration.dmdToSampleLinear);
    return;
end

% 2. An explicit optical model (or any config struct opticalModel accepts).
if hasValue(calibration, 'model')
    model = calibration.model;
    if ~isstruct(model) || ~isscalar(model)
        error('tfp:patterns:ppsfPattern:badCalibration', ...
            ['calibration.model must be a scalar struct from ' ...
             'tfp.util.opticalModel (or a config struct it accepts); got %s.'], ...
            class(model));
    end
    offsetsPx = tfp.patterns.sampleToDmdOffset(offsetsUm, model);
    return;
end

% 3. Explicit isotropic override. Correct only where the rig really is
%    isotropic (mock/simulated) — never on the clocked, dispersing bench path.
if hasValue(calibration, 'dmdPixelsPerUm')
    offsetsPx = isotropicOffsets(offsetsUm, calibration.dmdPixelsPerUm, ...
        'dmdPixelsPerUm');
    return;
end

% 4. A camera-plane scale cannot place a DMD target. Catching this is the
%    whole point of splitting the old ambiguous `pixelsPerUm` in two.
if hasValue(calibration, 'cameraPixelsPerUm')
    error('tfp:patterns:ppsfPattern:cameraCalibration', ...
        ['calibration carries .cameraPixelsPerUm (%g CAMERA px per um, from ' ...
         'tfp.calibration.alignDMDtoCamera) but no DMD-valued map. A camera ' ...
         'scale cannot place a DMD target — using it would scale every PPSF ' ...
         'offset by roughly the camera-px/DMD-px ratio (~5.8x on this rig). ' ...
         'Supply calibration.dmdToSampleLinear (a um-valued DMD->sample fit) ' ...
         'or calibration.model instead.'], ...
        double(calibration.cameraPixelsPerUm(1)));
end

% 5. Legacy ambiguous key. Honour the historical reading so old rig configs
%    keep running, but say loudly that it is ambiguous.
if hasValue(calibration, 'pixelsPerUm')
    warning('tfp:patterns:ppsfPattern:deprecatedPixelsPerUm', ...
        ['calibration.pixelsPerUm is DEPRECATED and ambiguous: ' ...
         'tfp.calibration.alignDMDtoCamera writes it as CAMERA px per um, ' ...
         'while ppsfPattern historically read it as DMD px per um. It is ' ...
         'being read as an ISOTROPIC DMD px per um (%g), which also ignores ' ...
         'the chip''s 45 deg clocking and its 1.2588x anisotropy. Rename it ' ...
         'to .dmdPixelsPerUm if that is what you meant, or supply ' ...
         '.model / .dmdToSampleLinear for the correct anisotropic map.'], ...
        double(calibration.pixelsPerUm(1)));
    offsetsPx = isotropicOffsets(offsetsUm, calibration.pixelsPerUm, 'pixelsPerUm');
    return;
end

% 6. Nothing stated — design constants.
offsetsPx = tfp.patterns.sampleToDmdOffset(offsetsUm, []);
end

function offsetsPx = isotropicOffsets(offsetsUm, scale, fieldName)
%isotropicOffsets The old scalar path, kept only for the branches above.
if ~isnumeric(scale) || ~isscalar(scale) || ~isfinite(scale) || scale <= 0
    error('tfp:patterns:ppsfPattern:badCalibration', ...
        'calibration.%s must be a positive finite scalar.', fieldName);
end
offsetsPx = double(offsetsUm) * double(scale);
end

function tf = hasValue(s, name)
%hasValue The repo's configField convention, reduced to a presence test.
tf = isstruct(s) && isfield(s, name) && ~isempty(s.(name));
end
