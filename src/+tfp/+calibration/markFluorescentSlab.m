function marks = markFluorescentSlab(dmd, slm, daq, config, options)
%markFluorescentSlab Burn or bleach a dz-encoded mark grid into a slab.
%
%   marks = tfp.calibration.markFluorescentSlab(dmd, slm, daq, config, options)
%
%   The DIRECT z-calibration methods (the lab's 3D-SHOT two-step protocol,
%   adapted): project one small DMD spot per SLM defocus value onto a
%   THICK fluorescent slab and mark it — either by burning (short, high
%   power) or by photobleaching (long dwell at moderate power, the
%   fallback when the DMD arm can't reach burn threshold). The LATERAL
%   GRID POSITION ENCODES WHICH dz made the mark, so the follow-up
%   (tfp.calibration.locateMarksInStack on an operator-acquired ETL
%   z-stack) can map each dark mark back to its commanded defocus with no
%   bookkeeping ambiguity.
%
%   options:
%     .mode          'burn' | 'bleach' (REQUIRED — the two differ only in
%                    power/dwell defaults, but the choice must be explicit
%                    because burn is the hardware-risk direction)
%     .dzCmdUm       defocus per mark (default -40:20:40)
%     .gridOriginPx  [col row] of the first mark (default chip centre
%                    minus half the grid extent)
%     .gridStepPx    lateral spacing between marks (default 120 px — far
%                    enough apart that a defocused mark can't be confused
%                    with its neighbour)
%     .spotRadiusPx  mark spot radius (default 6)
%     .powerMw       default: burn 50, bleach 10
%     .dwellS        default: burn 0.5, bleach 30
%
%   Returns the mark LEDGER (struct array, one per mark):
%     .dzCmdUm, .dmdCoords [col row], .mode, .powerMw, .dwellS, .timestamp
%   Persist it with the session and feed it to locateMarksInStack.
%
%   Safety: every pattern passes DMD.assertPatternsSafe on load, and
%   tfp.util.assertSlmPowerSafe runs per mark (a single small spot passes;
%   the call is here so nobody "temporarily" turns the grid into a patch).

if nargin < 5 || isempty(options)
    options = struct();
end
if ~isfield(options, 'mode')
    error('tfp:calibration:markFluorescentSlab:missingMode', ...
        'options.mode is required: ''burn'' or ''bleach''.');
end
mode = lower(char(options.mode));
switch mode
    case 'burn'
        defaultPowerMw = 50;
        defaultDwellS  = 0.5;
    case 'bleach'
        defaultPowerMw = 10;
        defaultDwellS  = 30;
    otherwise
        error('tfp:calibration:markFluorescentSlab:badMode', ...
            'options.mode must be ''burn'' or ''bleach'' (got ''%s'').', mode);
end

dzCmdUm      = double(tfp.util.configField(options, 'dzCmdUm', -40:20:40));
gridStepPx   = double(tfp.util.configField(options, 'gridStepPx', 120));
spotRadiusPx = double(tfp.util.configField(options, 'spotRadiusPx', 6));
powerMw      = double(tfp.util.configField(options, 'powerMw', defaultPowerMw));
dwellS       = double(tfp.util.configField(options, 'dwellS', defaultDwellS));

N = numel(dzCmdUm);
defaultOrigin = [round(dmd.nCols / 2) - round(gridStepPx * (N - 1) / 2), ...
                 round(dmd.nRows / 2)];
gridOrigin = double(tfp.util.configField(options, 'gridOriginPx', defaultOrigin));

% --- Prepare the SLM sequence ----------------------------------------
sys = tfp.optics.buildDefocusSys(config);
slm.prepareDefocusSequence(dzCmdUm, sys);
slm.armSequenceTrigger('software');

% --- One continuous DAQ session provides the clocked AO dwell --------
sampleRate = 10000;
daqCfg     = tfp.util.configField(config, 'daq', struct());
sampleRate = double(tfp.util.configField(daqCfg, 'sampleRate', sampleRate));
aoIdx      = double(tfp.util.configField(daqCfg, 'aoChannelIdx', 1));
sessionCfg = struct('sampleRate', sampleRate, 'aiChannels', [], ...
    'aoChannels', aoIdx, 'diLines', {{}}, 'doLines', {{}}, ...
    'frameClockLine', '');
daq.startContinuousSession(sessionCfg);
cleanupSession = onCleanup(@() stopSessionQuietly(daq)); %#ok<NASGU>

marks = struct('dzCmdUm', {}, 'dmdCoords', {}, 'mode', {}, ...
    'powerMw', {}, 'dwellS', {}, 'timestamp', {});

for k = 1:N
    coords = [gridOrigin(1) + (k - 1) * gridStepPx, gridOrigin(2)];
    pattern = tfp.patterns.singleSpot(dmd, coords, spotRadiusPx);

    tfp.util.assertSlmPowerSafe(pattern, powerMw, config);

    seqOpts.exposureUs = round(dwellS * 1e6);
    seqOpts.darkTimeUs = 0;
    dmd.loadPatternSequence(pattern, seqOpts);
    dmd.armSequence();

    slm.advanceToIndex(k);
    dmd.softTrigger();

    % Hold the modulator open for the dwell via clocked AO, then return
    % to 0 V (waveform carries its own trailing zero).
    nDwell   = max(1, round(dwellS * sampleRate));
    waveform = [powerMw * ones(nDwell, 1); 0];   % TODO C2: powerLUT volts
    daq.queueClockedAO(waveform, sampleRate, 'immediate');
    pause(dwellS);

    marks(end+1) = struct('dzCmdUm', dzCmdUm(k), 'dmdCoords', coords, ...
        'mode', mode, 'powerMw', powerMw, 'dwellS', dwellS, ...
        'timestamp', datetime('now')); %#ok<AGROW>
    fprintf('[markFluorescentSlab] %s mark %d/%d at [%d %d], dz %+g um\n', ...
        mode, k, N, coords(1), coords(2), dzCmdUm(k));
end
end

% --- Local helper ---

function stopSessionQuietly(daq)
try
    if daq.isRunning
        daq.stopContinuousSession();
    end
catch
end
end
