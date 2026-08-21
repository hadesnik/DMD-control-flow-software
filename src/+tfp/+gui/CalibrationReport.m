classdef CalibrationReport < handle
    %CalibrationReport The dated folder one calibration session leaves behind.
    %
    %   Every guided step writes here as it completes, so the record survives
    %   a crashed MATLAB, a closed window, or an operator who walks away
    %   mid-procedure. The report is rewritten after each step rather than at
    %   the end for exactly that reason.
    %
    %   LAYOUT — calibration/<YYYY-MM-DD>_<name>/
    %     report.html        the whole session, self-contained, openable in a
    %                        browser: what was done, what was measured, what
    %                        the verdict was and why
    %     report.json        the same, machine-readable
    %     steps/<id>.json    one step's verdict, rows and metrics (small)
    %     steps/<id>.mat     that step's FULL result struct with provenance
    %     figures/<id>.png   the step's plot, embedded in the HTML as well
    %     figures/<id>.pdf   vector copy of the same plot
    %
    %   WHY IN THE REPO. Calibrations are the rig's history: what the scale
    %   was on the day an experiment ran is not recoverable from anything
    %   else. The small artifacts (report, verdicts, figures) are tracked;
    %   the heavy .mat results are gitignored — see .gitignore, which carries
    %   the split.
    %
    %   No graphics anywhere in this file: the HTML is text, and figure files
    %   are exported by tfp.gui.CalibrationApp (the only file permitted to
    %   touch graphics) and handed here with attachFigure.
    %
    %   See also tfp.gui.CalibrationSession, tfp.gui.stepVerdict.

    properties (SetAccess = private)
        dir        = ''      % the dated session folder
        sessionName = ''
        meta       = struct()
        entries    = struct('stepId', {}, 'section', {}, 'title', {}, ...
                            'verdict', {}, 'headline', {}, 'rows', {}, ...
                            'reading', {}, 'remedy', {}, 'records', {}, ...
                            'knobs', {}, 'figurePng', {}, 'figurePdf', {}, ...
                            'matPath', {}, 'attempt', {}, 'decidedAt', {}, ...
                            'operatorNote', {})
    end

    methods
        function obj = CalibrationReport(root, sessionName, meta)
            %CalibrationReport Open (or reopen) a dated session folder.
            if nargin < 3 || isempty(meta), meta = struct(); end
            if nargin < 2 || isempty(sessionName), sessionName = 'calib'; end
            obj.sessionName = char(sessionName);
            obj.meta = meta;

            stamp = char(datetime('now', 'Format', 'yyyy-MM-dd'));
            base  = fullfile(char(root), sprintf('%s_%s', stamp, obj.sessionName));
            if isfolder(base)
                % A second session on the same day keeps its own folder rather
                % than overwriting the morning's calibration.
                base = sprintf('%s_%s', base, ...
                    char(datetime('now', 'Format', 'HHmmss')));
            end
            obj.dir = base;
            mkdir(obj.dir);
            mkdir(fullfile(obj.dir, 'steps'));
            mkdir(fullfile(obj.dir, 'figures'));
        end

        function p = htmlPath(obj)
            p = fullfile(obj.dir, 'report.html');
        end

        function p = recordStep(obj, step, result, verdict, options)
            %recordStep Persist one completed step and refresh the report.
            %
            %   Returns the path of the .mat holding the full result. A step
            %   that is retaken overwrites its entry — the report shows the
            %   accepted attempt and how many attempts it took, which is
            %   itself worth knowing when reading a calibration back later.
            if nargin < 5 || isempty(options), options = struct(); end

            e = struct();
            e.stepId    = step.id;
            e.section   = step.section;
            e.title     = step.title;
            e.verdict   = verdict.verdict;
            e.headline  = verdict.headline;
            e.rows      = verdict.rows;
            e.reading   = verdict.reading;
            e.remedy    = verdict.remedy;
            e.records   = step.records;
            e.knobs     = tfp.util.configField(options, 'knobValues', struct());
            e.figurePng = '';
            e.figurePdf = '';
            e.attempt   = double(tfp.util.configField(options, 'attempt', 1));
            e.decidedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
            e.operatorNote = char(tfp.util.configField(options, 'operatorNote', ''));

            p = fullfile(obj.dir, 'steps', [step.id '.mat']);
            try
                save(p, 'result', '-v7.3');
            catch ME
                warning('tfp:gui:CalibrationReport:saveFailed', ...
                    'could not save the full result for %s: %s', step.id, ME.message);
                p = '';
            end
            e.matPath = p;

            % Keep any figure already attached for this step across a rewrite.
            idx = obj.indexOf(step.id);
            if idx > 0
                e.figurePng = obj.entries(idx).figurePng;
                e.figurePdf = obj.entries(idx).figurePdf;
                obj.entries(idx) = e;
            else
                obj.entries(end+1) = e;
            end

            obj.writeStepJson(e, verdict);
            obj.write();
        end

        function [pngPath, pdfPath] = figurePaths(obj, stepId)
            %figurePaths Where the view should export this step's plot.
            pngPath = fullfile(obj.dir, 'figures', [char(stepId) '.png']);
            pdfPath = fullfile(obj.dir, 'figures', [char(stepId) '.pdf']);
        end

        function attachFigure(obj, stepId, pngPath, pdfPath)
            %attachFigure Register an exported figure and refresh the report.
            idx = obj.indexOf(stepId);
            if idx == 0, return; end
            if nargin >= 3 && isfile(pngPath), obj.entries(idx).figurePng = pngPath; end
            if nargin >= 4 && isfile(pdfPath), obj.entries(idx).figurePdf = pdfPath; end
            obj.write();
        end

        function note(obj, stepId, text)
            %note Attach an operator note to a recorded step.
            idx = obj.indexOf(stepId);
            if idx == 0, return; end
            obj.entries(idx).operatorNote = char(text);
            obj.write();
        end

        function write(obj)
            %write Regenerate report.html and report.json from the entries.
            obj.writeJson();
            obj.writeHtml();
        end
    end

    % =======================================================================
    methods (Access = private)

        function idx = indexOf(obj, stepId)
            idx = 0;
            for k = 1:numel(obj.entries)
                if strcmp(obj.entries(k).stepId, stepId), idx = k; return; end
            end
        end

        function writeStepJson(obj, e, verdict)
            payload = e;
            payload.metrics = jsonSafe(verdict.metrics);
            payload = rmfield(payload, 'matPath');
            writeText(fullfile(obj.dir, 'steps', [e.stepId '.json']), ...
                prettyJson(jsonSafe(payload)));
        end

        function writeJson(obj)
            payload = struct( ...
                'sessionName', obj.sessionName, ...
                'directory',   obj.dir, ...
                'meta',        jsonSafe(obj.meta), ...
                'writtenAt',   char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
                'steps',       {arrayfun(@(e) jsonSafe(rmfield(e, 'rows')), ...
                                         obj.entries, 'UniformOutput', false)});
            writeText(fullfile(obj.dir, 'report.json'), prettyJson(payload));
        end

        function writeHtml(obj)
            h = {};
            h{end+1} = '<title>Calibration report</title>';
            h{end+1} = styleBlock();
            h{end+1} = '<main>';
            h{end+1} = sprintf('<h1>Calibration session &mdash; %s</h1>', ...
                esc(obj.sessionName));
            h{end+1} = obj.metaBlock();
            h{end+1} = obj.summaryTable();

            for k = 1:numel(obj.entries)
                h{end+1} = obj.stepSection(obj.entries(k)); %#ok<AGROW>
            end

            if isempty(obj.entries)
                h{end+1} = '<p class="muted">No steps completed yet.</p>';
            end
            h{end+1} = '</main>';
            writeText(obj.htmlPath(), strjoin(h, newline));
        end

        function s = metaBlock(obj)
            rows = {};
            rows{end+1} = row2('Folder', obj.dir);
            f = fieldnames(obj.meta);
            for k = 1:numel(f)
                rows{end+1} = row2(f{k}, scalarText(obj.meta.(f{k}))); %#ok<AGROW>
            end
            rows{end+1} = row2('Written', char(datetime('now', ...
                'Format', 'yyyy-MM-dd HH:mm:ss')));
            s = ['<table class="meta">' strjoin(rows, '') '</table>'];
        end

        function s = summaryTable(obj)
            if isempty(obj.entries), s = ''; return; end
            rows = {'<tr><th>&sect;</th><th>Step</th><th>Verdict</th><th>Headline</th></tr>'};
            for k = 1:numel(obj.entries)
                e = obj.entries(k);
                rows{end+1} = sprintf( ...
                    ['<tr><td>%s</td><td><a href="#%s">%s</a></td>' ...
                     '<td><span class="pill %s">%s</span></td><td>%s</td></tr>'], ...
                    esc(e.section), esc(e.stepId), esc(e.title), ...
                    esc(e.verdict), esc(upper(e.verdict)), esc(e.headline)); %#ok<AGROW>
            end
            s = ['<h2>Summary</h2><table class="summary">' strjoin(rows, '') '</table>'];
        end

        function s = stepSection(~, e)
            p = {};
            p{end+1} = sprintf('<section id="%s">', esc(e.stepId));
            p{end+1} = sprintf('<h2>&sect;%s &mdash; %s <span class="pill %s">%s</span></h2>', ...
                esc(e.section), esc(e.title), esc(e.verdict), esc(upper(e.verdict)));
            p{end+1} = sprintf('<p class="headline">%s</p>', esc(e.headline));

            if ~isempty(e.rows)
                tr = {'<tr><th>Check</th><th>Measured</th><th>Wanted</th><th>Result</th></tr>'};
                for k = 1:numel(e.rows)
                    r = e.rows(k);
                    if isnan(r.ok)
                        cls = 'unknown'; mark = 'not evaluated';
                    elseif r.ok
                        cls = 'ok'; mark = 'ok';
                    else
                        cls = lower(r.severity); mark = upper(r.severity);
                    end
                    tr{end+1} = sprintf( ...
                        '<tr><td>%s</td><td class="num">%s</td><td class="num">%s</td><td><span class="pill %s">%s</span></td></tr>', ...
                        esc(r.label), esc(r.valueText), esc(r.expectedText), ...
                        cls, mark); %#ok<AGROW>
                end
                p{end+1} = ['<table class="checks">' strjoin(tr, '') '</table>'];
            end

            if ~isempty(e.figurePng) && isfile(e.figurePng)
                uri = dataUri(e.figurePng, 'image/png');
                if ~isempty(uri)
                    p{end+1} = sprintf('<figure><img src="%s" alt="%s"></figure>', ...
                        uri, esc(e.title));
                end
            end

            p{end+1} = listBlock('Reading', e.reading);
            p{end+1} = listBlock('What to change', e.remedy);
            p{end+1} = listBlock('Record sheet', e.records);

            if ~isempty(e.operatorNote)
                p{end+1} = sprintf('<p class="note"><b>Operator note:</b> %s</p>', ...
                    esc(e.operatorNote));
            end

            knobText = knobLine(e.knobs);
            foot = sprintf('Attempt %d &middot; completed %s', e.attempt, esc(e.decidedAt));
            if ~isempty(knobText)
                foot = [foot ' &middot; settings: ' esc(knobText)];
            end
            if ~isempty(e.figurePdf) && isfile(e.figurePdf)
                foot = [foot sprintf(' &middot; <a href="figures/%s.pdf">vector figure</a>', ...
                    esc(e.stepId))];
            end
            p{end+1} = sprintf('<p class="muted">%s</p>', foot);
            p{end+1} = '</section>';
            s = strjoin(p, newline);
        end
    end
end

% ===========================================================================

function s = listBlock(title, items)
s = '';
if isempty(items), return; end
if ischar(items), items = {items}; end
li = cellfun(@(t) sprintf('<li>%s</li>', esc(t)), items, 'UniformOutput', false);
s = sprintf('<h3>%s</h3><ul>%s</ul>', esc(title), strjoin(li, ''));
end

function s = row2(k, v)
s = sprintf('<tr><th>%s</th><td>%s</td></tr>', esc(k), esc(v));
end

function s = knobLine(knobs)
s = '';
if ~isstruct(knobs) || isempty(fieldnames(knobs)), return; end
f = fieldnames(knobs);
parts = cell(1, numel(f));
for k = 1:numel(f)
    parts{k} = sprintf('%s=%s', f{k}, scalarText(knobs.(f{k})));
end
s = strjoin(parts, ', ');
end

function s = scalarText(v)
if ischar(v)
    s = v;
elseif isstring(v) && isscalar(v)
    s = char(v);
elseif islogical(v) && isscalar(v)
    if v, s = 'yes'; else, s = 'no'; end
elseif isnumeric(v) && isscalar(v)
    s = sprintf('%g', v);
elseif isnumeric(v)
    s = ['[' strtrim(sprintf('%g ', v)) ']'];
elseif isa(v, 'datetime')
    s = char(v);
else
    s = class(v);
end
end

function uri = dataUri(path, mime)
%dataUri Inline a file so the report is self-contained — it has to survive
%   being copied off the rig, mailed, or published without its folder.
uri = '';
try
    fid = fopen(path, 'r');
    if fid < 0, return; end
    bytes = fread(fid, inf, '*uint8');
    fclose(fid);
    uri = ['data:' mime ';base64,' char(matlab.net.base64encode(bytes))];
catch
    uri = '';
end
end

function writeText(path, text)
fid = fopen(path, 'w');
if fid < 0
    warning('tfp:gui:CalibrationReport:writeFailed', 'could not write %s', path);
    return
end
fwrite(fid, unicode2native(text, 'UTF-8'));
fclose(fid);
end

function s = esc(t)
if ~ischar(t), t = scalarText(t); end
s = strrep(t, '&', '&amp;');
s = strrep(s, '<', '&lt;');
s = strrep(s, '>', '&gt;');
end

function s = prettyJson(payload)
try
    s = jsonencode(payload, 'PrettyPrint', true);
catch
    s = jsonencode(payload);
end
end

function p = jsonSafe(p)
%jsonSafe datetime and function_handle both break jsonencode.
if isstruct(p)
    for k = 1:numel(p)
        f = fieldnames(p);
        for j = 1:numel(f)
            p(k).(f{j}) = jsonSafe(p(k).(f{j}));
        end
    end
elseif isa(p, 'datetime')
    p = char(p);
elseif isa(p, 'function_handle')
    p = func2str(p);
elseif iscell(p)
    for k = 1:numel(p)
        p{k} = jsonSafe(p{k});
    end
end
end

function s = styleBlock()
%styleBlock Inline CSS. The report must render with no network access — it
%   is read on a rig PC that often has none, and published as an artifact
%   where external stylesheets are blocked outright.
s = ['<style>' ...
    ':root{--bg:#fff;--fg:#1a1a1a;--muted:#666;--line:#e2e2e2;--ok:#1a7f37;' ...
    '--warn:#9a6700;--adjust:#bc4c00;--fail:#b62324;--unknown:#57606a;}' ...
    '@media (prefers-color-scheme:dark){:root:not([data-theme="light"])' ...
    '{--bg:#14171a;--fg:#e6e6e6;--muted:#9aa0a6;--line:#2c3136;--ok:#4ac26b;' ...
    '--warn:#d4a72c;--adjust:#f0883e;--fail:#ff7b72;--unknown:#8b949e;}}' ...
    ':root[data-theme="dark"]{--bg:#14171a;--fg:#e6e6e6;--muted:#9aa0a6;' ...
    '--line:#2c3136;--ok:#4ac26b;--warn:#d4a72c;--adjust:#f0883e;--fail:#ff7b72;' ...
    '--unknown:#8b949e;}' ...
    'body{background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,' ...
    'BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;margin:0;}' ...
    'main{max-width:52rem;margin:0 auto;padding:2rem 1.25rem 5rem;}' ...
    'h1{font-size:1.6rem;margin:0 0 1rem;}' ...
    'h2{font-size:1.2rem;margin:2.5rem 0 .5rem;padding-top:1rem;' ...
    'border-top:1px solid var(--line);}' ...
    'h3{font-size:.95rem;margin:1.2rem 0 .3rem;color:var(--muted);' ...
    'text-transform:uppercase;letter-spacing:.04em;}' ...
    'table{border-collapse:collapse;width:100%;margin:.5rem 0;font-size:.92rem;' ...
    'display:block;overflow-x:auto;}' ...
    'th,td{text-align:left;padding:.35rem .6rem;border-bottom:1px solid var(--line);' ...
    'vertical-align:top;}' ...
    'th{color:var(--muted);font-weight:600;}' ...
    'td.num{font-variant-numeric:tabular-nums;white-space:nowrap;}' ...
    'table.meta th{width:11rem;}' ...
    '.pill{display:inline-block;padding:.05rem .5rem;border-radius:999px;' ...
    'font-size:.75rem;font-weight:700;letter-spacing:.03em;color:#fff;}' ...
    '.pill.pass,.pill.ok{background:var(--ok);}.pill.warn{background:var(--warn);}' ...
    '.pill.adjust{background:var(--adjust);}.pill.fail{background:var(--fail);}' ...
    '.pill.unknown{background:var(--unknown);}' ...
    '.headline{font-size:1.02rem;margin:.4rem 0 1rem;}' ...
    '.muted{color:var(--muted);font-size:.85rem;}' ...
    '.note{border-left:3px solid var(--line);padding-left:.8rem;}' ...
    'ul{margin:.3rem 0 .8rem;padding-left:1.2rem;}li{margin:.15rem 0;}' ...
    'figure{margin:1rem 0;}img{max-width:100%;height:auto;border:1px solid var(--line);' ...
    'border-radius:6px;background:#fff;}' ...
    'a{color:inherit;}' ...
    '</style>'];
end
