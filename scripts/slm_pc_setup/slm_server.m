function slm_server(configOverrides)
%slm_server Persistent Meadowlark mask server — runs on the SLM PC.
%
%   slm_server()                  % use slm_pc_config defaults
%   slm_server(struct('port', 3046))
%
%   The SLM PC (Windows, PCIe Blink controller, repo clone) runs this loop
%   unattended. NOTE THE DIRECTION REVERSAL: everywhere else in the lab the
%   DAQ PC is the msocket server; HERE THE SLM PC LISTENS (it must accept
%   connections whenever the DAQ PC starts an experiment). The DAQ-PC side
%   is tfp.hardware.MeadowlarkSLM (msconnect to this port).
%
%   Protocol (one client at a time; flat structs / char only — nested
%   structs do not round-trip on the lab msocket build):
%     <mask spec struct>  — validate (tfp.slm.validateSpec), recompute the
%                           mask stack with the SHARED engine
%                           (tfp.slm.computeDefocusStack — byte-identical
%                           to the DAQ PC's preview), upload via BlinkSLM
%                           (preloadSequence), arm per spec.triggerMode,
%                           reply 'READY'. On any failure reply
%                           'ERR: <message>'.
%     'ADV'               — software-advance one frame, reply 'ADV_OK'
%     'STATUS'            — reply a flat status struct
%     'BLANK'             — write the flat (safe) mask, reply 'BLANK_OK'
%     'BYE'               — client disconnecting; go back to accept
%     'SHUTDOWN'          — clean up and exit the loop
%
%   Until the Blink SDK is vendored + audited (docs/blink-api-audit.md),
%   BlinkSLM throws sdkNotVendored and this server replies ERR to specs —
%   run with configOverrides.dryRun = true to exercise the protocol
%   without hardware (masks are computed, upload is skipped).

if nargin < 1
    configOverrides = struct();
end
cfg = slm_pc_config();
fn  = fieldnames(configOverrides);
for k = 1:numel(fn)
    cfg.(fn{k}) = configOverrides.(fn{k});
end

if ~isempty(cfg.msocketPath) && isfolder(cfg.msocketPath)
    addpath(cfg.msocketPath);
end

dryRun = isfield(cfg, 'dryRun') && cfg.dryRun;
slm    = [];
if ~dryRun
    slm = tfp.hardware.BlinkSLM(cfg);
end

seqIndex = 0;
nMasks   = 0;
stack    = [];

fprintf('[slm_server] Listening on port %d (dryRun=%d). Ctrl-C to stop.\n', ...
    cfg.port, dryRun);

while true
    srvsock = mslisten(cfg.port);
    sock    = msaccept(srvsock, inf);
    msclose(srvsock);   % close listener promptly (receiveROIsFromScanImage lesson)
    fprintf('[slm_server] Client connected.\n');

    clientAlive = true;
    while clientAlive
        data = msrecv(sock, 0.2);   % poll; [] on timeout slice
        if isempty(data)
            continue
        end

        try
            if ischar(data)
                switch data
                    case 'ADV'
                        seqIndex = advanceOne(slm, stack, seqIndex, nMasks, dryRun);
                        mssend(sock, 'ADV_OK');
                    case 'STATUS'
                        mssend(sock, struct('seqIndex', seqIndex, ...
                            'nMasks', nMasks, 'dryRun', double(dryRun)));
                    case 'BLANK'
                        writeBlank(slm, cfg, dryRun);
                        seqIndex = 0;
                        mssend(sock, 'BLANK_OK');
                    case 'BYE'
                        clientAlive = false;
                    case 'SHUTDOWN'
                        fprintf('[slm_server] SHUTDOWN received.\n');
                        try, msclose(sock); catch, end %#ok<TRYNC>
                        if ~isempty(slm), slm.cleanup(); end
                        return
                    otherwise
                        mssend(sock, sprintf('ERR: unknown command %s', data));
                end
            elseif isstruct(data)
                % Mask spec: recompute with the shared engine + upload.
                spec = tfp.slm.validateSpec(data);
                sys  = tfp.slm.specToSys(spec);
                stackOpts = struct('wfcPath', spec.wfcPath);
                stack = tfp.slm.computeDefocusStack(spec.dzListUm, sys, stackOpts);
                nMasks   = size(stack, 3);
                seqIndex = 0;
                if ~dryRun
                    slm.preloadSequence(stack);
                    if strcmp(spec.triggerMode, 'ttl')
                        slm.armExternalTrigger();
                    end
                end
                fprintf('[slm_server] Sequence ready: %d masks (%s mode).\n', ...
                    nMasks, spec.triggerMode);
                mssend(sock, 'READY');
            else
                mssend(sock, sprintf('ERR: unexpected payload %s', class(data)));
            end
        catch ME
            fprintf(2, '[slm_server] %s: %s\n', ME.identifier, ME.message);
            try, mssend(sock, sprintf('ERR: %s', ME.message)); catch, end %#ok<TRYNC>
        end
    end

    try, msclose(sock); catch, end %#ok<TRYNC>
    fprintf('[slm_server] Client disconnected; back to accept.\n');
end
end

% --- Local helpers ---

function seqIndex = advanceOne(slm, stack, seqIndex, nMasks, dryRun)
if nMasks == 0
    error('tfp:scripts:slmServer:noSequence', 'No sequence loaded.');
end
seqIndex = seqIndex + 1;
if seqIndex > nMasks
    seqIndex = 1;   % wrap, matching TTL sequence-loop semantics
end
if ~dryRun
    % Software advance: either the SDK's native sequence step, or a direct
    % write of the preloaded frame if the audit finds no native sequencing.
    try
        slm.softwareAdvance();
    catch ME
        if strcmp(ME.identifier, 'tfp:hardware:BlinkSLM:sdkNotVendored')
            rethrow(ME);
        end
        slm.writeImage(stack(:, :, seqIndex));
    end
end
end

function writeBlank(slm, cfg, dryRun)
if dryRun
    return
end
blank = zeros(cfg.nRows, cfg.nCols, 'uint8');
slm.writeImage(blank);
end
