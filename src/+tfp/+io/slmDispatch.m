function reply = slmDispatch(slm, ctx, op, payload)
%slmDispatch Route a command to an SLM device and return a reply struct.
%
%   reply = tfp.io.slmDispatch(slm, ctx, op, payload)
%
%   Implements the shared SLM command dispatcher used by both the loopback
%   path inside RemoteSLM and the server-side loop in slm_pc_server.m.
%   Each call is wrapped in a try/catch so callers always receive a struct
%   reply; network-level error handling is the caller's responsibility.
%
%   Inputs:
%     slm     - Any concrete tfp.hardware.SLM subclass (MockSLM,
%               Meadowlark1024_SLM, …).
%     ctx     - Context struct with fields:
%                 .params  - CGH parameter struct from
%                            tfp.patterns.threeDShot.defaultParams, with the
%                            three validation fields ALSO copied in:
%                              maxCells           (default 20)
%                              addressableRadiusUm (default Inf)
%                              minSpacingUm        (default 0)
%                            These are read by tfp.util.validateSLMTargets
%                            from ctx.params, so the orchestrator MUST copy
%                            them from slmConfig into mergedParams before
%                            building ctx.
%                 .calib   - Calibration struct from
%                            tfp.patterns.threeDShot.loadSLMScanCalibration.
%                 .effMap  - Efficiency-map struct from
%                            tfp.patterns.threeDShot.loadEfficiencyMap.
%     op      - char, one of:
%                 'projectTargets' — compute CGH and present pattern.
%                 'blank'          — blank the SLM.
%                 'slmPower'       — turn SLM power on/off.
%                 'ping'           — query status.
%                 'shutdown'       — cleanup the SLM device.
%                 (anything else)  — returns ok=false, error='unknown op'.
%     payload - Depends on op:
%                 'projectTargets': N×2 ScanImage centroids (µm), or N×3
%                                   if calib.type=='identity' they pass
%                                   through mapScanToSLM unchanged.
%                 'slmPower':       logical scalar.
%                 others:          ignored.
%
%   Output:
%     reply - struct with at minimum .op and .ok.  Additional fields
%             per-op (see below).
%
%   Error handling:
%     Any exception thrown during an op is caught and returned as
%       struct('op', op, 'ok', false, 'error', ME.message).
%     Unknown op: struct('op', op, 'ok', false, 'error', 'unknown op').
%
%   See also: tfp.hardware.RemoteSLM, tfp.patterns.threeDShot.composeHologram,
%             tfp.util.validateSLMTargets.

try
    switch op

        % ----------------------------------------------------------------- %
        case 'projectTargets'
            % Step 1: map ScanImage centroids → SLM sample-plane coordinates.
            slm_xyz = tfp.patterns.threeDShot.mapScanToSLM(payload, ctx.calib);

            % Step 2: validate (cap count, radius, spacing).
            %   validateSLMTargets reads maxCells/addressableRadiusUm/minSpacingUm
            %   from ctx.params (the merged params struct).
            slm_xyz = tfp.util.validateSLMTargets(slm_xyz, ctx.params, 'slmDispatch');

            % Step 3: look up per-cell efficiency at each target.
            eta = tfp.patterns.threeDShot.efficiencyAtTargets(slm_xyz, ctx.effMap);

            % Step 4: compute hologram.
            [mask, ~, info] = tfp.patterns.threeDShot.composeHologram( ...
                slm_xyz, ctx.params, struct('efficiency', eta));

            % Step 5: send to SLM.
            slm.loadPhaseMask(mask);
            slm.present();

            reply = struct( ...
                'op',                      'projectTargets', ...
                'ok',                      true, ...
                'nAccepted',               size(slm_xyz, 1), ...
                'perCellDeliveredFraction', info.perCellDeliveredFraction, ...
                'etaEffective',             info.etaEffective);

        % ----------------------------------------------------------------- %
        case 'blank'
            slm.blank();
            reply = struct('op', 'blank', 'ok', true);

        % ----------------------------------------------------------------- %
        case 'slmPower'
            slm.slmPower(payload);
            reply = struct('op', 'slmPower', 'ok', true);

        % ----------------------------------------------------------------- %
        case 'ping'
            reply = struct('op', 'ping', 'ok', true, 'status', slm.getStatus());

        % ----------------------------------------------------------------- %
        case 'shutdown'
            slm.cleanup();
            reply = struct('op', 'shutdown', 'ok', true, 'shutdown', true);

        % ----------------------------------------------------------------- %
        otherwise
            reply = struct('op', op, 'ok', false, 'error', 'unknown op');

    end

catch ME
    reply = struct('op', op, 'ok', false, 'error', ME.message);
end
end
