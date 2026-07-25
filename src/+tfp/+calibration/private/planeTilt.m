function t = planeTilt(plane, umPerPixel, x, y)
%planeTilt Reduce a fitted focal-surface plane to a physical tilt.
%   Shared private helper for measureFocalPlaneTilt and its _mock.
%
%   Inputs:
%     plane      - struct from fitPlane (needs .coeffs and .valid).
%     umPerPixel - DMD sample-plane pixel size (µm per DMD pixel). The plane is
%                  fitted with z in µm and lateral coords in DMD pixels, so the
%                  physical (dimensionless) slope is coeff / umPerPixel.
%     x, y       - (optional) lateral coords (DMD px, relative to centre) over
%                  which to compute the peak-to-valley Z span.
%
%   Output t:
%     .tiltAngleDeg    - total tilt of the focal plane from horizontal (deg)
%     .tiltAzimuthDeg  - azimuth of the steepest-ascent direction (deg)
%     .tiltAnglesXYDeg - [theta_x theta_y] per-axis tilt (deg)
%     .peakToValleyUm  - max-min of the fitted plane over (x,y) in µm (NaN if
%                        x,y not given)

t.tiltAngleDeg    = NaN;
t.tiltAzimuthDeg  = NaN;
t.tiltAnglesXYDeg = [NaN NaN];
t.peakToValleyUm  = NaN;

if ~isstruct(plane) || ~isfield(plane, 'valid') || ~plane.valid
    return;
end

sx = plane.coeffs(2) / umPerPixel;   % µm-z per µm-lateral (dimensionless)
sy = plane.coeffs(3) / umPerPixel;

t.tiltAnglesXYDeg = [atand(sx), atand(sy)];
t.tiltAngleDeg    = atand(sqrt(sx.^2 + sy.^2));
t.tiltAzimuthDeg  = atan2d(sy, sx);

if nargin >= 4 && ~isempty(x)
    x = x(:); y = y(:);
    z = plane.coeffs(1) + plane.coeffs(2)*x + plane.coeffs(3)*y;
    t.peakToValleyUm = max(z) - min(z);
end
end
