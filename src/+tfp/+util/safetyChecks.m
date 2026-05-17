function safetyChecks(varargin)
%safetyChecks Laser-path safety interlocks invoked by Sequencer.run before every trial.
%   Phase 1 stub. Real implementation will verify that the Pockels
%   cell is commanded closed during trial gaps, that the shutter is
%   in the expected state, that requested power is within the
%   configured maximum, and that the safety-abort flag has not been
%   raised.
%
%   TODO(Phase 2): the `varargin` signature is a Phase 1 placeholder.
%   Define the concrete argument list when the laser/Pockels interlock
%   backend lands.
error('not implemented');
end
