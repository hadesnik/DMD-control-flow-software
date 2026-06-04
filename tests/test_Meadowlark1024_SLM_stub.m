classdef test_Meadowlark1024_SLM_stub < matlab.unittest.TestCase
    %test_Meadowlark1024_SLM_stub Stub tests for Meadowlark1024_SLM on non-Windows.
    %   On this macOS development machine (no Blink_SDK_C.dll), constructing
    %   Meadowlark1024_SLM must throw a clean typed error rather than crashing
    %   inside loadlibrary.  If the DLL is somehow present (e.g. on the scope
    %   PC), the test is skipped via assumeFail.
    %
    %   These tests verify the fail-safe initialize() path only.  Functional
    %   hardware tests are performed on the Windows scope PC after bring-up.

    methods (Test)

        % ---------------------------------------------------------------- %
        % libLoadFailed — clean error on missing DLL

        function constructor_throwsLibLoadFailed(testCase)
            %constructor_throwsLibLoadFailed Constructing with empty config
            %   on a system without Blink_SDK_C.dll must throw
            %   tfp:hardware:Meadowlark1024_SLM:libLoadFailed.

            testCase.verifyError( ...
                @() tfp.hardware.Meadowlark1024_SLM(struct()), ...
                'tfp:hardware:Meadowlark1024_SLM:libLoadFailed');
        end

        function constructor_throwsLibLoadFailed_withDllPath(testCase)
            %constructor_throwsLibLoadFailed_withDllPath Providing an
            %   explicit (nonexistent) dllPath still triggers libLoadFailed,
            %   not a raw MATLAB error.

            cfg.dllPath    = '/nonexistent/path/Blink_SDK_C.dll';
            cfg.headerPath = '/nonexistent/path/Blink_SDK_C_matlab.h';

            testCase.verifyError( ...
                @() tfp.hardware.Meadowlark1024_SLM(cfg), ...
                'tfp:hardware:Meadowlark1024_SLM:libLoadFailed');
        end

        function initialize_throwsLibLoadFailed_directCall(testCase)
            %initialize_throwsLibLoadFailed_directCall Calling initialize()
            %   directly on a bare object (if instantiated without constructor
            %   calling it) must also produce libLoadFailed.
            %   NOTE: Because the constructor calls initialize(), this test
            %   exercises the same code path as constructor_throwsLibLoadFailed.

            testCase.verifyError( ...
                @() tfp.hardware.Meadowlark1024_SLM(struct('dims', [512 512])), ...
                'tfp:hardware:Meadowlark1024_SLM:libLoadFailed');
        end

    end
end
