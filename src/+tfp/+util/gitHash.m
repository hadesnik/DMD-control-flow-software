function h = gitHash(shortForm)
%gitHash Best-effort commit hash of this repository, for provenance stamping.
%
%   h = tfp.util.gitHash()        % full 40-char hash, or '' if unavailable
%   h = tfp.util.gitHash(true)    % abbreviated
%
%   Never throws and never blocks: a missing git, a missing .git directory, or
%   a detached checkout all return ''. Provenance is worth recording but is
%   never worth failing a calibration over.
%
%   A '-dirty' suffix is appended when the working tree has uncommitted
%   changes, because a bare hash from a dirty tree is a provenance record that
%   points at code which was not the code that ran.

if nargin < 1 || isempty(shortForm), shortForm = false; end
h = '';

repoRoot = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
if ~isfolder(fullfile(repoRoot, '.git'))
    return
end

if shortForm
    revArg = '--short';
else
    revArg = '';
end

try
    [status, out] = system(sprintf('git -C "%s" rev-parse %s HEAD 2>/dev/null', ...
        repoRoot, revArg));
    if status ~= 0
        return
    end
    h = strtrim(out);
    [dirtyStatus, dirtyOut] = system(sprintf( ...
        'git -C "%s" status --porcelain 2>/dev/null', repoRoot));
    if dirtyStatus == 0 && ~isempty(strtrim(dirtyOut))
        h = [h '-dirty'];
    end
catch
    h = '';
end
end
