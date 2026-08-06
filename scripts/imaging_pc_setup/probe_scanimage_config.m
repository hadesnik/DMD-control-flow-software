function probe_scanimage_config()
%probe_scanimage_config  Report this imaging PC's live ScanImage configuration.
%
% Implements TASKS.md T-EP-5c. Run on the IMAGING PC, in the MATLAB session that
% is running ScanImage, with `hSI` in the base workspace.
%
%   >> probe_scanimage_config
%
% STRICTLY READ-ONLY. It reads properties and prints them. It never assigns to
% hSI, never starts or stops an acquisition, and never touches logFileCounter.
% Safe to run at any time, including mid-session (though group 2 values are
% most meaningful when ScanImage is idle and configured for the experiment).
%
% Why this exists: the DAQ PC drives all timing but cannot see any of these
% values. Several contracts in docs/SYNC_EPISODIC.md depend on them —
% especially which trigger terminal to wire the per-trial start-acq TTL into
% (group 2) and how per-trial TIFF paths are derived (group 3). Paste this
% output into the rig log, or send it to whoever is working on the DAQ PC.
%
% Property names below were confirmed by reading the installed ScanImage
% source (SI2019bR0) on 2026-08-05; citations appear inline. The probe still
% reports MISSING rather than erroring if a property is absent, so it stays
% useful if this PC is ever upgraded to a different ScanImage version.
%
% See also: imaging_pc_config, SIStreamSetup, test_msocket_link.

fprintf('\n');
fprintf('=========================================================\n');
fprintf(' probe_scanimage_config   %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
fprintf('=========================================================\n');

% --- hSI must exist in the BASE workspace (ScanImage puts it there) ---------
if evalin('base', 'exist(''hSI'', ''var'')') ~= 1
    fprintf('\n  hSI not found in the base workspace.\n\n');
    fprintf('  Start ScanImage first, then re-run this script from the same\n');
    fprintf('  MATLAB session. Groups 1-5 all read live ScanImage state.\n\n');
    fprintf('  Group 6 (msocket) does not need ScanImage — running it now:\n');
    section('6. msocket / network config (no ScanImage needed)');
    probeMsocket();
    fprintf('\n');
    return;
end
hSI = evalin('base', 'hSI');

% ---------------------------------------------------------------------------
section('1. Version and identity');
% Confirmed: hSI.acqState — +scanimage/SI.m:42, one of
% {'focus' 'grab' 'loop' 'idle' 'point'}.
show('VERSION_MAJOR',      hSI, 'VERSION_MAJOR');
show('VERSION_MINOR',      hSI, 'VERSION_MINOR');
show('VERSION_COMMIT',     hSI, 'VERSION_COMMIT');
show('acqState',           hSI, 'acqState');
showValue('hScan2D class', safeClass(hSI, 'hScan2D'));
showValue('scanner name',  safeGet2(hSI, 'hScan2D', 'name'));

if isprop(hSI, 'acqState') && ~strcmpi(hSI.acqState, 'idle')
    note(sprintf(['ScanImage is "%s", not idle. Group 2 values may be ' ...
        'mid-acquisition state.'], hSI.acqState));
end

% ---------------------------------------------------------------------------
section('2. Episodic external-trigger prerequisites (SYNC_EPISODIC.md 12.1-12.2)');
% Confirmed: hSI.extTrigEnable            — +scanimage/SI.m:20
%            hScan2D.trigAcqInTerm        — +scanimage/+components/Scan2D.m:44
%            hScan2D.trigAcqEdge          — Scan2D.m:47
%            hScan2D.trigAcqInTermAllowed — Scan2D.m:150
%            hScan2D.framesPerAcq         — Scan2D.m:121
show('hSI.extTrigEnable',            hSI, 'extTrigEnable');
show2('hScan2D.trigAcqInTerm',       hSI, 'hScan2D', 'trigAcqInTerm');
show2('hScan2D.trigAcqEdge',         hSI, 'hScan2D', 'trigAcqEdge');
show2('hScan2D.trigAcqInTermAllowed', hSI, 'hScan2D', 'trigAcqInTermAllowed');

% framesPerAcq exists at BOTH levels: SI.m:126 (initialised nan) and
% Scan2D.m:121 ("number of frames per acquisition trigger"). Report both so
% the operator sets whichever is actually in effect.
show('hSI.framesPerAcq',      hSI, 'framesPerAcq');
show2('hScan2D.framesPerAcq', hSI, 'hScan2D', 'framesPerAcq');

note(['^ trigAcqInTermAllowed is the list the DAQ PC needs: the start-acq ' ...
      'TTL must be wired to one of those terminals, and trigAcqInTerm set to it.']);

% ---------------------------------------------------------------------------
section('3. Per-trial TIFF path derivation (SYNC_EPISODIC.md 9.2, 9.5)');
% Confirmed: logFilePath Scan2D.m:55, logFileStem Scan2D.m:88,
%            logFileCounter Scan2D.m:89, logFullFilename Scan2D.m:237.
show2('hScan2D.logFilePath',     hSI, 'hScan2D', 'logFilePath');
show2('hScan2D.logFileStem',     hSI, 'hScan2D', 'logFileStem');
show2('hScan2D.logFileCounter',  hSI, 'hScan2D', 'logFileCounter');
show2('hScan2D.logFullFilename', hSI, 'hScan2D', 'logFullFilename');
show2('hScan2D.logFramesPerFile',hSI, 'hScan2D', 'logFramesPerFile');

% The acq counter does NOT auto-advance unconditionally. SI.m:993 guards it:
%     if obj.hChannels.loggingEnable
%         obj.hScan2D.logFileCounter = obj.hScan2D.logFileCounter + 1;
% (same guard again at SI.m:1501 for the abort path, grab/loop only).
% With logging disabled the counter is frozen and every trial would derive
% the SAME path -- silently overwriting, since 9.5 derives paths by counter
% arithmetic rather than reading the disk. Check it explicitly.
% There is no logFileAutoIncrement property on this ScanImage version.
show2('hChannels.loggingEnable', hSI, 'hChannels', 'loggingEnable');
if isprop(hSI, 'hChannels') && isprop(hSI.hChannels, 'loggingEnable') ...
        && ~hSI.hChannels.loggingEnable
    result('FAIL', 'acq counter will advance?', ...
        'NO -- loggingEnable is false, so logFileCounter is frozen (SI.m:993)');
end
show2('hChannels.channelSave', hSI, 'hChannels', 'channelSave');

% Pad width 5 confirmed: +scanimage/+components/Photostim.m:2254 builds
% sprintf('_%05d', logFileCounter). Same convention in
% IntegrationRoiManager.m:155 and MotionManager.m:1627.
stem    = safeGet2(hSI, 'hScan2D', 'logFileStem');
pathStr = safeGet2(hSI, 'hScan2D', 'logFilePath');
counter = safeGet2(hSI, 'hScan2D', 'logFileCounter');
if ischar(stem) && ischar(pathStr) && isnumeric(counter) && isscalar(counter)
    predicted = fullfile(pathStr, sprintf('%s_%05d.tif', stem, counter));
    showValue('=> next TIFF (predicted)', predicted);
    if exist(predicted, 'file') == 2
        note('That file ALREADY EXISTS — counter may not have advanced yet.');
    end
else
    showValue('=> next TIFF (predicted)', '(cannot derive — see MISSING above)');
end
note(['Pad width 5 confirmed in SI2019bR0 source (Photostim.m:2254). ' ...
      'Matches acqNumWidth_ = 5 locked in SYNC_EPISODIC.md 9.2.']);

% ---------------------------------------------------------------------------
section('4. Frame rate (SYNC_EPISODIC.md 6.4)');
% Confirmed: hRoiManager.scanFrameRate — +scanimage/+components/RoiManager.m:25
% (dependent on scanFramePeriod). Legacy fallback lives on hScan2D.
show2('hRoiManager.scanFrameRate',   hSI, 'hRoiManager', 'scanFrameRate');
show2('hRoiManager.scanFramePeriod', hSI, 'hRoiManager', 'scanFramePeriod');
show2('hScan2D.scanFrameRate (legacy fallback)', hSI, 'hScan2D', 'scanFrameRate');
show2('hRoiManager.scanZoomFactor',  hSI, 'hRoiManager', 'scanZoomFactor');
show2('hRoiManager.linesPerFrame',   hSI, 'hRoiManager', 'linesPerFrame');
show2('hRoiManager.pixelsPerLine',   hSI, 'hRoiManager', 'pixelsPerLine');
show2('hRoiManager.mroiEnable',      hSI, 'hRoiManager', 'mroiEnable');

% framesPerTrial and trialTimeoutS are computed on the DAQ PC from
% config.imaging.frameRate. If that config value disagrees with the live
% scanFrameRate here, every trial asks ScanImage for the wrong frame count
% and the episodic cross-check drifts. Compare explicitly.
liveRate = safeGet2(hSI, 'hRoiManager', 'scanFrameRate');
if isnumeric(liveRate) && isscalar(liveRate) && isfinite(liveRate)
    note(sprintf(['Live frame rate is %.4f Hz. Whoever sets config.imaging.' ...
        'frameRate on the DAQ PC must match THIS, not a nominal 30.'], liveRate));
end

% ---------------------------------------------------------------------------
section('5. ROI integration (live F-streaming path)');

% si_frame_callback is SINGLE-PLANE ONLY (see its header). frameAcquired
% fires once per frame/slice (SI.m:1080), but integration values finalize
% per VOLUME -- so on an N-slice stack the callback sends N duplicate packets
% per volume with non-contiguous frame indices. This is a silent data-quality
% failure, not a crash, so check it up front.
nSlices = safeGet2(hSI, 'hStackManager', 'numSlices');
showValue('hStackManager.numSlices', nSlices);
if isnumeric(nSlices) && isscalar(nSlices) && nSlices > 1
    result('FAIL', 'single-plane required', sprintf( ...
        ['%d slices configured -- si_frame_callback would send %d duplicate ' ...
         'packets per volume. Set numSlices = 1 before F-streaming.'], ...
        nSlices, nSlices));
end
% Confirmed: getIntegrationValues -> [intRois, values, timestamps, framenumbers]
% at +scanimage/+components/IntegrationRoiManager.m:506. Returns [] for all
% four when no integration ROIs are configured.
if ~isprop(hSI, 'hIntegrationRoiManager')
    result('MISSING', 'hIntegrationRoiManager', 'ROI integration unavailable');
else
    hIrm = hSI.hIntegrationRoiManager;
    show('hIntegrationRoiManager.enable', hIrm, 'enable');

    nRois = NaN;
    try
        rg = hIrm.roiGroup;
        if ~isempty(rg) && isprop(rg, 'rois')
            nRois = numel(rg.rois);
        end
    catch
    end
    showValue('integration ROIs defined', nRois);

    try
        [~, F, ts, fn] = hIrm.getIntegrationValues();
        if isempty(F)
            result('PASS', 'getIntegrationValues()', ...
                'callable, returned empty (expected when idle / no ROIs)');
        else
            result('PASS', 'getIntegrationValues()', sprintf( ...
                '%d value(s), frame %g, t=%g s', numel(F), fn(1), ts(1)));
        end
    catch ME
        result('FAIL', 'getIntegrationValues()', ME.message);
    end
end
note(['si_frame_callback streams these back to the DAQ PC on port 3044. ' ...
      'Zero ROIs here is fine until integration ROIs are drawn.']);

% ---------------------------------------------------------------------------
section('6. msocket / network config');
probeMsocket();

% ---------------------------------------------------------------------------
fprintf('\n');
fprintf('---------------------------------------------------------\n');
fprintf(' Done. Anything marked MISSING is a genuine gap: either a\n');
fprintf(' different ScanImage version, or a property that moved.\n');
fprintf(' Send groups 2 and 3 to whoever is working on the DAQ PC.\n');
fprintf('---------------------------------------------------------\n\n');
end

% ===========================================================================
% Probes
% ===========================================================================

function probeMsocket()
%probeMsocket Report the resolved imaging_pc_config settings and msocket state.
try
    cfg = imaging_pc_config();
catch ME
    result('FAIL', 'imaging_pc_config()', ME.message);
    return;
end
showValue('msocketPath', cfg.msocketPath);
showValue('scopePcIp (DAQ PC)', cfg.scopePcIp);
showValue('controlPort', cfg.controlPort);
showValue('streamPort',  cfg.streamPort);
showValue('roiPort',     cfg.roiPort);

if isfolder(cfg.msocketPath)
    result('PASS', 'msocketPath', 'folder exists');
else
    result('FAIL', 'msocketPath', 'folder does NOT exist — fix imaging_pc_config_local.m');
end

% msocket ships both a .m help stub and a .mexw64; `which` shows which wins.
fns = {'mssend', 'msrecv', 'msconnect', 'msclose'};
for k = 1:numel(fns)
    w = which(fns{k});
    if isempty(w)
        result('FAIL', fns{k}, 'not on the MATLAB path');
    else
        result('PASS', fns{k}, w);
    end
end
end

% ===========================================================================
% Output helpers  (printResult idiom, cf. scripts/verify_DLP650LNIR_DMD.m)
% ===========================================================================

function section(title)
fprintf('\n--- %s\n', title);
end

function result(status, label, msg)
fprintf('[%-7s] %-38s %s\n', status, label, msg);
end

function note(msg)
fprintf('           %s\n', wrapNote(msg));
end

function showValue(label, value)
fprintf('[%-7s] %-38s %s\n', 'VALUE', label, fmt(value));
end

function show(label, obj, propName)
%show Print obj.propName, or MISSING if the property does not exist.
if isprop(obj, propName)
    try
        fprintf('[%-7s] %-38s %s\n', 'VALUE', label, fmt(obj.(propName)));
    catch ME
        result('FAIL', label, sprintf('read threw: %s', ME.message));
    end
else
    result('MISSING', label, 'property not present on this ScanImage version');
end
end

function show2(label, obj, subName, propName)
%show2 Print obj.subName.propName, or MISSING at whichever level is absent.
if ~isprop(obj, subName)
    result('MISSING', label, sprintf('no such sub-object: %s', subName));
    return;
end
try
    sub = obj.(subName);
catch ME
    result('FAIL', label, ME.message);
    return;
end
show(label, sub, propName);
end

function c = safeClass(obj, subName)
if isprop(obj, subName)
    try
        c = class(obj.(subName));
        return;
    catch
    end
end
c = '(unavailable)';
end

function v = safeGet2(obj, subName, propName)
v = [];
if ~isprop(obj, subName), return; end
try
    sub = obj.(subName);
    if isprop(sub, propName)
        v = sub.(propName);
    end
catch
end
end

function s = fmt(v)
%fmt Render a property value as a single readable line.
if ischar(v)
    if isempty(v)
        s = '(empty string)';
    else
        s = v;
    end
elseif isempty(v)
    s = '(empty)';
elseif islogical(v) && isscalar(v)
    if v, s = 'true'; else, s = 'false'; end
elseif isnumeric(v) && isscalar(v)
    s = num2str(v);
elseif isnumeric(v) || islogical(v)
    s = mat2str(v);
elseif iscellstr(v) %#ok<ISCLSTR>
    s = strjoin(v, ', ');
elseif iscell(v)
    s = sprintf('<%s cell>', mat2str(size(v)));
else
    s = sprintf('<%s>', class(v));
end
% Keep one value on one line.
s = strtrim(regexprep(s, '\s+', ' '));
if numel(s) > 200
    s = [s(1:197) '...'];
end
end

function out = wrapNote(msg)
%wrapNote Soft-wrap a note to keep console output readable.
msg = strtrim(regexprep(msg, '\s+', ' '));
width = 66;
if numel(msg) <= width
    out = msg;
    return;
end
words = strsplit(msg, ' ');
lines = {};
cur = '';
for k = 1:numel(words)
    if isempty(cur)
        cand = words{k};
    else
        cand = [cur ' ' words{k}]; %#ok<AGROW>
    end
    if numel(cand) > width
        lines{end+1} = cur; %#ok<AGROW>
        cur = words{k};
    else
        cur = cand;
    end
end
if ~isempty(cur)
    lines{end+1} = cur;
end
out = strjoin(lines, sprintf('\n           '));
end
