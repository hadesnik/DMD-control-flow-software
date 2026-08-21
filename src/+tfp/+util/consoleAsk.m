function answer = consoleAsk(spec)
%consoleAsk Default askFcn: put a guided-bringup question at the prompt.
%
%   answer = tfp.util.consoleAsk(spec)
%
%   The command-line implementation of the questions the guided bringup has
%   to ask because no instrument can answer them: which way the focus moved,
%   whether the operator has seen a table, where an imaging stack is. The
%   GUI substitutes a dialog with the same signature; tests substitute a
%   canned answerer. The same injection idiom as consoleConfirmPower — never
%   a global "assume yes" flag, because that flag gets left on.
%
%   spec:
%     .kind     'yesno'  -> returns logical
%               'choice' -> returns the chosen char option
%               'data'   -> returns a variable fetched by name or loaded
%                           from a .mat path; [] if the operator declines
%     .title    short heading
%     .message  cellstr, printed one line per entry
%     .options  cellstr of choices ('choice' only)
%     .default  default answer on a bare Enter
%
%   See also tfp.util.consoleConfirmPower, tfp.gui.CalibrationSession.

kind    = lower(char(tfp.util.configField(spec, 'kind', 'yesno')));
title   = char(tfp.util.configField(spec, 'title', 'Question'));
message = tfp.util.configField(spec, 'message', {});
if ischar(message), message = {message}; end

fprintf('\n=== %s ===\n', title);
for k = 1:numel(message)
    fprintf('%s\n', message{k});
end

switch kind
    case 'yesno'
        default = logical(tfp.util.configField(spec, 'default', true));
        if default, prompt = '  [Y/n]: '; else, prompt = '  [y/N]: '; end
        reply = strtrim(lower(input(prompt, 's')));
        if isempty(reply)
            answer = default;
        else
            answer = any(strcmp(reply, {'y', 'yes'}));
        end

    case 'choice'
        opts = tfp.util.configField(spec, 'options', {});
        for k = 1:numel(opts)
            fprintf('  %d) %s\n', k, opts{k});
        end
        reply = strtrim(input('  Choice: ', 's'));
        idx = str2double(reply);
        if isfinite(idx) && idx >= 1 && idx <= numel(opts)
            answer = opts{idx};
        else
            answer = char(tfp.util.configField(spec, 'default', ''));
        end

    case 'data'
        % A workspace variable name or a .mat path. Deliberately not an
        % eval of arbitrary text: the two accepted forms are a bare
        % identifier and a readable file.
        reply = strtrim(input('  Variable name or .mat path (blank to cancel): ', 's'));
        answer = [];
        if isempty(reply)
            return
        end
        if isfile(reply)
            loaded = load(reply);
            f = fieldnames(loaded);
            if isscalar(f)
                answer = loaded.(f{1});
            else
                fprintf('  %s holds %d variables: %s\n', reply, numel(f), strjoin(f', ', '));
                pick = strtrim(input('  Which one? ', 's'));
                if isfield(loaded, pick), answer = loaded.(pick); end
            end
        elseif isvarname(reply)
            try
                answer = evalin('base', reply);
            catch ME
                fprintf(2, '  could not read %s from the base workspace: %s\n', ...
                    reply, ME.message);
            end
        else
            fprintf(2, '  ''%s'' is neither a file nor a valid variable name.\n', reply);
        end

    otherwise
        error('tfp:util:consoleAsk:badKind', ...
            'unknown question kind ''%s'' (yesno | choice | data).', kind);
end
end
