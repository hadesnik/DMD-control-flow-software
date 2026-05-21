classdef test_MockPLM < matlab.unittest.TestCase
    %test_MockPLM Phase 1 MockPLM and PLM.computeDefocusPattern tests.
    %   All tests use MockPLM; no real hardware required. TIPLM_PLM stub
    %   behaviour is covered in tiplm_stubs_throwNotImplemented.

    methods (Access = private)
        function plm = makePlm(~)
            plm = tfp.hardware.MockPLM();
            config.nRows         = 800;
            config.nCols         = 904;
            config.pitchX_um     = 16.2;
            config.pitchY_um     = 10.8;
            config.nPhaseStates  = 32;
            config.lambda_nm     = 1030;
            config.loadLatencyMs = 0;    % fast tests
            plm.initialize(config);
        end

        function tiplm = makeTiplm(~)
            tiplm = tfp.hardware.TIPLM_PLM(struct());
        end

        function pat = zeroPattern(~, plm)
            pat = zeros(plm.nRows, plm.nCols, 'uint8');
        end
    end

    methods (Test)

        % ---------------------------------------------------------------- %
        % initialize

        function initialize_setsProperties(testCase)
            plm = tfp.hardware.MockPLM();
            config.nRows         = 800;
            config.nCols         = 904;
            config.pitchX_um     = 16.2;
            config.pitchY_um     = 10.8;
            config.nPhaseStates  = 32;
            config.lambda_nm     = 1030;
            config.loadLatencyMs = 0;
            plm.initialize(config);

            testCase.verifyEqual(plm.nRows,        800);
            testCase.verifyEqual(plm.nCols,        904);
            testCase.verifyEqual(plm.pitchX_um,    16.2);
            testCase.verifyEqual(plm.pitchY_um,    10.8);
            testCase.verifyEqual(plm.nPhaseStates, 32);
            testCase.verifyEqual(plm.lambda_nm,    1030);
            testCase.verifyTrue(plm.isInitialized);
        end

        % ---------------------------------------------------------------- %
        % computeDefocusPattern — output shape and type

        function computeDefocusPattern_returnsUint8NyNx(testCase)
            plm = testCase.makePlm();
            pat = plm.computeDefocusPattern(50, struct());
            testCase.verifyClass(pat, 'uint8');
            testCase.verifyEqual(size(pat), [plm.nRows, plm.nCols]);
        end

        function computeDefocusPattern_valuesInRange(testCase)
            plm = testCase.makePlm();
            % Large dz generates many wrap cycles; verify bounds hold throughout.
            pat = plm.computeDefocusPattern(200, struct());
            testCase.verifyGreaterThanOrEqual(double(min(pat(:))), 0);
            testCase.verifyLessThanOrEqual(double(max(pat(:))), 31);
        end

        % ---------------------------------------------------------------- %
        % computeDefocusPattern — dz = 0 → flat wavefront

        function computeDefocusPattern_dzZeroIsFlat(testCase)
            plm = testCase.makePlm();
            pat = plm.computeDefocusPattern(0, struct());
            testCase.verifyEqual(pat, zeros(plm.nRows, plm.nCols, 'uint8'));
        end

        % ---------------------------------------------------------------- %
        % computeDefocusPattern — pupil mask

        function computeDefocusPattern_outsidePupilIsZero(testCase)
            plm = testCase.makePlm();
            pat = plm.computeDefocusPattern(200, struct());

            % Default sys: r_PLM = 16800*0.6/1.33/2.4 ≈ 3157 µm.
            % Array corners sit at r ≈ 8491 µm — well outside the pupil.
            testCase.verifyEqual(pat(1,   1),   uint8(0));
            testCase.verifyEqual(pat(1,   end), uint8(0));
            testCase.verifyEqual(pat(end, 1),   uint8(0));
            testCase.verifyEqual(pat(end, end), uint8(0));

            % Pixel 100 cols from centre (r ≈ 1630 µm) is inside the pupil.
            % At dz=200 µm the phase wraps ~7 times, producing a nonzero state.
            cx = ceil(plm.nCols / 2);
            cy = ceil(plm.nRows / 2);
            testCase.verifyGreaterThan(double(pat(cy, cx - 100)), 0);
        end

        % ---------------------------------------------------------------- %
        % computeDefocusPattern — 180-degree rotational symmetry

        function computeDefocusPattern_symmetricUnder180Rotation(testCase)
            plm = testCase.makePlm();
            pat = plm.computeDefocusPattern(100, struct());
            % phi(r) depends only on r^2, so pat(i,j) == pat(Ny+1-i, Nx+1-j).
            testCase.verifyEqual(pat, rot90(pat, 2));
        end

        % ---------------------------------------------------------------- %
        % loadPattern — validation

        function loadPattern_validation(testCase)
            plm = testCase.makePlm();

            % Non-uint8 rejected.
            testCase.verifyError( ...
                @() plm.loadPattern(zeros(plm.nRows, plm.nCols)), ...
                'tfp:hardware:MockPLM:badPattern');

            % Wrong row count rejected.
            testCase.verifyError( ...
                @() plm.loadPattern(zeros(plm.nRows - 1, plm.nCols, 'uint8')), ...
                'tfp:hardware:MockPLM:badPatternShape');

            % Value >= nPhaseStates rejected.
            bad = zeros(plm.nRows, plm.nCols, 'uint8');
            bad(1, 1) = uint8(32);
            testCase.verifyError(@() plm.loadPattern(bad), ...
                'tfp:hardware:MockPLM:badPatternValues');

            % Valid pattern accepted; isPatternLoaded flips.
            plm.loadPattern(testCase.zeroPattern(plm));
            testCase.verifyTrue(plm.getStatus().isPatternLoaded);
        end

        % ---------------------------------------------------------------- %
        % stub methods — log entries and state transitions

        function displayPattern_logsAndSetsState(testCase)
            plm = testCase.makePlm();
            plm.displayPattern(testCase.zeroPattern(plm));

            entries = plm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'displayPattern')));
            testCase.verifyEqual(plm.getStatus().state, 'displaying');
        end

        function configureTrigger_logs(testCase)
            plm = testCase.makePlm();
            plm.configureTrigger();

            entries = plm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'configureTrigger')));
        end

        function advancePattern_logs(testCase)
            plm = testCase.makePlm();
            plm.advancePattern();

            entries = plm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'advancePattern')));
        end

        % ---------------------------------------------------------------- %
        % log — ordering

        function log_capturesCalls(testCase)
            plm = testCase.makePlm();
            pat = testCase.zeroPattern(plm);
            plm.loadPattern(pat);
            plm.displayPattern(pat);
            plm.configureTrigger();
            plm.advancePattern();

            entries    = plm.getLog();
            eventTypes = {entries.eventType};

            % First entry is 'initialize' (from makePlm).
            testCase.verifyEqual(eventTypes{1}, 'initialize');
            testCase.verifyTrue(any(strcmp(eventTypes, 'loadPattern')));
            testCase.verifyTrue(any(strcmp(eventTypes, 'displayPattern')));
            testCase.verifyTrue(any(strcmp(eventTypes, 'configureTrigger')));
            testCase.verifyTrue(any(strcmp(eventTypes, 'advancePattern')));

            % Ordering: load < display < configureTrigger < advancePattern.
            iLoad = find(strcmp(eventTypes, 'loadPattern'),      1);
            iDisp = find(strcmp(eventTypes, 'displayPattern'),   1);
            iCfg  = find(strcmp(eventTypes, 'configureTrigger'), 1);
            iAdv  = find(strcmp(eventTypes, 'advancePattern'),   1);
            testCase.verifyLessThan(iLoad, iDisp);
            testCase.verifyLessThan(iDisp, iCfg);
            testCase.verifyLessThan(iCfg,  iAdv);
        end

        % ---------------------------------------------------------------- %
        % cleanup

        function cleanup_clearsState(testCase)
            plm = testCase.makePlm();
            plm.loadPattern(testCase.zeroPattern(plm));

            plm.cleanup();
            testCase.verifyFalse(plm.isInitialized);
            testCase.verifyEqual(plm.getStatus().state, 'idle');
            testCase.verifyFalse(plm.getStatus().isPatternLoaded);
        end

        % ---------------------------------------------------------------- %
        % TIPLM_PLM stubs

        function tiplm_stubs_throwNotImplemented(testCase)
            tiplm = testCase.makeTiplm();

            % displayPattern scaffolds the PTB path; encode_for_DLPC900 now
            % returns successfully (linear grayscale). displayPattern itself
            % is skipped here because Screen('Screens') is unavailable in
            % CI/dev — tested manually on the scope PC with PTB installed.

            testCase.verifyError(@() tiplm.configureTrigger(), ...
                'tfp:hardware:TIPLM_PLM:notImplemented');
            testCase.verifyError(@() tiplm.advancePattern(), ...
                'tfp:hardware:TIPLM_PLM:notImplemented');
        end

    end
end
