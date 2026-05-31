function SISocket = SImsocketPrep()
%SImsocketPrep Connect to the ScanImage PC via msocket and perform A/B handshake.
%   SISocket = SImsocketPrep()
%   Returns the open socket handle. Caller is responsible for storing it.
%   Example:
%     SISocket = SImsocketPrep();
%     SIEngaged = 1;

addpath(genpath('C:\Users\adesniklab\Documents\MATLAB\msocket\'));

disp('establishing socket connection to SI computer');

srvsock = mslisten(3043);
SISocket = msaccept(srvsock, 42);
msclose(srvsock);

mssend(SISocket, 'A');
invar = [];
while ~strcmp(invar, 'B')
    invar = msrecv(SISocket, .5);
end
disp('input from SI computer validated');