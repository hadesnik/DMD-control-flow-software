%ALPPATHS  Locate the installed ViALUX ALP SDK and prepare loadlibrary.
%
% Every alp* bench script needs the same three things: the DLL, a matching
% header, and a library alias. Hard-coding them meant a single SDK version
% change broke five scripts at once, each with an unhelpful "The specified
% module could not be found" from loadlibrary. This resolves them instead.
%
%   [dll, hdr, alias] = alpPaths()        % newest installed SDK
%   [dll, hdr, alias] = alpPaths('4.1')   % force a specific version
%
% Preference order is newest-first, with the repo's bundled DLL as a last
% resort. Also sets MW_MINGW64_LOC, because loadlibrary compiles a thunk from
% the header and needs a C compiler -- on this PC only R2020b has one.
%
% Header and DLL must MATCH. Loading a 4.3 DLL against the 4.1 header (or vice
% versa) fails in ways that look like device faults rather than a version
% mismatch, so the two always travel together here.

function [dllPath, hdrPath, alias] = alpPaths(preferVersion)

if nargin < 1, preferVersion = ''; end

repo = fileparts(fileparts(mfilename('fullpath')));   % repo root

% Candidates, newest first. Built as a struct array rather than a cell matrix:
% a cell literal spanning continuation lines silently flattens into one row,
% which scrambles the columns without erroring.
cand = @(v,d,h,a,s) struct('ver',v, 'dll',d, 'hdr',h, 'alias',a, 'desc',s);

C = [ ...
    cand('4.3', ...
         'C:\Program Files\ALP-4.3\ALP-4.3 API\x64\alp4395.dll', ...
         'C:\Program Files\ALP-4.3\ALP-4.3 API\alp.h', ...
         'alp4395', 'installed ALP-4.3 SDK (x64)'), ...
    cand('4.2', ...
         'C:\Program Files\ALP-4.2\ALP-4.2 high-speed API\x64\alpV42.dll', ...
         fullfile(repo, 'vendor', 'alp', 'official', 'alp.h'), ...
         'alpV42', 'installed ALP-4.2 SDK (x64)'), ...
    cand('4.1', ...
         'C:\Program Files\ALP-4.1\ALP-4.1 high-speed API\x64\alpD41.dll', ...
         fullfile(repo, 'vendor', 'alp', 'official-4.1', 'alp.h'), ...
         'alpD41', 'installed ALP-4.1 SDK (x64)'), ...
    cand('4.3-vendored', ...
         fullfile(repo, 'vendor', 'alp', 'reference', 'parot-alptool', 'alp4395.dll'), ...
         fullfile(repo, 'vendor', 'alp', 'official', 'alp.h'), ...
         'alp4395', 'repo-bundled ALP-4.3 DLL (older build, no AlpSeqPutEx)') ...
    ];

% --- MinGW: loadlibrary needs a compiler to build the thunk ---------------
mingw = 'C:\ProgramData\MATLAB\SupportPackages\R2020b\3P.instrset\mingw_w64.instrset';
if isfolder(mingw) && isempty(getenv('MW_MINGW64_LOC'))
    setenv('MW_MINGW64_LOC', mingw);
end

% --- Pick ----------------------------------------------------------------
tried = {};
for k = 1:numel(C)
    c = C(k);
    if ~isempty(preferVersion) && ~strcmp(c.ver, preferVersion), continue; end
    if isfile(c.dll) && isfile(c.hdr)
        dllPath = c.dll; hdrPath = c.hdr; alias = c.alias;
        return
    end
    if isfile(c.dll) && ~isfile(c.hdr)
        tried{end+1} = sprintf('  %-14s DLL found but header missing: %s', c.ver, c.hdr); %#ok<AGROW>
    else
        tried{end+1} = sprintf('  %-14s no DLL at %s', c.ver, c.dll); %#ok<AGROW>
    end
end

if isempty(preferVersion)
    error('tfp:scripts:alpPaths:noSdk', ...
        ['No usable ALP SDK found. Checked:\n%s\n\n' ...
         'Install the ViALUX ALP Controller Suite, or pass an explicit\n' ...
         'version, e.g. alpPaths(''4.1'').'], strjoin(tried, newline));
else
    error('tfp:scripts:alpPaths:versionNotFound', ...
        'ALP %s was requested but is not usable. Checked:\n%s', ...
        preferVersion, strjoin(tried, newline));
end
end
