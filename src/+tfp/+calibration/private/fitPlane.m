function p = fitPlane(x, y, z)
%fitPlane Least-squares fit of a plane z = c0 + c1*x + c2*y.
%   Shared private helper for measureFocalPlaneTilt and its _mock. Uses the
%   same backslash OLS idiom as measurePSF / powerMeterSweep.
%
%   Inputs x,y,z : column (or any-shape) vectors of equal length.
%   Output p:
%     .coeffs        - [c0 c1 c2]; c1,c2 are slopes in z-units per x/y-unit
%     .zPred         - fitted z at the input points
%     .residualsRms  - RMS of (z - zPred)
%     .n             - number of points used
%     .valid         - false if <3 points or the points are collinear

x = x(:); y = y(:); z = z(:);
n = numel(z);

p.coeffs       = [NaN NaN NaN];
p.zPred        = nan(n, 1);
p.residualsRms = NaN;
p.n            = n;
p.valid        = false;

if n < 3
    return;
end

D = [ones(n,1), x, y];
if rank(D) < 3
    return;              % collinear / degenerate — no unique plane
end

c = D \ z;
p.coeffs       = c(:)';
p.zPred        = D * c;
p.residualsRms = sqrt(mean((z - p.zPred).^2));
p.valid        = true;
end
