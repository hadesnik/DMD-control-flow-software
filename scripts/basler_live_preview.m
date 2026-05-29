%basler_live_preview  Live preview of the Basler acA2500-14um substage camera.
%
%   Run on the scope PC:
%
%     addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'))
%     basler_live_preview
%
%   Close the figure window to stop.

DEVICE_ID   = 1;    % from imaqhwinfo('gentl') — change if camera is not device 1
EXPOSURE_MS = 50;
GAIN        = 0;

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

cfg.deviceId   = DEVICE_ID;
cfg.format     = 'Mono8';
cfg.exposureMs = EXPOSURE_MS;
cfg.gain       = GAIN;

cam = tfp.hardware.BaslerSubstageCamera();
cam.initialize(cfg);

fig = figure('Name', 'Basler Live Preview', 'NumberTitle', 'off');
hImg = imagesc(zeros(cam.nRows, cam.nCols));
colormap(fig, gray);
axis image off;
title(sprintf('Basler acA2500  |  exposure %d ms  |  close window to stop', EXPOSURE_MS));
colorbar;

cam.startLive();
fprintf('Live preview running — close the figure to stop.\n');

while ishandle(fig)
    frame = cam.getFrame();
    set(hImg, 'CData', frame);
    drawnow;
end

cam.stopLive();
cam.cleanup();
fprintf('Camera stopped.\n');
