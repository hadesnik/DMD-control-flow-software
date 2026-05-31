function [patterns, pinfo] = makeTimingPatterns(dmd, cfg)
%makeTimingPatterns Build the 2-pattern logical stack for DMD switching-timing measurements.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure.
%
%   In the ping-pong timing measurement, the DMD alternates between two
%   spatial patterns while an avalanche photodiode (APD) behind a pinhole
%   records the optical transient.  Pattern A places a bright spot ON the
%   pinhole (high APD signal); pattern B either steers light to a far-off
%   spot or blanks all mirrors so the pinhole goes dark (low signal).  The
%   rise and fall of the APD voltage directly capture the DMD optical
%   switching time.
%
%   [patterns, pinfo] = makeTimingPatterns(dmd, cfg)
%
%   Inputs
%   ------
%   dmd : tfp.hardware.DMD subclass, or a plain struct
%       Must expose scalar integer fields .nRows and .nCols giving the DMD
%       panel dimensions.  No hardware calls are made; only geometry fields
%       are read.  Pass a struct, e.g. struct('nRows',800,'nCols',1280),
%       when hardware is not available.
%
%   cfg : struct
%       Timing-experiment configuration struct.  Relevant sub-fields:
%
%         cfg.pattern.onCoords  [col row]  (1×2 double)
%             DMD pixel coordinate of the spot that falls on the APD
%             pinhole.  1-indexed, origin top-left.
%
%         cfg.pattern.offCoords [col row]  (1×2 double)
%             DMD pixel coordinate used for the "off" spot when
%             offMode == 'spot'.  Ignored (and set to [] in pinfo) when
%             offMode == 'alloff'.
%
%         cfg.pattern.offMode   char | string
%             'spot'   — Pattern B is a spot at offCoords (same radius as
%                        pattern A).  Use this when you want to keep the
%                        mirror array in an active state during the "off"
%                        dwell and only characterise the switching transient
%                        at the pinhole.
%             'alloff' — Pattern B sets ALL mirrors to their OFF state
%                        (false everywhere), giving maximum contrast at the
%                        pinhole.  Preferred when APD dark-state SNR matters
%                        more than mirror-state consistency.
%
%         cfg.pattern.radiusPx  scalar double > 0
%             Radius of every spot (both on and off) in DMD pixels.
%
%         cfg.pattern.illuminatedRegion  [c0 c1 r0 r1] | []   (optional)
%             Bounding box (DMD px) of the laser-illuminated footprint — the
%             pi-Shaper flat-top.  When non-empty, every spot's disc is checked
%             against this box and a warning is issued for any spot that
%             extends outside it (a soft check, not an error — the patterns are
%             still built).  [] (the default, or an absent field) skips the
%             check.  Mirrors the illuminatedRegion hint used by the
%             exp_ensemble_* experiments.  For the pi-Shaper 6 mm flat-top on a
%             1280x800 DLP650LNIR (10.8 um pitch) the box is [362 918 122 678].
%
%   Outputs
%   -------
%   patterns : logical(nRows, nCols, 2)
%       3-D logical array.
%         patterns(:,:,1) = pattern A — spot at onCoords.
%         patterns(:,:,2) = pattern B — spot at offCoords (offMode 'spot')
%                           or all-false (offMode 'alloff').
%       Suitable for direct use with tfp.hardware.DMD.loadPatternSequence.
%
%   pinfo : struct
%       Provenance / diagnostic information:
%         .onCoords    [col row] actually used for pattern A (1×2 double).
%         .offCoords   [col row] actually used for pattern B, or [] for
%                       alloff mode (1×2 double or []).
%         .offMode     char — the validated offMode string.
%         .radiusPx    scalar double — radius used for both spots.
%         .activePixels [nnz(A)  nnz(B)]  (1×2 double) — number of ON
%                       mirror pixels in each pattern.  Useful for verifying
%                       illumination symmetry or computing duty-cycle power.
%         .nRows       scalar double — panel row count (from dmd).
%         .nCols       scalar double — panel column count (from dmd).
%         .illuminatedRegion  [c0 c1 r0 r1] or [] — the lit-footprint box that
%                       was checked against (echoes cfg.pattern.illuminatedRegion).
%
%   Errors (error identifier format: tfp:timing:makeTimingPatterns:<reason>)
%   ------
%   tfp:timing:makeTimingPatterns:badDmd
%       dmd does not expose valid .nRows / .nCols fields.
%   tfp:timing:makeTimingPatterns:badOffMode
%       cfg.pattern.offMode is not 'spot' or 'alloff'.
%   tfp:timing:makeTimingPatterns:coordOutOfRange
%       A spot centre coordinate is completely outside the panel array.
%       (Partial clip — centre inside array, but some disk pixels fall
%       outside — issues a warning with the same id and continues.)
%   tfp:timing:makeTimingPatterns:badIlluminatedRegion
%       cfg.pattern.illuminatedRegion is non-empty but is not a 4-element
%       finite [c0 c1 r0 r1] vector with c0<=c1 and r0<=r1.
%
%   Warnings
%   --------
%   tfp:timing:makeTimingPatterns:coordOutOfRange
%       Spot disc extends beyond the panel edge and will be clipped.
%       The measurement is still valid but spot area (activePixels) will be
%       smaller than pi*radiusPx^2.
%   tfp:timing:makeTimingPatterns:spotOutsideIllumination
%       cfg.pattern.illuminatedRegion is set and a spot disc extends outside
%       the lit footprint, so that spot will be dim/dark on real hardware.
%
%   Example
%   -------
%   % Use a plain struct when running without hardware:
%   dmd = struct('nRows', 800, 'nCols', 1280);
%   cfg.pattern.onCoords  = [640, 400];   % centre of panel
%   cfg.pattern.offCoords = [100, 100];   % corner, far from pinhole
%   cfg.pattern.offMode   = 'spot';
%   cfg.pattern.radiusPx  = 10;
%   [patterns, pinfo] = makeTimingPatterns(dmd, cfg);
%   % Confirm 2-pattern stack:
%   assert(isequal(size(patterns), [800 1280 2]));
%
%   See also tfp.patterns.singleSpot, tfp.hardware.DMD

% -------------------------------------------------------------------------
% 1.  Read panel geometry from dmd
% -------------------------------------------------------------------------
try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:timing:makeTimingPatterns:badDmd', ...
        ['dmd must expose scalar integer fields .nRows and .nCols. ' ...
         'Failed with: %s'], ME.message);
end

if ~isnumeric(nRows) || ~isscalar(nRows) || nRows < 1 || ...
   ~isnumeric(nCols) || ~isscalar(nCols) || nCols < 1
    error('tfp:timing:makeTimingPatterns:badDmd', ...
        'dmd.nRows and dmd.nCols must be positive scalars; got nRows=%s, nCols=%s.', ...
        mat2str(nRows), mat2str(nCols));
end

nRows = double(nRows);
nCols = double(nCols);

% -------------------------------------------------------------------------
% 2.  Unpack and validate cfg
% -------------------------------------------------------------------------
onCoords  = cfg.pattern.onCoords;
offCoords = cfg.pattern.offCoords;
offMode   = cfg.pattern.offMode;
radiusPx  = cfg.pattern.radiusPx;

% Optional illuminated-footprint box; absent field or [] => no check.
if isfield(cfg.pattern, 'illuminatedRegion')
    illuminatedRegion = cfg.pattern.illuminatedRegion;
else
    illuminatedRegion = [];
end

% Normalise offMode to char so strcmp works regardless of string/char input
if isstring(offMode)
    offMode = char(offMode);
end

if ~ismember(offMode, {'spot', 'alloff'})
    error('tfp:timing:makeTimingPatterns:badOffMode', ...
        'cfg.pattern.offMode must be ''spot'' or ''alloff''; got ''%s''.', offMode);
end

% -------------------------------------------------------------------------
% 3.  Validate coordinates
% -------------------------------------------------------------------------
validateCoord(onCoords,  'onCoords',  nRows, nCols, radiusPx);

if strcmp(offMode, 'spot')
    validateCoord(offCoords, 'offCoords', nRows, nCols, radiusPx);
end

% Optional soft check against the illuminated footprint (pi-Shaper flat-top).
if ~isempty(illuminatedRegion)
    illuminatedRegion = validateIlluminatedRegion(illuminatedRegion);
    checkSpotInsideRegion(onCoords,  'onCoords',  radiusPx, illuminatedRegion);
    if strcmp(offMode, 'spot')
        checkSpotInsideRegion(offCoords, 'offCoords', radiusPx, illuminatedRegion);
    end
end

% -------------------------------------------------------------------------
% 4.  Build pattern A  (spot ON the pinhole)
% -------------------------------------------------------------------------
patA = tfp.patterns.singleSpot(dmd, onCoords, radiusPx);

% -------------------------------------------------------------------------
% 5.  Build pattern B  (dark / far-off)
% -------------------------------------------------------------------------
if strcmp(offMode, 'alloff')
    patB       = false(nRows, nCols);
    offCoordsOut = [];
else
    patB         = tfp.patterns.singleSpot(dmd, offCoords, radiusPx);
    offCoordsOut = offCoords(:)';          % ensure 1×2
end

% -------------------------------------------------------------------------
% 6.  Assemble the 3-D logical stack
% -------------------------------------------------------------------------
patterns = false(nRows, nCols, 2);
patterns(:,:,1) = patA;
patterns(:,:,2) = patB;

% Guarantee logical (singleSpot should already return logical, but be safe)
patterns = logical(patterns);

% Sanity-check output shape (defensive, should never fire)
assert(isequal(size(patterns), [nRows nCols 2]), ...
    'tfp:timing:makeTimingPatterns:internalShapeMismatch', ...
    'Internal error: unexpected output shape %s.', mat2str(size(patterns)));

% -------------------------------------------------------------------------
% 7.  Build pinfo
% -------------------------------------------------------------------------
pinfo.onCoords    = onCoords(:)';           % 1×2
pinfo.offCoords   = offCoordsOut;
pinfo.offMode     = offMode;
pinfo.radiusPx    = radiusPx;
pinfo.activePixels = [nnz(patA)  nnz(patB)];
pinfo.nRows       = nRows;
pinfo.nCols       = nCols;
if isempty(illuminatedRegion)
    pinfo.illuminatedRegion = [];
else
    pinfo.illuminatedRegion = illuminatedRegion(:)';   % 1×4 [c0 c1 r0 r1]
end

end % makeTimingPatterns


% =========================================================================
% Local helper — coordinate range validation
% =========================================================================
function validateCoord(coords, coordName, nRows, nCols, radiusPx)
%validateCoord Check that coords is a valid 1×2 [col row] within the panel.
%
%   Errors if the centre is completely outside [1..nCols] × [1..nRows].
%   Warns (same id) if the spot disc clips the panel boundary.

if ~isnumeric(coords) || numel(coords) ~= 2
    error('tfp:timing:makeTimingPatterns:coordOutOfRange', ...
        'cfg.pattern.%s must be a 1×2 numeric [col row]; got size [%s].', ...
        coordName, num2str(size(coords)));
end

col = coords(1);
row = coords(2);

% Hard error: centre completely outside the panel
if col < 1 || col > nCols || row < 1 || row > nRows
    error('tfp:timing:makeTimingPatterns:coordOutOfRange', ...
        ['cfg.pattern.%s centre [col=%g row=%g] is completely outside ' ...
         'the DMD panel ([1..%d] × [1..%d]). ' ...
         'Correct the coordinate or swap onCoords/offCoords.'], ...
        coordName, col, row, nCols, nRows);
end

% Soft warning: spot disc clips the boundary (centre is inside, disc extends out)
if (col - radiusPx) < 1 || (col + radiusPx) > nCols || ...
   (row - radiusPx) < 1 || (row + radiusPx) > nRows
    warning('tfp:timing:makeTimingPatterns:coordOutOfRange', ...
        ['cfg.pattern.%s spot (centre [col=%g row=%g], radius=%g px) ' ...
         'extends beyond the DMD panel edge and will be clipped. ' ...
         'pinfo.activePixels will reflect the clipped area.'], ...
        coordName, col, row, radiusPx);
end

end % validateCoord


% =========================================================================
% Local helper — illuminated-region validation
% =========================================================================
function region = validateIlluminatedRegion(region)
%validateIlluminatedRegion Check a [c0 c1 r0 r1] lit-footprint box.
%   Errors tfp:timing:makeTimingPatterns:badIlluminatedRegion if the input is
%   not a 4-element finite vector with c0<=c1 and r0<=r1. Returns it as a row.

if ~isnumeric(region) || numel(region) ~= 4 || ~all(isfinite(region(:)))
    error('tfp:timing:makeTimingPatterns:badIlluminatedRegion', ...
        ['cfg.pattern.illuminatedRegion must be a 4-element finite ' ...
         '[c0 c1 r0 r1] vector or []; got %s.'], mat2str(region));
end
region = double(region(:)');
if region(1) > region(2) || region(3) > region(4)
    error('tfp:timing:makeTimingPatterns:badIlluminatedRegion', ...
        ['cfg.pattern.illuminatedRegion must satisfy c0<=c1 and r0<=r1; ' ...
         'got [%g %g %g %g].'], region(1), region(2), region(3), region(4));
end

end % validateIlluminatedRegion


% =========================================================================
% Local helper — soft check that a spot disc fits inside the lit footprint
% =========================================================================
function checkSpotInsideRegion(coords, coordName, radiusPx, region)
%checkSpotInsideRegion Warn if a spot disc extends outside the lit footprint.
%   Soft check only (no error): mirrors the exp_ensemble_* illuminatedRegion
%   hint. Warns tfp:timing:makeTimingPatterns:spotOutsideIllumination.

col = coords(1);
row = coords(2);
c0 = region(1); c1 = region(2);
r0 = region(3); r1 = region(4);

if (col - radiusPx) < c0 || (col + radiusPx) > c1 || ...
   (row - radiusPx) < r0 || (row + radiusPx) > r1
    warning('tfp:timing:makeTimingPatterns:spotOutsideIllumination', ...
        ['cfg.pattern.%s spot (centre [col=%g row=%g], radius=%g px) ' ...
         'extends outside the illuminated footprint [c0=%g c1=%g r0=%g r1=%g]; ' ...
         'that spot will be dim/dark on real hardware. Move it inside the lit ' ...
         'region or clear cfg.pattern.illuminatedRegion to silence this check.'], ...
        coordName, col, row, radiusPx, c0, c1, r0, r1);
end

end % checkSpotInsideRegion
