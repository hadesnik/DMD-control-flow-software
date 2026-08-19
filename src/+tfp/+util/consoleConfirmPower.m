function ok = consoleConfirmPower(spec)
%consoleConfirmPower Default confirmFcn: render a power step and ask at the prompt.
%
%   ok = tfp.util.consoleConfirmPower(spec)
%
%   The command-line implementation of the informed-consent gate that
%   tfp.hardware.LaserPowerController applies before any power increase. The
%   GUI substitutes a uiconfirm closure with the same signature; tests
%   substitute @(spec) true or @(spec) false. Same injection idiom as
%   tfp.hardware.ManualZStage's promptFcn — never a global flag, because a
%   global "skip confirmations" flag is exactly the thing that gets left on.
%
%   A 'danger' spec defaults to NO: bare Enter declines. Anything else
%   defaults to yes on bare Enter.
%
%   See also tfp.util.formatPowerConfirmSpec, tfp.hardware.LaserPowerController.

txt = tfp.util.formatPowerConfirmSpec(spec);
fprintf('\n%s\n', strjoin(txt, char(10)));

if spec.defaultAnswer
    prompt = '  Proceed? [Y/n]: ';
else
    prompt = '  Proceed? [y/N]: ';
end

answer = strtrim(lower(input(prompt, 's')));
if isempty(answer)
    ok = logical(spec.defaultAnswer);
else
    ok = any(strcmp(answer, {'y', 'yes'}));
end

if ok
    fprintf('  -> proceeding.\n');
else
    fprintf('  -> declined; no output made.\n');
end
end
