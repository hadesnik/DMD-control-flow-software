function g = fitGaussian2D(frame, centroid, hwMax)
%fitGaussian2D Closed-form weighted-Gaussian fit (no Optimization Toolbox).
%   Fits ln(I) to a 2D quadratic over a crop around the spot, weighting each
%   pixel by I^2 (Guo's method). Falls back to intensity-weighted second
%   moments if the quadratic is not concave or too few pixels survive.
%
%   Shared private helper used by measurePSF (PSF widths) and
%   measureFocalPlaneTilt (spot sharpness as a focus metric).
%
%   Inputs:
%     frame    - 2D double image.
%     centroid - [x y] = [col row] spot centre (e.g. from findSpotCentroid).
%     hwMax    - max half-width of the crop (px).
%   Output g: struct with fields .sx .sy (sigmas, px), .x0 .y0 (centre, px),
%     .A (peak amplitude), .B (background).
%
%   Throws tfp:calibration:fitGaussian2D:flatSpot if the spot has no contrast.
[H, W] = size(frame);
cc = round(centroid(1));   % column (x)
rr = round(centroid(2));   % row (y)

hw = min([hwMax, cc - 1, W - cc, rr - 1, H - rr]);
hw = max(hw, 3);
cols = (cc - hw):(cc + hw);
rows = (rr - hw):(rr + hw);
crop = frame(rows, cols);

% background = median of the crop border; subtract and clip
border = [crop(1,:), crop(end,:), crop(:,1).', crop(:,end).'];
B = median(border);
w = crop - B;
peak = max(w(:));
if ~(peak > 0)
    error('tfp:calibration:fitGaussian2D:flatSpot', ...
        'Detected spot has no contrast above the background.');
end

[CX, CY] = meshgrid(cols, rows);   % full-frame coords, size(crop)
mask = w > 0.15 * peak;
xi = CX(mask);  yi = CY(mask);  wi = w(mask);

useFallback = numel(wi) < 6;
if ~useFallback
    % local coords for conditioning
    xs = xi - cc;  ys = yi - rr;
    D  = [ones(numel(wi),1), xs, ys, xs.^2, ys.^2];
    Wt = wi.^2;                         % Guo weighting
    coef = (D' * (D .* Wt)) \ (D' * (Wt .* log(wi)));
    c3 = coef(4);  c4 = coef(5);
    if c3 < 0 && c4 < 0
        g.sx = sqrt(-1 / (2 * c3));
        g.sy = sqrt(-1 / (2 * c4));
        g.x0 = -coef(2) / (2 * c3) + cc;
        g.y0 = -coef(3) / (2 * c4) + rr;
        g.A  = exp(coef(1) - coef(2)^2/(4*c3) - coef(3)^2/(4*c4));
        g.B  = B;
        return;
    end
    useFallback = true; %#ok<NASGU>
end

% --- fallback: intensity-weighted second central moments ---
sumw = sum(wi);
mx = sum(wi .* xi) / sumw;
my = sum(wi .* yi) / sumw;
g.sx = sqrt(max(sum(wi .* (xi - mx).^2) / sumw, eps));
g.sy = sqrt(max(sum(wi .* (yi - my).^2) / sumw, eps));
g.x0 = mx;
g.y0 = my;
g.A  = peak;
g.B  = B;
end
