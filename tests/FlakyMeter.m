classdef FlakyMeter < handle
    %FlakyMeter A power meter that throws on the Nth read.
    %   Test fixture for tfp.calibration.powerMeterSweepSingle's fault path:
    %   a meter failure mid-sweep must still leave the modulator at zero.
    properties
        failOnRead
        nReads = 0
    end
    methods
        function obj = FlakyMeter(failOnRead)
            obj.failOnRead = failOnRead;
        end
        function w = measPower(obj)
            obj.nReads = obj.nReads + 1;
            if obj.nReads >= obj.failOnRead
                error('FlakyMeter:boom', 'synthetic meter failure on read %d', obj.nReads);
            end
            w = 1e-3;
        end
        function close(~)
        end
    end
end
