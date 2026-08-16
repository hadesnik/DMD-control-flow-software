function assertSlmPowerSafe(patterns, powerMw, config)
%assertSlmPowerSafe Enforce the SLM liquid-crystal alignment power cap.
%
%   tfp.util.assertSlmPowerSafe(patterns, powerMw, config)
%
%   Makes docs/optics_handoff.md §7b LIVE: with the 3D-SHOT diffuser gone,
%   the SLM sits at a Fourier plane of the DMD pattern. An all-ON /
%   near-uniform DMD patch focuses each colour to a diffraction-limited
%   core sheared into a spectral LINE of ~0.1 mm^2 on the LC — so
%   alignment-style patterns are power-capped (slm_alignment_cap_mW = 44,
%   read from the handoff constants, FAIL-CLOSED: a missing handoff file
%   is an error). Sparse operating patterns spread each target's light
%   over ~2.8 mm on the LC and are benign.
%
%   Discriminator: the handoff's "all-ON or near-uniform" is quantified
%   here as the largest CONTIGUOUS ON blob per frame — a single blob
%   covering more than config.slm.uniform_blob_fraction of the chip
%   (default 0.02, deliberately conservative; an optics-repo-ratified
%   constant is requested for the f7=300 regeneration) counts as an
%   alignment-style pattern and caps powerMw at the handoff value.
%
%   patterns: logical(H, W) or logical(H, W, N) DMD frames.
%   powerMw:  commanded power at the grating arm (mW). Empty/NaN passes
%             (power unknown at this call site — the AO queue is capped
%             elsewhere).
%   config:   full config struct (reads config.slm.uniform_blob_fraction
%             and skips the check entirely when config.slm.enabled is
%             false — no SLM in the path, no LC to protect).
%
%   Throws tfp:util:assertSlmPowerSafe:slmAlignmentCapExceeded.
%
%   See also tfp.hardware.DMD.assertPatternsSafe (the on-fraction cap,
%   which protects the DMD relay pupil and applies at ANY power).

if nargin < 3 || isempty(config)
    config = struct();
end
slmCfg = tfp.util.configField(config, 'slm', struct());
if ~logical(tfp.util.configField(slmCfg, 'enabled', false))
    return   % no SLM in the path
end
if isempty(powerMw) || ~isscalar(powerMw) || ~isfinite(powerMw)
    return   % power unknown here; enforced where it is known
end

caps  = tfp.util.readHandoffConstants();   % fail-closed on missing file
capMw = caps.slm_alignment_cap_mW;
blobFracLimit = double(tfp.util.configField(slmCfg, ...
    'uniform_blob_fraction', 0.02));

if islogical(patterns)
    pats = patterns;
else
    pats = logical(patterns);
end

for k = 1:size(pats, 3)
    frame = pats(:, :, k);
    if ~any(frame(:))
        continue
    end
    cc = bwconncomp(frame);
    biggest = max(cellfun(@numel, cc.PixelIdxList));
    blobFrac = biggest / numel(frame);
    if blobFrac > blobFracLimit && powerMw > capMw
        error('tfp:util:assertSlmPowerSafe:slmAlignmentCapExceeded', ...
            ['Frame %d has a contiguous ON blob covering %.1f%% of the ' ...
             'chip (> %.1f%%): with the SLM in the path this focuses a ' ...
             'spectral line onto the LC. Commanded power %.1f mW exceeds ' ...
             'the %g mW all-ON alignment cap (optics_handoff.md §7b). ' ...
             'Lower the power for alignment patterns, or break the ' ...
             'pattern into sparse targets.'], ...
            k, 100 * blobFrac, 100 * blobFracLimit, powerMw, capMw);
    end
end
end
