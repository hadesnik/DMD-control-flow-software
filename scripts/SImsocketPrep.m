function [SISocket]=SImsocketPrep()
global ExpStruct

%run this first
addpath(genpath('C:\Users\adesniklab\Documents\MATLAB\msocket\'));

%initialize socket connection with the si computer
disp('establishing socket connection to SI computer');

srvsock = mslisten(3043);
SISocket = msaccept(srvsock,42);
msclose(srvsock);

sendVar = 'A';
mssend(SISocket,sendVar);
invar=[];
while ~strcmp(invar,'B');
    invar=msrecv(SISocket,.5);
end
disp('input from SI computer validated');
ExpStruct.SIMsocketEstablished = 1;
ExpStruct.SISocket = SISocket;