classdef test_MockSLM < matlab.unittest.TestCase
    %test_MockSLM Unit tests for MockSLM and the SLM.displayPhase concrete method.
    %   All tests use MockSLM; no real hardware required.
    %   Covers: initialization, loadPhaseMask validation, state transitions,
    %   displayPhase = load + present log ordering, blank, slmPower, getStatus,
    %   getActivePattern, getLog ordering, and cleanup.

    % -------------------------------------------------------------------- %
    methods (Access = private)

        function slm = makeSlm(~)
            %makeSlm Create and initialize a MockSLM with default (64×64) dims.
            slm = tfp.hardware.MockSLM();
            cfg.dims = [64 64];   % small for speed: nCols=64, nRows=64
            slm.initialize(cfg);
        end

        function mask = zeroMask(~, slm)
            %zeroMask Return a valid all-zero uint8 mask sized to slm.
            mask = zeros(slm.nRows, slm.nCols, 'uint8');
        end

        function mask = randMask(~, slm)
            %randMask Return a random uint8 mask sized to slm.
            mask = uint8(randi([0 255], slm.nRows, slm.nCols));
        end
    end

    % -------------------------------------------------------------------- %
    methods (Test)

        % ---------------------------------------------------------------- %
        % initialize

        function initialize_setsProperties(testCase)
            slm = tfp.hardware.MockSLM();
            cfg.dims     = [128 96];   % nCols=128, nRows=96
            cfg.pitch_um = 15;
            slm.initialize(cfg);

            testCase.verifyEqual(slm.nCols,        128);
            testCase.verifyEqual(slm.nRows,        96);
            testCase.verifyEqual(slm.pitch_um,     15);
            testCase.verifyTrue(slm.isInitialized);
        end

        function initialize_defaultDims(testCase)
            slm = tfp.hardware.MockSLM();
            slm.initialize(struct());

            testCase.verifyEqual(slm.nCols, 1024);
            testCase.verifyEqual(slm.nRows, 1024);
            testCase.verifyEqual(slm.pitch_um, 17);
        end

        function initialize_dimsConvention(testCase)
            % DIMS CONVENTION: dims = [nCols nRows], so dims(1)=nCols, dims(2)=nRows.
            % A CGH mask [Ny x Nx] = [nRows x nCols] passes size check exactly.
            slm = tfp.hardware.MockSLM();
            cfg.dims = [256 512];   % nCols=256, nRows=512
            slm.initialize(cfg);

            testCase.verifyEqual(slm.nCols, 256);
            testCase.verifyEqual(slm.nRows, 512);

            % A mask of size [nRows x nCols] = [512 x 256] should be accepted.
            mask = zeros(512, 256, 'uint8');
            slm.loadPhaseMask(mask);
            testCase.verifyEqual(slm.getStatus().state, 'loaded');
        end

        function initialize_explicitNRowsNColsOverrideDims(testCase)
            % Explicit nRows / nCols fields override dims.
            slm = tfp.hardware.MockSLM();
            cfg.dims  = [1024 1024];
            cfg.nCols = 320;
            cfg.nRows = 240;
            slm.initialize(cfg);

            testCase.verifyEqual(slm.nCols, 320);
            testCase.verifyEqual(slm.nRows, 240);
        end

        % ---------------------------------------------------------------- %
        % loadPhaseMask — validation

        function loadPhaseMask_rejectsNonUint8(testCase)
            slm = testCase.makeSlm();
            % Pass a double array — should throw badMask.
            testCase.verifyError( ...
                @() slm.loadPhaseMask(zeros(slm.nRows, slm.nCols)), ...
                'tfp:hardware:MockSLM:badMask');
        end

        function loadPhaseMask_rejectsWrongShape(testCase)
            slm = testCase.makeSlm();
            % One extra row — should throw badMaskShape.
            testCase.verifyError( ...
                @() slm.loadPhaseMask(zeros(slm.nRows + 1, slm.nCols, 'uint8')), ...
                'tfp:hardware:MockSLM:badMaskShape');
        end

        function loadPhaseMask_rejectsWrongWidth(testCase)
            slm = testCase.makeSlm();
            testCase.verifyError( ...
                @() slm.loadPhaseMask(zeros(slm.nRows, slm.nCols - 1, 'uint8')), ...
                'tfp:hardware:MockSLM:badMaskShape');
        end

        function loadPhaseMask_acceptsValidMask(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            testCase.verifyTrue(slm.getStatus().isMaskLoaded);
        end

        function loadPhaseMask_rejectsBeforeInit(testCase)
            slm = tfp.hardware.MockSLM();
            testCase.verifyError( ...
                @() slm.loadPhaseMask(zeros(64, 64, 'uint8')), ...
                'tfp:hardware:MockSLM:notInitialized');
        end

        % ---------------------------------------------------------------- %
        % State transitions: idle → loaded → presenting

        function stateTransitions_idleToLoaded(testCase)
            slm = testCase.makeSlm();
            testCase.verifyEqual(slm.getStatus().state, 'idle');
            slm.loadPhaseMask(testCase.zeroMask(slm));
            testCase.verifyEqual(slm.getStatus().state, 'loaded');
        end

        function stateTransitions_loadedToPresenting(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            slm.present();
            testCase.verifyEqual(slm.getStatus().state, 'presenting');
        end

        function stateTransitions_presentingToLoadedViaLoad(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            slm.present();
            testCase.verifyEqual(slm.getStatus().state, 'presenting');
            % Loading a new mask from presenting should go back to 'loaded'.
            slm.loadPhaseMask(testCase.randMask(slm));
            testCase.verifyEqual(slm.getStatus().state, 'loaded');
        end

        % ---------------------------------------------------------------- %
        % displayPhase = loadPhaseMask + present (concrete on SLM base)

        function displayPhase_endStateIsPresenting(testCase)
            slm = testCase.makeSlm();
            slm.displayPhase(testCase.zeroMask(slm));
            testCase.verifyEqual(slm.getStatus().state, 'presenting');
        end

        function displayPhase_logOrderLoadThenPresent(testCase)
            slm = testCase.makeSlm();
            slm.displayPhase(testCase.zeroMask(slm));

            entries    = slm.getLog();
            eventTypes = {entries.eventType};
            iLoad    = find(strcmp(eventTypes, 'loadPhaseMask'), 1);
            iPresent = find(strcmp(eventTypes, 'present'),      1);
            testCase.verifyNotEmpty(iLoad);
            testCase.verifyNotEmpty(iPresent);
            testCase.verifyLessThan(iLoad, iPresent);
        end

        % ---------------------------------------------------------------- %
        % blank

        function blank_setsZeroMaskAndPresenting(testCase)
            slm = testCase.makeSlm();
            % Load a non-zero mask first.
            slm.loadPhaseMask(testCase.randMask(slm));
            slm.blank();

            testCase.verifyEqual(slm.getStatus().state, 'presenting');
            activeMask = slm.getActivePattern();
            testCase.verifyEqual(activeMask, zeros(slm.nRows, slm.nCols, 'uint8'));
        end

        function blank_transitionsFromIdle(testCase)
            slm = testCase.makeSlm();
            slm.blank();
            testCase.verifyEqual(slm.getStatus().state, 'presenting');
        end

        function blank_logsEvent(testCase)
            slm = testCase.makeSlm();
            slm.blank();
            entries = slm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'blank')));
        end

        % ---------------------------------------------------------------- %
        % slmPower

        function slmPower_togglesGetStatusPowerOn(testCase)
            slm = testCase.makeSlm();
            testCase.verifyFalse(slm.getStatus().powerOn);
            slm.slmPower(true);
            testCase.verifyTrue(slm.getStatus().powerOn);
            slm.slmPower(false);
            testCase.verifyFalse(slm.getStatus().powerOn);
        end

        function slmPower_logsEvent(testCase)
            slm = testCase.makeSlm();
            slm.slmPower(true);
            entries = slm.getLog();
            iPwr = find(strcmp({entries.eventType}, 'slmPower'), 1);
            testCase.verifyNotEmpty(iPwr);
            testCase.verifyTrue(entries(iPwr).payload.on);
        end

        % ---------------------------------------------------------------- %
        % getStatus

        function getStatus_isMaskLoadedFalseInitially(testCase)
            slm = testCase.makeSlm();
            testCase.verifyFalse(slm.getStatus().isMaskLoaded);
        end

        function getStatus_isMaskLoadedTrueAfterLoad(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            testCase.verifyTrue(slm.getStatus().isMaskLoaded);
        end

        function getStatus_powerOnInitiallyFalse(testCase)
            slm = testCase.makeSlm();
            testCase.verifyFalse(slm.getStatus().powerOn);
        end

        % ---------------------------------------------------------------- %
        % getActivePattern

        function getActivePattern_emptyBeforeLoad(testCase)
            slm = testCase.makeSlm();
            testCase.verifyEmpty(slm.getActivePattern());
        end

        function getActivePattern_returnsMask(testCase)
            slm   = testCase.makeSlm();
            mask  = testCase.randMask(slm);
            slm.loadPhaseMask(mask);
            testCase.verifyEqual(slm.getActivePattern(), mask);
        end

        function getActivePattern_isUint8(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            testCase.verifyClass(slm.getActivePattern(), 'uint8');
        end

        % ---------------------------------------------------------------- %
        % getLog ordering

        function getLog_initializeIsFirstEntry(testCase)
            slm = testCase.makeSlm();
            entries = slm.getLog();
            testCase.verifyNotEmpty(entries);
            testCase.verifyEqual(entries(1).eventType, 'initialize');
        end

        function getLog_capturesFullCallSequence(testCase)
            slm  = testCase.makeSlm();
            mask = testCase.zeroMask(slm);
            slm.loadPhaseMask(mask);
            slm.present();
            slm.slmPower(true);
            slm.blank();

            entries    = slm.getLog();
            eventTypes = {entries.eventType};

            testCase.verifyEqual(eventTypes{1}, 'initialize');

            iLoad    = find(strcmp(eventTypes, 'loadPhaseMask'), 1);
            iPresent = find(strcmp(eventTypes, 'present'),       1);
            iPwr     = find(strcmp(eventTypes, 'slmPower'),      1);
            iBlank   = find(strcmp(eventTypes, 'blank'),         1);

            testCase.verifyLessThan(iLoad,    iPresent);
            testCase.verifyLessThan(iPresent, iPwr);
            testCase.verifyLessThan(iPwr,     iBlank);
        end

        % ---------------------------------------------------------------- %
        % cleanup

        function cleanup_clearsState(testCase)
            slm = testCase.makeSlm();
            slm.loadPhaseMask(testCase.zeroMask(slm));
            slm.present();
            slm.slmPower(true);

            slm.cleanup();

            testCase.verifyFalse(slm.isInitialized);
            testCase.verifyEqual(slm.getStatus().state, 'idle');
            testCase.verifyFalse(slm.getStatus().isMaskLoaded);
            testCase.verifyFalse(slm.getStatus().powerOn);
        end

        function cleanup_logsEvent(testCase)
            slm = testCase.makeSlm();
            slm.cleanup();
            entries = slm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'cleanup')));
        end

        % ---------------------------------------------------------------- %
        % debugFigure flag — log renderToDebugFigure without drawing

        function debugFigure_logsRenderEvent(testCase)
            slm = tfp.hardware.MockSLM();
            cfg.dims        = [64 64];
            cfg.debugFigure = true;
            slm.initialize(cfg);

            slm.loadPhaseMask(zeros(64, 64, 'uint8'));
            slm.present();

            entries = slm.getLog();
            testCase.verifyTrue(any(strcmp({entries.eventType}, 'renderToDebugFigure')));
        end

    end
end
