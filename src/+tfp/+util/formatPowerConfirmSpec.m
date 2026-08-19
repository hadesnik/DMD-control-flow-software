function lines = formatPowerConfirmSpec(spec, options)
%formatPowerConfirmSpec Render a power-step confirmation spec as text.
%
%   lines = tfp.util.formatPowerConfirmSpec(spec)
%   lines = tfp.util.formatPowerConfirmSpec(spec, options)
%
%   ONE WORDING, THREE CONSUMERS: the console prompt
%   (tfp.util.consoleConfirmPower), the GUI's uiconfirm body, and the session
%   log. Two copies of a safety message is how they drift, and the one in the
%   log stops matching the one the operator actually saw.
%
%   spec is the struct built by tfp.hardware.LaserPowerController; see its
%   buildSpec for the field list.
%
%   options:
%     .width   wrap width for the warning lines (default 74)
%     .bullet  prefix for warnings (default '  ! ')
%
%   Returns a cellstr, one entry per line — the caller joins with newline
%   (console) or sprintf('%s\n') (uiconfirm), and can style per line.

if nargin < 2 || isempty(options), options = struct(); end
width  = double(tfp.util.configField(options, 'width',  74));
bullet = char(tfp.util.configField(options, 'bullet', '  ! '));

lines = {};
lines{end+1} = upper(spec.title);
lines{end+1} = repmat('=', 1, min(width, numel(lines{1})));

lines{end+1} = sprintf('  Requested   : %s  (%s on %s)', ...
    mwStr(spec.requestedMw), voltStr(spec.requestedV), chanStr(spec.aoChannel));
lines{end+1} = sprintf('  Currently   : %s  (%s)', ...
    mwStr(spec.previousMw), voltStr(spec.previousV));

% The pulse-energy line is the one that matters; give it the margin in the
% same breath so nobody has to divide two numbers under time pressure.
lines{end+1} = sprintf('  Pulse energy: %.1f uJ of %.0f uJ ceiling   (%.2fx margin)', ...
    spec.pulseEnergyUJ, spec.ceilingUJ, spec.marginX);
lines{end+1} = sprintf('  Relay pupil : %.2e W/cm2 of ~%.0e threshold', ...
    spec.pupilIntensityWcm2, spec.thresholdWcm2);
lines{end+1} = sprintf('  Pattern     : %.2f%% ON, largest contiguous blob %.2f%%', ...
    100 * spec.onFraction, 100 * spec.largestBlobFraction);

if isfield(spec, 'powerIsWorstCase') && spec.powerIsWorstCase
    lines{end+1} = '  NOTE        : no power curve yet — figures are a WORST-CASE bound.';
end

ls = spec.laserState;
if isstruct(ls) && isfield(ls, 'repRateKhz')
    lines{end+1} = sprintf('  Laser       : %g kHz / %g = %.3g kHz effective%s', ...
        ls.repRateKhz, ls.pulsePickerDivision, ls.effectiveRepRateHz / 1e3, ...
        frontPanelSuffix(ls));
    lines{end+1} = sprintf('  Shutter     : %s', ternary(ls.shutterOpen, 'OPEN', 'closed'));
end

if isfield(spec, 'warnings') && ~isempty(spec.warnings)
    lines{end+1} = '';
    for k = 1:numel(spec.warnings)
        wrapped = wrapText(spec.warnings{k}, width - numel(bullet));
        for j = 1:numel(wrapped)
            if j == 1
                lines{end+1} = [bullet wrapped{j}];        %#ok<AGROW>
            else
                lines{end+1} = [repmat(' ', 1, numel(bullet)) wrapped{j}]; %#ok<AGROW>
            end
        end
    end
end

switch lower(spec.severity)
    case 'danger'
        lines{end+1} = '';
        lines{end+1} = '  *** Check the beam path and the meter before proceeding. ***';
    case 'caution'
        lines{end+1} = '';
        lines{end+1} = '  Power is increasing by more than 2x.';
end

end

% ---------------------------------------------------------------------------
function s = mwStr(mw)
if isempty(mw) || ~isfinite(mw)
    s = '(uncalibrated)';
else
    s = sprintf('%.3g mW', mw);
end
end

function s = voltStr(v)
if isempty(v) || ~isfinite(v)
    s = '-- V';
else
    s = sprintf('%.3f V', v);
end
end

function s = chanStr(c)
if isempty(c), s = '(unwired)'; else, s = c; end
end

function s = frontPanelSuffix(ls)
if isfield(ls, 'frontPanelPowerW') && ~isempty(ls.frontPanelPowerW)
    s = sprintf(', front panel %.3g W', ls.frontPanelPowerW);
else
    s = '';
end
end

function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end

% ---------------------------------------------------------------------------
function out = wrapText(txt, width)
%wrapText Greedy word wrap; returns a cellstr.
words = strsplit(strtrim(char(txt)));
out   = {};
cur   = '';
for k = 1:numel(words)
    if isempty(cur)
        cand = words{k};
    else
        cand = [cur ' ' words{k}];
    end
    if numel(cand) > width && ~isempty(cur)
        out{end+1} = cur;   %#ok<AGROW>
        cur = words{k};
    else
        cur = cand;
    end
end
if ~isempty(cur), out{end+1} = cur; end
if isempty(out),  out = {''};       end
end
