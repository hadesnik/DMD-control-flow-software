function v = stepVerdict(step, result, context)
%stepVerdict Decide whether a bringup step passed, and say why in English.
%
%   v = tfp.gui.stepVerdict(step, result)
%   v = tfp.gui.stepVerdict(step, result, context)
%
%   THE POINT OF THIS FILE. A calibration GUI that prints numbers and leaves
%   the operator to decide whether they are good numbers is only usable by
%   someone who already knows the answer. This applies each step's declared
%   acceptance criteria to its result and returns a decision plus the
%   reasoning, in the same words whether it is rendered in the wizard, in
%   the HTML report, or at the command line.
%
%   FOUR OUTCOMES, and they are deliberately not a pass/fail pair:
%     'pass'    every criterion met. Move on.
%     'warn'    outside a DESIGN band, but the measurement is the truth.
%               The repo's standing doctrine: the handoff is design intent,
%               the bench is fact. Advancing is allowed and correct.
%     'adjust'  something PHYSICAL is wrong. Change it at the bench, then
%               retake this step. Advancing is blocked.
%     'fail'    the measurement itself did not work — bad fit, too few
%               points, a device that did not answer. Retake as-is with
%               different parameters. Advancing is blocked.
%
%   UNKNOWN CRITERIA. A criterion whose field is missing (a partial result,
%   an older saved calibration) cannot be evaluated. It never silently
%   passes: it contributes 'warn', except where the criterion's own severity
%   is 'fail', in which case not being able to verify is itself a stop. That
%   rule is why "power at 0 V is off" cannot be skipped by a result struct
%   that happens to lack the field.
%
%   Returns:
%     .stepId .verdict .headline
%     .rows        struct array, one per criterion: label, valueText,
%                  expectedText, ok (true|false|NaN), severity, why
%     .reading     cellstr — the interpretation paragraph
%     .remedy      cellstr — what to do about it (empty when passing)
%     .canAdvance  logical — may the wizard enable Next
%     .mustRetake  logical — should the wizard push Retake
%     .metrics     the derived metrics, kept for the report
%
%   See also tfp.gui.bringupSteps, tfp.gui.stepMetrics.

if nargin < 3 || isempty(context), context = struct(); end

v = struct('stepId', step.id, 'verdict', 'pass', 'headline', '', ...
    'rows', emptyRow(), 'reading', {{}}, 'remedy', {{}}, ...
    'canAdvance', true, 'mustRetake', false, 'metrics', struct());

% --- checklist steps: the operator is the instrument -------------------
if strcmp(step.kind, 'checklist')
    v = checklistVerdict(v, step, result);
    return
end

% --- derive, then test -------------------------------------------------
try
    v.metrics = tfp.gui.stepMetrics(step.id, result, context);
catch ME
    v.metrics = struct();
    v.reading{end+1} = sprintf('Derived metrics could not be computed (%s).', ME.message);
end

lookup = struct('result', result, 'm', v.metrics);

worst = 0;   % 0 pass, 1 warn, 2 adjust, 3 fail
for k = 1:numel(step.criteria)
    c   = step.criteria(k);
    row = evaluate(c, lookup);
    v.rows(end+1) = row;
    if isnan(row.ok)
        % Not evaluated — see the unknown rule in the header.
        contrib = severityRank(c.severity);
        if contrib < 3, contrib = 1; end
    elseif row.ok
        contrib = 0;
    else
        contrib = severityRank(c.severity);
    end
    worst = max(worst, contrib);
end

v.verdict    = rankName(worst);
v.canAdvance = worst <= 1;
v.mustRetake = worst >= 2;
v.headline   = headlineFor(step, v);
v.reading    = [v.reading, readingFor(step, v)];
if worst >= 1
    v.remedy = step.remedy;
end
end

% ===========================================================================

function v = checklistVerdict(v, step, result)
%checklistVerdict Every box ticked, or a list of what is not.
%
%   A checklist is not busywork here: each unticked item on the section 1
%   bench list is a scale constant that would be wrong downstream while
%   every internal consistency check still passed.
checked = [];
if isstruct(result) && isfield(result, 'checked')
    checked = logical(result.checked(:))';
end
n = numel(step.checks);
if numel(checked) ~= n
    checked = false(1, n);
end
for k = 1:n
    v.rows(end+1) = makeRow(step.checks{k}, boolText(checked(k)), 'confirmed', ...
        checked(k), 'adjust', '');
end
nUnchecked = sum(~checked);
if nUnchecked == 0
    v.verdict = 'pass'; v.canAdvance = true; v.mustRetake = false;
    v.headline = sprintf('All %d items confirmed.', n);
    v.reading  = {step.purpose};
else
    v.verdict = 'adjust'; v.canAdvance = false; v.mustRetake = true;
    v.headline = sprintf('%d of %d items still unconfirmed.', nUnchecked, n);
    v.reading  = {step.purpose, ...
        'The unconfirmed items are listed above. Each one is a physical fact about the bench that later steps compute with.'};
    v.remedy   = step.remedy;
end
end

function row = evaluate(c, lookup)
%evaluate One criterion against the result, returning a renderable row.
val = fetch(lookup, c.field);
expectedText = expectedString(c);

if isempty(val) || (isnumeric(val) && ~isscalar(val))
    row = makeRow(c.label, 'not measured', expectedText, NaN, c.severity, c.why);
    return
end
if isnumeric(val) && ~isfinite(val)
    row = makeRow(c.label, 'not measured', expectedText, NaN, c.severity, c.why);
    return
end

switch lower(c.test)
    case 'lt',      ok = double(val) <  c.value;
    case 'le',      ok = double(val) <= c.value;
    case 'gt',      ok = double(val) >  c.value;
    case 'ge',      ok = double(val) >= c.value;
    case 'eq',      ok = double(val) == c.value;
    case 'istrue',  ok = logical(val);
    case 'isfalse', ok = ~logical(val);
    otherwise
        row = makeRow(c.label, 'unknown test', expectedText, NaN, c.severity, c.why);
        return
end

row = makeRow(c.label, valueString(val, c), expectedText, logical(ok), ...
    c.severity, c.why);
end

function val = fetch(lookup, dotted)
%fetch Resolve a criterion's field. A leading 'm.' reads the derived
%   metrics; anything else reads the raw result struct.
parts = strsplit(char(dotted), '.');
if strcmp(parts{1}, 'm')
    cur = lookup.m;
    parts(1) = [];
else
    cur = lookup.result;
end
val = [];
for k = 1:numel(parts)
    if ~isstruct(cur) || isempty(cur) || ~isfield(cur, parts{k})
        return
    end
    cur = cur(1).(parts{k});
end
val = cur;
end

function s = headlineFor(step, v)
bad = v.rows(arrayfun(@(r) ~isnan(r.ok) && ~r.ok, v.rows));
unk = v.rows(arrayfun(@(r) isnan(r.ok), v.rows));
switch v.verdict
    case 'pass'
        s = sprintf('Section %s passed — every check met.', step.section);
    case 'warn'
        if ~isempty(bad)
            s = sprintf('Section %s measured. Outside a design band (%s), which is a note, not a problem.', ...
                step.section, joinLabels(bad));
        else
            s = sprintf('Section %s measured, with %d check(s) that could not be evaluated.', ...
                step.section, numel(unk));
        end
    case 'adjust'
        s = sprintf('Section %s needs a physical change: %s. Fix it at the bench, then retake.', ...
            step.section, joinLabels(bad));
    otherwise
        s = sprintf('Section %s did not measure successfully: %s. Retake.', ...
            step.section, joinLabels(bad));
end
end

function lines = readingFor(step, v)
%readingFor The interpretation paragraph: what each number means, with the
%   failing ones explained first because that is what the operator needs.
lines = {};
order = [find(arrayfun(@(r) ~isnan(r.ok) && ~r.ok, v.rows)), ...
         find(arrayfun(@(r) isnan(r.ok), v.rows)), ...
         find(arrayfun(@(r) ~isnan(r.ok) && r.ok, v.rows))];
for k = order
    r = v.rows(k);
    if isnan(r.ok)
        mark = 'could not evaluate';
    elseif r.ok
        mark = 'ok';
    else
        mark = upper(r.severity);
    end
    line = sprintf('%s: %s (wanted %s) — %s.', r.label, r.valueText, ...
        r.expectedText, mark);
    if ~isempty(r.why) && (isnan(r.ok) || ~r.ok)
        line = [line ' ' r.why]; %#ok<AGROW>
    end
    lines{end+1} = line; %#ok<AGROW>
end
if ~isempty(step.records)
    lines{end+1} = ['Record sheet: ' strjoin(step.records, '; ') '.'];
end
end

function s = joinLabels(rows)
if isempty(rows), s = '(none)'; return; end
labels = arrayfun(@(r) r.label, rows, 'UniformOutput', false);
s = strjoin(labels, ', ');
end

function s = expectedString(c)
switch lower(c.test)
    case 'lt',      s = sprintf('< %g%s', c.value, unitSuffix(c));
    case 'le',      s = sprintf('<= %g%s', c.value, unitSuffix(c));
    case 'gt',      s = sprintf('> %g%s', c.value, unitSuffix(c));
    case 'ge',      s = sprintf('>= %g%s', c.value, unitSuffix(c));
    case 'eq',      s = sprintf('= %g%s', c.value, unitSuffix(c));
    case 'istrue',  s = 'yes';
    case 'isfalse', s = 'no';
    otherwise,      s = '?';
end
end

function s = valueString(val, c)
if islogical(val)
    s = boolText(val);
elseif isnumeric(val)
    s = sprintf('%.4g%s', double(val), unitSuffix(c));
else
    s = char(val);
end
end

function s = unitSuffix(c)
if isempty(c.unit), s = ''; else, s = [' ' c.unit]; end
end

function s = boolText(tf)
if tf, s = 'yes'; else, s = 'no'; end
end

function r = severityRank(sev)
switch lower(char(sev))
    case 'info',   r = 0;
    case 'warn',   r = 1;
    case 'adjust', r = 2;
    case 'fail',   r = 3;
    otherwise,     r = 3;
end
end

function name = rankName(r)
names = {'pass', 'warn', 'adjust', 'fail'};
name  = names{min(max(r, 0), 3) + 1};
end

function r = emptyRow()
r = struct('label', {}, 'valueText', {}, 'expectedText', {}, 'ok', {}, ...
    'severity', {}, 'why', {});
end

function r = makeRow(label, valueText, expectedText, ok, severity, why)
r = struct('label', char(label), 'valueText', char(valueText), ...
    'expectedText', char(expectedText), 'ok', double(ok), ...
    'severity', char(severity), 'why', char(why));
end
