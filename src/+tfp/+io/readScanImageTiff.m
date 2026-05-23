function meta = readScanImageTiff(tiffPath)
%readScanImageTiff Uniform metadata reader for ScanImage TIFFs and mock sidecars.
%
%   meta = tfp.io.readScanImageTiff(tiffPath) returns a struct with the
%   LOCKED shape defined by SYNC_EPISODIC.md §6.2 / §9.7:
%
%       meta.numFrames                 uint32
%       meta.numChannels               uint32
%       meta.frameRateHz               double  (NaN if unknown)
%       meta.frameTimestamps_s         Nx1 double (NaN entries if unknown)
%       meta.timestampsAreSynthesised  logical
%       meta.sourceTiff                char  (echo of input path)
%       meta.scanImageVersion          char  ('unknown' / 'mock' if N/A)
%
%   Dispatch
%   --------
%     - `.mat` extension  -> load a struct named `meta` from the file and
%                            return it unchanged (mock sidecar branch).
%     - `.tif` / `.tiff`  -> parse the real ScanImage TIFF, preferring
%                            `scanimage.util.opentif` if available and
%                            falling back to `imfinfo`.
%     - other extensions  -> error tfp:io:readScanImageTiff:unsupportedExtension.
%
%   Errors
%   ------
%     tfp:io:readScanImageTiff:fileNotFound
%     tfp:io:readScanImageTiff:unsupportedExtension
%     tfp:io:readScanImageTiff:badMatSidecar
%     tfp:io:readScanImageTiff:imfinfoFailed
%
%   Warning (one-shot per session)
%   ------------------------------
%     tfp:io:readScanImageTiff:noTimestamps — emitted if neither per-frame
%       timestamps nor frame rate are recoverable from the TIFF.

arguments
    tiffPath (1, :) char
end

if ~isfile(tiffPath)
    error('tfp:io:readScanImageTiff:fileNotFound', ...
        'TIFF/sidecar not found: %s.', tiffPath);
end

[~, ~, ext] = fileparts(tiffPath);
extLower    = lower(ext);

switch extLower
    case '.mat'
        meta = readMatSidecar(tiffPath);
        return
    case {'.tif', '.tiff'}
        meta = readRealTiff(tiffPath);
        return
    otherwise
        error('tfp:io:readScanImageTiff:unsupportedExtension', ...
            'Unsupported file extension ''%s''; expected .mat, .tif, or .tiff.', ext);
end
end

% =========================================================================
% Mock sidecar branch
% =========================================================================

function meta = readMatSidecar(matPath)
%readMatSidecar Load and validate the `meta` struct from a .mat sidecar.
S = load(matPath);
if ~isfield(S, 'meta') || ~isstruct(S.meta)
    error('tfp:io:readScanImageTiff:badMatSidecar', ...
        '.mat sidecar %s must contain a struct variable named ''meta''.', matPath);
end
meta = S.meta;
validateMetaShape(meta, matPath);
end

function validateMetaShape(meta, sourcePath)
%validateMetaShape Verify all locked-shape fields are present.
required = {'numFrames', 'numChannels', 'frameRateHz', ...
            'frameTimestamps_s', 'timestampsAreSynthesised', ...
            'sourceTiff', 'scanImageVersion'};
for k = 1:numel(required)
    if ~isfield(meta, required{k})
        error('tfp:io:readScanImageTiff:badMatSidecar', ...
            '.mat sidecar %s is missing required meta field ''%s''.', ...
            sourcePath, required{k});
    end
end
end

% =========================================================================
% Real TIFF branch
% =========================================================================

function meta = readRealTiff(tiffPath)
%readRealTiff Parse a ScanImage TIFF (or any multi-page TIFF) for metadata.

% Initialise the locked-shape output.
meta = makeBlankMeta(tiffPath);

% Prefer ScanImage's own reader when available.
usedOpentif = false;
if exist('scanimage.util.opentif', 'file')
    try
        meta = readViaOpentif(tiffPath, meta);
        usedOpentif = true;
    catch
        % Fall through to imfinfo path.
        usedOpentif = false;
    end
end

if ~usedOpentif
    meta = readViaImfinfo(tiffPath, meta);
end

% If no per-frame timestamps were recovered, synthesise from frame rate
% (or warn one-shot if even that is unavailable).
if isempty(meta.frameTimestamps_s) || all(isnan(meta.frameTimestamps_s))
    N = double(meta.numFrames);
    if ~isnan(meta.frameRateHz) && meta.frameRateHz > 0 && N > 0
        meta.frameTimestamps_s        = (0:N-1)' / meta.frameRateHz;
        meta.timestampsAreSynthesised = true;
    else
        meta.frameTimestamps_s        = nan(max(N, 0), 1);
        meta.timestampsAreSynthesised = true;
        oneShotNoTimestampsWarning(tiffPath);
    end
end
end

function meta = makeBlankMeta(tiffPath)
meta = struct( ...
    'numFrames',                uint32(0), ...
    'numChannels',              uint32(1), ...
    'frameRateHz',              NaN, ...
    'frameTimestamps_s',        zeros(0, 1), ...
    'timestampsAreSynthesised', false, ...
    'sourceTiff',               char(tiffPath), ...
    'scanImageVersion',         'unknown');
end

function meta = readViaOpentif(tiffPath, meta)
%readViaOpentif Use scanimage.util.opentif if present.
%   ScanImage's opentif signatures vary by version. We defensively extract
%   what we can and fall back to imfinfo for whatever it doesn't provide.
%
%   %VERIFY: exact return-struct shape from scanimage.util.opentif depends
%   on ScanImage version; this code probes optimistically and ignores
%   missing fields.

[~, header, imgInfo] = scanimage.util.opentif(tiffPath); %#ok<ASGLU>

if isstruct(header)
    if isfield(header, 'SI') && isstruct(header.SI)
        SI = header.SI;
        if isfield(SI, 'hRoiManager') && isstruct(SI.hRoiManager) ...
                && isfield(SI.hRoiManager, 'scanFrameRate')
            meta.frameRateHz = double(SI.hRoiManager.scanFrameRate);
        end
        if isfield(SI, 'hChannels') && isstruct(SI.hChannels) ...
                && isfield(SI.hChannels, 'channelSave')
            cs = SI.hChannels.channelSave;
            if ~isempty(cs)
                meta.numChannels = uint32(numel(cs));
            end
        end
        if isfield(SI, 'VERSION_MAJOR')
            major = SI.VERSION_MAJOR;
            minor = '';
            if isfield(SI, 'VERSION_MINOR')
                minor = num2str(SI.VERSION_MINOR);
            end
            meta.scanImageVersion = sprintf('%s.%s', num2str(major), minor);
        end
    end
end

% imgInfo, if returned, often carries frame timestamps.
if exist('imgInfo', 'var') && isstruct(imgInfo) ...
        && isfield(imgInfo, 'frameTimestamps_sec')
    fts = imgInfo.frameTimestamps_sec(:);
    if ~isempty(fts) && all(isfinite(fts))
        meta.frameTimestamps_s        = double(fts);
        meta.timestampsAreSynthesised = false;
    end
end

% Need at least a frame count to be useful; fall back to imfinfo if not.
if meta.numFrames == 0
    info = safeImfinfo(tiffPath);
    nIfd = numel(info);
    C    = double(meta.numChannels);
    if C < 1, C = 1; end
    meta.numFrames = uint32(floor(nIfd / C));
    if ~isempty(info) && isempty(meta.frameTimestamps_s) ...
            && isfield(info(1), 'ImageDescription')
        parsed = parseImageDescription(info);
        meta   = mergeParsed(meta, parsed);
    end
end
end

function meta = readViaImfinfo(tiffPath, meta)
%readViaImfinfo Pure imfinfo fallback path.
info = safeImfinfo(tiffPath);
nIfd = numel(info);
if nIfd == 0
    error('tfp:io:readScanImageTiff:imfinfoFailed', ...
        'imfinfo returned no IFDs for %s.', tiffPath);
end

parsed = parseImageDescription(info);

% Determine channel count.
if ~isnan(parsed.numChannels) && parsed.numChannels > 0
    C = double(parsed.numChannels);
else
    % %VERIFY: defaulting to single-channel when SI.hChannels.channelSave
    % is not present in ImageDescription. ScanImage TIFFs interleave
    % channels frame-by-frame; without channelSave we cannot demultiplex
    % so we assume numChannels == 1.
    C = 1;
end

meta.numChannels = uint32(C);
meta.numFrames   = uint32(floor(nIfd / C));

meta = mergeParsed(meta, parsed);
end

function info = safeImfinfo(tiffPath)
try
    info = imfinfo(tiffPath);
catch ME
    newME = MException('tfp:io:readScanImageTiff:imfinfoFailed', ...
        'imfinfo failed on %s: %s', tiffPath, ME.message);
    newME = addCause(newME, ME);
    throw(newME);
end
end

function meta = mergeParsed(meta, parsed)
if ~isnan(parsed.frameRateHz)
    meta.frameRateHz = parsed.frameRateHz;
end
if ~isempty(parsed.frameTimestamps_s)
    meta.frameTimestamps_s        = parsed.frameTimestamps_s(:);
    meta.timestampsAreSynthesised = false;
end
if ~isempty(parsed.scanImageVersion)
    meta.scanImageVersion = parsed.scanImageVersion;
end
end

% =========================================================================
% ImageDescription parsing
% =========================================================================

function parsed = parseImageDescription(info)
%parseImageDescription Pull ScanImage fields from per-IFD ImageDescriptions.
parsed = struct( ...
    'frameRateHz',       NaN, ...
    'frameTimestamps_s', zeros(0, 1), ...
    'numChannels',       NaN, ...
    'scanImageVersion',  '');

nIfd = numel(info);
fts  = nan(nIfd, 1);

for i = 1:nIfd
    if ~isfield(info(i), 'ImageDescription')
        continue;
    end
    desc = info(i).ImageDescription;
    if isempty(desc) || ~(ischar(desc) || isstring(desc))
        continue;
    end
    desc = char(desc);

    % Per-IFD frame timestamp.
    val = extractScalarKey(desc, 'frameTimestamps_sec');
    if ~isnan(val)
        fts(i) = val;
    end

    % Header-style keys: parse only from the first IFD that has them.
    if i == 1 || isnan(parsed.frameRateHz)
        rate = extractScalarKey(desc, 'SI.hRoiManager.scanFrameRate');
        if ~isnan(rate)
            parsed.frameRateHz = rate;
        end
    end

    if i == 1 || isnan(parsed.numChannels)
        chans = extractChannelSave(desc);
        if ~isnan(chans)
            parsed.numChannels = chans;
        end
    end

    if i == 1 || isempty(parsed.scanImageVersion)
        verStr = extractScanImageVersion(desc);
        if ~isempty(verStr)
            parsed.scanImageVersion = verStr;
        end
    end
end

if any(~isnan(fts))
    parsed.frameTimestamps_s = fts;
end
end

function val = extractScalarKey(desc, key)
%extractScalarKey Pull `key = number` from a ScanImage ImageDescription.
val = NaN;
% Allow either `key = value` or `key=value` with surrounding whitespace.
pat   = ['(^|\n)\s*', regexptranslate('escape', key), '\s*=\s*([-+0-9.eE]+)'];
token = regexp(desc, pat, 'tokens', 'once');
if isempty(token) || numel(token) < 2
    return;
end
num = str2double(token{2});
if isnan(num)
    return;
end
val = num;
end

function n = extractChannelSave(desc)
%extractChannelSave Parse SI.hChannels.channelSave (scalar or bracket list).
n   = NaN;
pat = '(^|\n)\s*SI\.hChannels\.channelSave\s*=\s*([^\n]+)';
tok = regexp(desc, pat, 'tokens', 'once');
if isempty(tok) || numel(tok) < 2
    return;
end
rhs = strtrim(tok{2});
if startsWith(rhs, '[') && endsWith(rhs, ']')
    inner = rhs(2:end-1);
    inner = strrep(inner, ';', ' ');
    inner = strrep(inner, ',', ' ');
    parts = strtrim(strsplit(inner));
    parts = parts(~cellfun(@isempty, parts));
    if isempty(parts)
        return;
    end
    n = numel(parts);
else
    if ~isnan(str2double(rhs))
        n = 1;
    end
end
end

function verStr = extractScanImageVersion(desc)
%extractScanImageVersion Recover Software/version string from ImageDescription.
verStr = '';

% Try `SI.VERSION_MAJOR = N` and `SI.VERSION_MINOR = M`.
major = extractScalarKey(desc, 'SI.VERSION_MAJOR');
minor = extractScalarKey(desc, 'SI.VERSION_MINOR');
if ~isnan(major)
    if ~isnan(minor)
        verStr = sprintf('%g.%g', major, minor);
    else
        verStr = sprintf('%g', major);
    end
    return;
end

% Fall back to a free-form Software= line.
pat = '(^|\n)\s*Software\s*=\s*([^\n]+)';
tok = regexp(desc, pat, 'tokens', 'once');
if ~isempty(tok) && numel(tok) >= 2
    verStr = strtrim(tok{2});
end
end

% =========================================================================
% Warning helper
% =========================================================================

function oneShotNoTimestampsWarning(tiffPath)
%oneShotNoTimestampsWarning Emit warning at most once per MATLAB session.
persistent warnedNoTimestamps
if isempty(warnedNoTimestamps) || ~warnedNoTimestamps
    warning('tfp:io:readScanImageTiff:noTimestamps', ...
        'No per-frame timestamps or frame rate recoverable from %s; frameTimestamps_s left as NaN.', ...
        tiffPath);
    warnedNoTimestamps = true;
end
end
