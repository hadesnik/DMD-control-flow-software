function m = stepMetrics(stepId, result, context)
%stepMetrics Derive the quantities a step's acceptance criteria test.
%
%   m = tfp.gui.stepMetrics(stepId, result)
%   m = tfp.gui.stepMetrics(stepId, result, context)
%
%   The criteria in tfp.gui.bringupSteps are deliberately simple field
%   lookups with a comparison. Everything that needs arithmetic — is the
%   power curve monotonic, does the fitted scale agree with the handoff,
%   how big is the groove gradient relative to the dispersion one — is
%   computed here, in one headless, testable place, and reached from a
%   criterion as 'm.<name>'.
%
%   context (all optional):
%     .config    the session config, for comparisons against what the rig
%                was told (ETL plane spacing, expected z-stage mount)
%     .handoff   parsed handoff constants; read lazily if absent
%     .results   struct of earlier steps' results, keyed by step id — how
%                the tilt-sign check reaches the field-tilt proposal
%     .answers   operator answers collected during the step (the questions
%                a camera cannot answer, e.g. "did focus move deeper?")
%
%   EVERY metric is computed defensively: a missing or malformed field
%   yields NaN (numeric) or an empty logical, never an error. A metric that
%   could not be computed is reported by tfp.gui.stepVerdict as "not
%   evaluated" rather than silently passing — see its unknown-handling rule.
%
%   See also tfp.gui.bringupSteps, tfp.gui.stepVerdict.

if nargin < 3 || isempty(context), context = struct(); end
if nargin < 2, result = struct(); end
m = struct();

switch char(stepId)

    case 'prereq_software'
        % result is the preflight status struct array.
        st = result;
        if isstruct(st) && isfield(st, 'status')
            states = {st.status};
            m.nFailed  = sum(strcmpi(states, 'fail'));
            m.nPending = sum(strcmpi(states, 'pending')) + sum(strcmpi(states, 'absent'));
            % A device that ANNOUNCES itself as simulated is not the hazard —
            % a mock session is simulated by construction, says so in a banner
            % on every tab, refuses to write a rig config and refuses to emit
            % real light. The hazard is a device that FELL BACK to a simulator
            % when a real one was expected, which is what the session's own
            % `simulated` flags record. Counting the two together would make
            % the demo unable to advance past its own first step while telling
            % the rig nothing it does not already show in red.
            m.nUnexpectedlySimulated = countSimulated(context);
            m.nSimulatedRows = sum(strcmpi(states, 'simulated'));
        end

    case 'laser_state'
        fp = pick(result, 'frontPanelPowerW', []);
        m.hasFrontPanelPower = ~isempty(fp) && isfinite(fp) && fp > 0;

    case 'power_curve'
        v  = pick(result, 'voltage.voltageV',   []);
        p  = pick(result, 'voltage.powerMw',    []);
        sd = pick(result, 'voltage.powerStdMw', []);
        if ~isempty(v) && numel(v) == numel(p)
            [v, order] = sort(v(:));
            p = p(order); p = p(:);
            m.maxPowerMw = max(p);
            % "0 V means off" — the open safety question in CLAUDE.md. The
            % test is against the span of the curve rather than an absolute
            % milliwatt figure, because what matters is that the modulator
            % actually closes, not that the meter reads exactly zero.
            if v(1) <= eps && m.maxPowerMw > 0
                m.zeroIsOff = p(1) <= 0.02 * m.maxPowerMw;
            end
            % Monotonic to within the measurement noise: a curve that dips
            % by less than its own error bar is not evidence of a fold.
            if numel(p) > 2
                tol = 0.02 * max(m.maxPowerMw, eps);
                m.monotonic = all(diff(p) >= -tol);
            end
            if ~isempty(sd) && numel(sd) == numel(p)
                sd = sd(order); sd = sd(:);
                live = p > 0.05 * m.maxPowerMw;   % scatter on a dark reading is meaningless
                if any(live)
                    m.worstStdFrac = max(sd(live) ./ p(live));
                end
            end
            m.hasWorkingPoint = m.maxPowerMw >= 5 && min(p) <= 5;
        end

    case 'lateral_dmd_camera'
        % Compare the FITTED DMD scale against the handoff design values.
        % The chip is clocked 45 degrees, so the two scales lie along the
        % chip diagonals rather than its rows and columns — which is exactly
        % why this uses the singular values of the affine's linear part
        % instead of reading off its diagonal. The singular values are the
        % principal scales whatever the rotation.
        A   = pick(result, 'dmdToSample_affine', []);
        ump = pick(result, 'umPerPixel', NaN);
        h   = handoffOf(context);
        if ~isempty(A) && isequal(size(A), [3 3]) && isfinite(ump) && ~isempty(h)
            sv = svd(A(1:2, 1:2)) * ump;         % um at sample per DMD pixel
            m.umPerPxFittedMin = min(sv);
            m.umPerPxFittedMax = max(sv);
            m.anamorphicFitted = max(sv) / max(min(sv), eps);
            expMin = getfielddef(h, 'um_per_px_groove', NaN);
            expMax = getfielddef(h, 'um_per_px_disp',   NaN);
            if isfinite(expMin) && isfinite(expMax)
                m.scaleErrorFrac = max(abs(min(sv) - expMin) / expMin, ...
                                       abs(max(sv) - expMax) / expMax);
                % "A few percent" in the guide; 5 percent is the band, and it
                % only ever warns — the fit is the calibration.
                m.scaleAgreesWithHandoff = m.scaleErrorFrac <= 0.05;
            end
        end

    case 'lateral_scan_camera'
        bbox = pick(result, 'rectBboxPx', []);
        px   = pick(result, 'scanPixels', []);
        m.rectFound = ~isempty(bbox) && all(isfinite(bbox(:))) && all(bbox(3:end) > 0);
        if numel(px) == 2 && all(isfinite(px))
            m.pixelsAreSquare = px(1) == px(2);
            if m.rectFound && numel(bbox) >= 4
                wantAspect = max(px) / max(min(px), eps);
                gotAspect  = max(bbox(3:4)) / max(min(bbox(3:4)), eps);
                m.aspectError = abs(gotAspect - wantAspect) / wantAspect;
                m.aspectPlausible = m.aspectError <= 0.25;
            end
        end

    case 'lateral_signs'
        f = pick(result, 'scan_fast_axis_sign', NaN);
        s = pick(result, 'scan_slow_axis_sign', NaN);
        m.signsResolved = any(f == [1 -1]) && any(s == [1 -1]);

    case 'lateral_persist'
        A = pick(result, 'dmdToScan_affine', []);
        m.hasAffine = ~isempty(A) && isequal(size(A), [3 3]) && all(isfinite(A(:)));
        % composeCalibration warns rather than throws on a stage move, so the
        % warning has to be read back out of the composed notes.
        notes = pick(result, 'notes', '');
        m.stagePositionConsistent = ~contains(lower(char(notes)), 'stageposition');

    case 'field_tilt'
        a  = pick(result, 'fit.aUmPerUm', NaN);
        b  = pick(result, 'fit.bUmPerUm', NaN);
        edge = pick(result, 'focusAtWindowEdge', []);
        if isfinite(a) && isfinite(b)
            m.grooveFraction = abs(b) / max(abs(a), eps);
        end
        if ~isempty(edge)
            m.nFocusAtEdge = sum(logical(edge(:)));
        end

    case 'z_ruler'
        m.roundTripErrUm = pick(result, 'roundTripErrUm', NaN);
        m.directionConfirmed = pick(result, 'directionConfirmed', []);
        m.xyGateCorrect      = pick(result, 'xyGateCorrect', []);

    case 'z_slm_defocus'
        slope = pick(result, 'fit.slopeUmPerCmd', NaN);
        if isfinite(slope)
            % Compared as |slope| against 1 because the command is DEFINED in
            % sample-plane microns; the sign is the relay's, not an error.
            m.slopeAbsError = abs(abs(slope) - 1);
        end
        dz = pick(result, 'dzCmdUm', []);
        m.nDefocusPoints = numel(dz);

    case 'z_etl_planes'
        z = pick(result, 'planeZUm', []);
        z = z(:)';
        m.nPlanesFitted = sum(isfinite(z));
        if numel(z) > 1 && all(isfinite(z))
            d = diff(z);
            m.planesMonotonic = all(d > 0) || all(d < 0);
            m.planeSpacingUm  = mean(abs(d));
            want = configuredPlaneSpacing(context);
            if isfinite(want) && want > 0
                m.spacingErrorFrac = abs(m.planeSpacingUm - want) / want;
                m.spacingMatchesConfig = m.spacingErrorFrac <= 0.20;
            end
        end

    case 'z_compose'
        m.rulerMatches = ~pick(result, 'rulerMismatch', false);
        cmds = pick(result, 'dzCmdForPlane', []);
        if ~isempty(cmds)
            reach = remoteFocusRange(context);
            m.maxAbsCommandUm = max(abs(cmds(:)));
            m.commandsInRange = all(isfinite(cmds(:))) && m.maxAbsCommandUm <= reach;
        end

    case 'verify_marks'
        nA = pick(result, 'nAgree', NaN);
        nT = pick(result, 'nTotal', NaN);
        if isfinite(nA) && isfinite(nT) && nT > 0
            m.agreeFraction = nA / nT;
        end
        % A mark the locator never saw reports a plane index anyway (the
        % argmax of an all-NaN contrast vector is 1), so "did it agree" is
        % not the same question as "was it there". Separate them: an
        % unimaged mark means the grid is wider than the imaging field, and
        % that is a framing problem, not a calibration disagreement.
        found = pick(result, 'found', []);
        if ~isempty(found) && isstruct(found) && isfield(found, 'contrastByPlane')
            located = arrayfun(@(f) any(isfinite(f.contrastByPlane)), found);
            m.nMarksLocated  = sum(located);
            m.allMarksInField = all(located);
        end

    case 'verify_tilt_sign'
        planes = pick(result, 'planeIdx', []);
        planes = planes(:)';
        if numel(planes) > 1 && all(isfinite(planes))
            d = diff(planes);
            m.marchMonotonic = (all(d >= 0) || all(d <= 0)) && any(d ~= 0);
        end
        observed = pick(result, 'depthGradientSign', NaN);
        proposed = priorField(context, 'field_tilt', 'depthGradientSign', NaN);
        if isfinite(observed) && isfinite(proposed) && proposed ~= 0
            m.signAgreesWithTilt = (observed == proposed);
        end
end
end

% ===========================================================================

function v = pick(s, dotted, default)
%pick Fetch a dotted path out of a struct, or the default if any hop is
%   missing. Every metric above goes through this, which is why a partial
%   result degrades to "not evaluated" instead of erroring mid-report.
if nargin < 3, default = []; end
v = default;
if ~isstruct(s) || isempty(s), return; end
parts = strsplit(char(dotted), '.');
cur = s;
for k = 1:numel(parts)
    if ~isstruct(cur) || ~isfield(cur, parts{k}) || isempty(cur)
        return
    end
    cur = cur(1).(parts{k});
end
v = cur;
end

function v = getfielddef(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end

function h = handoffOf(context)
h = getfielddef(context, 'handoff', []);
if isempty(h)
    try
        h = tfp.util.readHandoffConstants();
    catch
        h = [];
    end
end
end

function n = countSimulated(context)
%countSimulated The session's own simulated-device flags, which the preflight
%   table does not always show as a row of its own.
n = 0;
sim = getfielddef(context, 'simulated', struct());
if isstruct(sim)
    f = fieldnames(sim);
    for k = 1:numel(f)
        if islogical(sim.(f{k})) && sim.(f{k}), n = n + 1; end
    end
end
end

function want = configuredPlaneSpacing(context)
cfg = getfielddef(context, 'config', struct());
etl = getfielddef(cfg, 'etl', struct());
want = double(getfielddef(etl, 'plane_spacing_um', NaN));
end

function r = remoteFocusRange(context)
%remoteFocusRange Half the handoff's remote-focus span, as the reachable
%   command magnitude either side of zero.
h = handoffOf(context);
r = double(getfielddef(h, 'remote_focus_um', 908)) / 2;
end

function v = priorField(context, stepId, name, default)
%priorField Reach into an earlier step's saved result.
v = default;
res = getfielddef(context, 'results', struct());
if isstruct(res) && isfield(res, stepId)
    v = pick(res.(stepId), name, default);
end
end
