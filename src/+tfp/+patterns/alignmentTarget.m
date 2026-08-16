function mask = alignmentTarget(dmd, options)
%alignmentTarget Downstream-alignment target confined to the design patch.
%
%   mask = tfp.patterns.alignmentTarget(dmd)
%   mask = tfp.patterns.alignmentTarget(dmd, options)
%
%   The alignment pattern for everything downstream of the DMD, built from
%   the rays the aperture budget actually promised to pass — and nothing
%   beyond them:
%
%     * a RING at the design-patch edge (Ø patch_diameter_px, handoff §5;
%       463 px = Ø5.0 mm on the merged arm). The ring's rays ARE the
%       extreme-field bundle of the aperture budget, so "the ring clears
%       every aperture cleanly" is the acceptance test for the whole train.
%     * a centre CROSS (chip row/col axes) for centring on each optic,
%       at the grating footprint, and at I0.
%     * TICKS on the two chip diagonals just inside the ring — the
%       DISPERSION diagonal (+col,+row; see tfp.optics.dmdToDispersionUm)
%       gets LONG ticks and the groove diagonal SHORT ticks, so the
%       anamorphic stretch and the tilt work can be oriented on a card at
%       a glance.
%
%   Everything lives inside the patch disc. Full-chip patterns (e.g. the
%   alpCheckerboard smoke test) are wrong for downstream alignment: mirrors
%   between the patch edge and the Gaussian illumination tails carry
%   percent-level power into field angles the lens apertures were never
%   sized for — a fuzzy, misleading beam edge at alignment power and watts
%   of stray light at experiment power. Note the design region is a DISC,
%   not the legacy 6x6 mm square: the optical axes are the chip DIAGONALS,
%   so a chip-aligned square pokes sqrt(2) of its half-width beyond the
%   checked field at the corners.
%
%   Safety by construction: ON fraction ~1% (far under the 50% cap) and the
%   largest contiguous blob (the ring) is <2% of the chip, passing
%   tfp.util.assertSlmPowerSafe's near-uniform discriminator honestly.
%
%   Inputs:
%     dmd     - object/struct with .nRows / .nCols (tests may pass a bare
%               struct, per the +patterns convention).
%     options - optional struct:
%       .patchDiameterPx - patch disc diameter (default: the handoff
%                          constant patch_diameter_px, read at runtime —
%                          design values are never hardcoded)
%       .ringWidthPx     - ring thickness            (default 5)
%       .crossHalfPx     - cross half-length         (default 60)
%       .lineWidthPx     - cross / tick line width   (default 5)
%       .tickLenDispPx   - dispersion tick length    (default 40)
%       .tickLenGroovePx - groove tick length        (default 20)
%       .center          - [col row] patch centre (default chip centre)
%
%   Returns logical(nRows, nCols).
%
%   See also tfp.patterns.singleSpot, tfp.optics.dmdToDispersionUm,
%   scripts/alpCheckerboard.m (chip smoke test — NOT an alignment target).

if nargin < 2 || isempty(options)
    options = struct();
end

nRows = double(dmd.nRows);
nCols = double(dmd.nCols);

patchDiamPx = tfp.util.configField(options, 'patchDiameterPx', []);
if isempty(patchDiamPx)
    c = tfp.util.readHandoffConstants();
    patchDiamPx = c.patch_diameter_px;
end
R        = double(patchDiamPx) / 2;
ringW    = double(tfp.util.configField(options, 'ringWidthPx',     5));
crossHalf = double(tfp.util.configField(options, 'crossHalfPx',    60));
lineW    = double(tfp.util.configField(options, 'lineWidthPx',     5));
tickDisp = double(tfp.util.configField(options, 'tickLenDispPx',   40));
tickGrv  = double(tfp.util.configField(options, 'tickLenGroovePx', 20));
center   = double(tfp.util.configField(options, 'center', ...
                  [(nCols + 1) / 2, (nRows + 1) / 2]));

if R <= ringW || 2 * R > min(nRows, nCols)
    error('tfp:patterns:alignmentTarget:badPatch', ...
        'patchDiameterPx = %g does not fit the %dx%d chip (or is degenerate).', ...
        patchDiamPx, nRows, nCols);
end

[cols, rows] = meshgrid(1:nCols, 1:nRows);
x = cols - center(1);            % +x along columns
y = rows - center(2);            % +y along rows
r = sqrt(x.^2 + y.^2);

% Rotated (diagonal) coordinates: u along the DISPERSION diagonal
% (+col,+row), v along the groove diagonal — matching dmdToDispersionUm.
u = (x + y) / sqrt(2);
v = (x - y) / sqrt(2);

% Ring at the patch edge (the worst-case-field probe).
ring = abs(r - R) <= ringW / 2;

% Centre cross along the chip axes.
cross_ = (abs(x) <= lineW / 2 & abs(y) <= crossHalf) | ...
         (abs(y) <= lineW / 2 & abs(x) <= crossHalf);

% Diagonal ticks just inside the ring. Dispersion ticks are LONGER than
% groove ticks so the two optical axes are distinguishable on a card.
inner    = R - ringW;            % inner edge of the ring
dispTick = abs(v) <= lineW / 2 & abs(u) >= inner - tickDisp & abs(u) <= inner - 3;
grvTick  = abs(u) <= lineW / 2 & abs(v) >= inner - tickGrv  & abs(v) <= inner - 3;

% Union, clipped to the patch disc (the ring's outer edge is the boundary).
mask = (ring | cross_ | dispTick | grvTick) & (r <= R + ringW / 2);
end
