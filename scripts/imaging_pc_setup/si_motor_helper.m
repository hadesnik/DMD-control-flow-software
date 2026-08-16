function si_motor_helper(options)
%si_motor_helper Serve objective-z moves/reads on the imaging PC (port 3047).
%
%   si_motor_helper()                         % defaults
%   si_motor_helper(struct('port', 3047))
%
%   Runs INSIDE the ScanImage MATLAB on the imaging PC (where hSI lives —
%   the same reason the bridge's evalin-based helpers only work there; see
%   docs/SYNC_EPISODIC.md). The DAQ PC connects via
%   tfp.hardware.RelayZStage and drives the MP-285 through ScanImage's
%   motor interface without any re-cabling.
%
%   Wire format (bare numeric vectors only — msocket-safe):
%     [1 zUm]   absolute move (um)      -> reply [0] on success
%     [2 0]     read position           -> reply [0 zUm]
%     [3 dzUm]  relative move (um)      -> reply [0]
%     [99 0]    shutdown the helper     -> reply [0], loop exits
%   First reply element ~= 0 is an error code; detail prints on this
%   console.
%
%   %VERIFY on SI2019bR0 before first use: the hSI motor surface. This
%   helper reads/writes hSI.hMotors.motorPosition ([x y z], um) as the
%   single patch point — some ScanImage versions expose
%   hSI.hMotors.hMotorZ / axesPosition instead; adjust readZ_/writeZ_
%   below only.

if nargin < 1
    options = struct();
end
port     = getOpt(options, 'port', 3047);
msockDir = getOpt(options, 'msocketPath', '');
if ~isempty(msockDir) && isfolder(msockDir)
    addpath(msockDir);
end

fprintf('[si_motor_helper] Listening on port %d. Ctrl-C to stop.\n', port);

while true
    srvsock = mslisten(port);
    sock    = msaccept(srvsock, inf);
    msclose(srvsock);
    fprintf('[si_motor_helper] Client connected.\n');

    clientAlive = true;
    while clientAlive
        req = msrecv(sock, 0.2);
        if isempty(req)
            continue
        end
        try
            if ~isnumeric(req) || numel(req) < 2
                mssend(sock, -2);   % bad request
                continue
            end
            switch req(1)
                case 1
                    writeZ_(double(req(2)));
                    mssend(sock, 0);
                case 2
                    mssend(sock, [0, readZ_()]);
                case 3
                    writeZ_(readZ_() + double(req(2)));
                    mssend(sock, 0);
                case 99
                    mssend(sock, 0);
                    fprintf('[si_motor_helper] Shutdown requested.\n');
                    try, msclose(sock); catch, end %#ok<TRYNC>
                    return
                otherwise
                    mssend(sock, -3);   % unknown opcode
            end
        catch ME
            fprintf(2, '[si_motor_helper] %s: %s\n', ME.identifier, ME.message);
            try, mssend(sock, -1); catch, end %#ok<TRYNC>
            clientAlive = false;   % drop the client; back to accept
        end
    end

    try, msclose(sock); catch, end %#ok<TRYNC>
    fprintf('[si_motor_helper] Client disconnected; back to accept.\n');
end
end

% --- hSI patch points (the ONLY places that touch ScanImage) ---

function zUm = readZ_()
% %VERIFY hSI.hMotors.motorPosition on SI2019bR0 (see header).
pos = evalin('base', 'hSI.hMotors.motorPosition');
zUm = double(pos(3));
end

function writeZ_(zUm)
% %VERIFY blocking semantics: motorPosition assignment on SI2019bR0 blocks
% until the MP-285 completes the move (audit on the bench; if it does not,
% add a position-poll loop here).
pos    = evalin('base', 'hSI.hMotors.motorPosition');
pos(3) = double(zUm);
assignin('base', 'tfp_motor_target__', pos);
evalin('base', 'hSI.hMotors.motorPosition = tfp_motor_target__;');
evalin('base', 'clear tfp_motor_target__');
end

function v = getOpt(s, name, default)
if isfield(s, name), v = s.(name); else, v = default; end
end
