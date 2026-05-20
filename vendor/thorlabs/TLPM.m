classdef TLPM < handle
    %TLPM Thorlabs PM100D wrapper via TLPM_64.dll (calllib).
    %   Implements findRsrc, init, setWavelength, measPower, close —
    %   the subset used by tfp.calibration.powerMeterSweep.
    %
    %   Requires MinGW-w64 (MATLAB Add-On) for the first loadlibrary call,
    %   which compiles a thunk DLL cached in the MATLAB temp directory.
    %   Subsequent calls reuse the cached thunk; MinGW is not invoked again.
    %
    %   DLL:    C:\Program Files\IVI Foundation\VISA\Win64\Bin\TLPM_64.dll
    %   Header: vendor\thorlabs\tlpm_mini.h (stripped, no __fastcall__)

    properties (Access = private)
        vi_  = uint32(0)   % ViSession handle; 0 = not open
    end

    properties (Constant, Access = private)
        LIB = 'tlpm'
        DLL = 'C:\Program Files\IVI Foundation\VISA\Win64\Bin\TLPM_64'
    end

    methods
        function obj = TLPM()
            if ~libisloaded(obj.LIB)
                hdr = fullfile(fileparts(mfilename('fullpath')), 'tlpm_mini.h');
                loadlibrary(obj.DLL, hdr, 'alias', obj.LIB);
            end
        end

        function rsrc = findRsrc(obj)
            %findRsrc Return VISA resource string for the first PM100 found.
            countPtr = libpointer('uint32Ptr', uint32(0));
            obj.chk(calllib(obj.LIB, 'TLPM_findRsrc', uint32(0), countPtr), 'findRsrc');
            if countPtr.Value == 0
                error('TLPM:notFound', ...
                    'No Thorlabs power meter found. Check USB cable.');
            end
            bufPtr = libpointer('int8Ptr', zeros(1, 256, 'int8'));
            obj.chk(calllib(obj.LIB, 'TLPM_getRsrcName', uint32(0), uint32(0), bufPtr), 'getRsrcName');
            raw  = bufPtr.Value;
            rsrc = char(raw(1 : find(raw == 0, 1) - 1));
        end

        function init(obj, resourceName, ~, ~)
            %init Open connection. Extra args (IDQuery, reset) accepted but ignored.
            viPtr = libpointer('uint32Ptr', uint32(0));
            obj.chk(calllib(obj.LIB, 'TLPM_init', resourceName, uint16(1), uint16(0), viPtr), 'init');
            obj.vi_ = viPtr.Value;
            fprintf('PM100D connected (session 0x%08X)\n', obj.vi_);
        end

        function setWavelength(obj, wavelengthNm)
            %setWavelength Set spectral correction wavelength in nm.
            obj.chk(calllib(obj.LIB, 'TLPM_setWavelength', obj.vi_, double(wavelengthNm)), 'setWavelength');
        end

        function powerW = measPower(obj)
            %measPower Read instantaneous power. Returns watts.
            pwrPtr = libpointer('doublePtr', 0);
            obj.chk(calllib(obj.LIB, 'TLPM_measPower', obj.vi_, pwrPtr), 'measPower');
            powerW = pwrPtr.Value;
        end

        function close(obj)
            %close Release the PM100D connection.
            if obj.vi_ ~= uint32(0)
                calllib(obj.LIB, 'TLPM_close', obj.vi_);
                obj.vi_ = uint32(0);
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Access = private)
        function chk(~, status, funcName)
            if status ~= 0
                error('TLPM:apiError', 'TLPM_%s returned 0x%08X', funcName, uint32(status));
            end
        end
    end
end
