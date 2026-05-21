classdef test_DLPC900_PLM < matlab.unittest.TestCase
    %test_DLPC900_PLM Unit tests for DLPC900_PLM USB pattern loading (PLM-7).
    %   Tests exercise bitplane encoding, USB command framing, and public-API
    %   state transitions against the mock transport. No real USB hardware
    %   required. Hardware-level verification is deferred to PLM EVM arrival.

    methods (Access = private)
        function plm = makePlm(~)
            plm = tfp.hardware.DLPC900_PLM(struct());
        end

        function plm = makeConnectedPlm(testCase)
            plm = testCase.makePlm();
            plm.connect(struct('mockTransport', true));
        end

        function pat = zeroPattern(~, plm)
            pat = zeros(plm.nRows, plm.nCols, 'uint8');
        end
    end

    methods (Test)

        % ---------------------------------------------------------------- %
        % connect

        function connect_mockTransportSetsConnected(testCase)
            plm = testCase.makePlm();
            plm.connect(struct('mockTransport', true));
            testCase.verifyEqual(plm.getStatus().state, 'connected');
            testCase.verifyTrue(plm.getStatus().isConnected);
        end

        function connect_defaultThrowsNotImplemented(testCase)
            plm = testCase.makePlm();
            testCase.verifyError(@() plm.connect(), ...
                'tfp:hardware:DLPC900_PLM:notImplemented');
            testCase.verifyError(@() plm.connect(struct()), ...
                'tfp:hardware:DLPC900_PLM:notImplemented');
        end

        function connect_loggedWithTransport(testCase)
            plm = testCase.makeConnectedPlm();
            entries = plm.getLog();
            iConn   = find(strcmp({entries.eventType}, 'connect'), 1);
            testCase.verifyNotEmpty(iConn);
            testCase.verifyEqual(entries(iConn).payload.transport, 'mock');
        end

        % ---------------------------------------------------------------- %
        % Bitplane encoding — correctness and validation

        function encodeBitplanes_shapeAndType(testCase)
            plm = testCase.makePlm();
            pats = zeros(plm.nRows, plm.nCols, 3, 'uint8');
            bp   = plm.encodeBitplanes_(pats);
            testCase.verifyClass(bp, 'logical');
            % 5 bits per pattern, 3 patterns → 15 bitplanes
            testCase.verifySize(bp, [plm.nRows, plm.nCols, 15]);
        end

        function encodeBitplanes_zerosAllFalse(testCase)
            plm  = testCase.makePlm();
            pats = zeros(plm.nRows, plm.nCols, 2, 'uint8');
            bp   = plm.encodeBitplanes_(pats);
            testCase.verifyFalse(any(bp(:)));
        end

        function encodeBitplanes_singlePixelRoundTrip(testCase)
            % Pixel (1,1) of each pattern carries a known 5-bit value; verify
            % the bitplanes reproduce that value via bit-weighted sum.
            plm  = testCase.makePlm();
            vals = uint8([0, 1, 17, 31]);
            pats = zeros(plm.nRows, plm.nCols, numel(vals), 'uint8');
            for k = 1:numel(vals)
                pats(1, 1, k) = vals(k);
            end
            bp = plm.encodeBitplanes_(pats);

            for k = 1:numel(vals)
                reconstructed = uint8(0);
                for b = 0:4
                    if bp(1, 1, (k-1)*5 + b + 1)
                        reconstructed = reconstructed + uint8(2^b);
                    end
                end
                testCase.verifyEqual(reconstructed, vals(k));
            end
        end

        function encodeBitplanes_LSBFirstOrder(testCase)
            % Value = 1 → only bit 0 set → first bitplane true, others false.
            plm = testCase.makePlm();
            pat = zeros(plm.nRows, plm.nCols, 'uint8');
            pat(10, 20) = 1;
            bp  = plm.encodeBitplanes_(pat);
            testCase.verifyTrue(bp(10, 20, 1));
            testCase.verifyFalse(any([bp(10, 20, 2), bp(10, 20, 3), ...
                                     bp(10, 20, 4), bp(10, 20, 5)]));
        end

        function encodeBitplanes_rejectsNonUint8(testCase)
            plm  = testCase.makePlm();
            pats = zeros(plm.nRows, plm.nCols, 2);
            testCase.verifyError(@() plm.encodeBitplanes_(pats), ...
                'tfp:hardware:DLPC900_PLM:badPatterns');
        end

        function encodeBitplanes_rejectsBadShape(testCase)
            plm  = testCase.makePlm();
            pats = zeros(plm.nRows - 1, plm.nCols, 2, 'uint8');
            testCase.verifyError(@() plm.encodeBitplanes_(pats), ...
                'tfp:hardware:DLPC900_PLM:badPatternShape');
        end

        function encodeBitplanes_rejectsOutOfRangeValues(testCase)
            plm  = testCase.makePlm();
            pats = zeros(plm.nRows, plm.nCols, 1, 'uint8');
            pats(5, 5) = uint8(32);    % >= nPhaseStates
            testCase.verifyError(@() plm.encodeBitplanes_(pats), ...
                'tfp:hardware:DLPC900_PLM:badPatternValues');
        end

        % ---------------------------------------------------------------- %
        % USB command framing

        function buildCommandPacket_layoutAndLength(testCase)
            % cmd=0x1A1B, data=[0x03] → packet length = 6 + 1 = 7 bytes.
            plm    = testCase.makePlm();
            packet = plm.buildCommandPacket_(uint16(hex2dec('1A1B')), ...
                                             uint8(0), uint8(3));
            testCase.verifyClass(packet, 'uint8');
            testCase.verifyEqual(numel(packet), 7);

            % flag byte
            testCase.verifyEqual(packet(1), uint8(0));
            % length field = 2 (cmd) + 1 (data) = 3, little-endian
            testCase.verifyEqual(packet(3), uint8(3));
            testCase.verifyEqual(packet(4), uint8(0));
            % cmd LSB / MSB (little-endian on wire)
            testCase.verifyEqual(packet(5), uint8(hex2dec('1B')));
            testCase.verifyEqual(packet(6), uint8(hex2dec('1A')));
            % payload byte
            testCase.verifyEqual(packet(7), uint8(3));
        end

        function buildCommandPacket_sequenceByteIncrements(testCase)
            plm = testCase.makePlm();
            p1  = plm.buildCommandPacket_(uint16(hex2dec('1A1B')), 0, uint8([]));
            p2  = plm.buildCommandPacket_(uint16(hex2dec('1A1B')), 0, uint8([]));
            testCase.verifyEqual(p2(2), uint8(mod(double(p1(2)) + 1, 256)));
        end

        % ---------------------------------------------------------------- %
        % uploadPatternSequence — validation and successful upload

        function uploadPatternSequence_requiresConnect(testCase)
            plm  = testCase.makePlm();
            pats = zeros(plm.nRows, plm.nCols, 1, 'uint8');
            testCase.verifyError( ...
                @() plm.uploadPatternSequence(pats, 100, 'external'), ...
                'tfp:hardware:DLPC900_PLM:notImplemented');
        end

        function uploadPatternSequence_rejectsLowExposure(testCase)
            plm  = testCase.makeConnectedPlm();
            pats = zeros(plm.nRows, plm.nCols, 1, 'uint8');
            testCase.verifyError( ...
                @() plm.uploadPatternSequence(pats, 50, 'external'), ...
                'tfp:hardware:DLPC900_PLM:badExposure');
        end

        function uploadPatternSequence_rejectsBadTriggerMode(testCase)
            plm  = testCase.makeConnectedPlm();
            pats = zeros(plm.nRows, plm.nCols, 1, 'uint8');
            testCase.verifyError( ...
                @() plm.uploadPatternSequence(pats, 100, 'maybe'), ...
                'tfp:hardware:DLPC900_PLM:badTriggerMode');
        end

        function uploadPatternSequence_succeedsAndUpdatesState(testCase)
            plm  = testCase.makeConnectedPlm();
            pats = zeros(plm.nRows, plm.nCols, 2, 'uint8');
            plm.uploadPatternSequence(pats, 100, 'external');
            testCase.verifyEqual(plm.getStatus().state, 'loaded');

            entries  = plm.getLog();
            iUpload  = find(strcmp({entries.eventType}, 'uploadPatternSequence'), 1);
            testCase.verifyNotEmpty(iUpload);
            testCase.verifyEqual(entries(iUpload).payload.nPatterns,  2);
            testCase.verifyEqual(entries(iUpload).payload.nBitplanes, 10);
            testCase.verifyEqual(entries(iUpload).payload.triggerMode, 'external');
        end

        % ---------------------------------------------------------------- %
        % configureTrigger

        function configureTrigger_rejectsBadMode(testCase)
            plm = testCase.makeConnectedPlm();
            testCase.verifyError(@() plm.configureTrigger('maybe'), ...
                'tfp:hardware:DLPC900_PLM:badTriggerMode');
        end

        function configureTrigger_externalArms(testCase)
            plm = testCase.makeConnectedPlm();
            plm.configureTrigger('external');
            testCase.verifyEqual(plm.getStatus().state, 'armed');

            entries = plm.getLog();
            iCfg = find(strcmp({entries.eventType}, 'configureTrigger'), 1);
            testCase.verifyNotEmpty(iCfg);
            testCase.verifyEqual(entries(iCfg).payload.mode, 'external');
        end

        function configureTrigger_defaultModeIsExternal(testCase)
            plm = testCase.makeConnectedPlm();
            plm.configureTrigger();
            entries = plm.getLog();
            iCfg = find(strcmp({entries.eventType}, 'configureTrigger'), 1);
            testCase.verifyEqual(entries(iCfg).payload.mode, 'external');
        end

        % ---------------------------------------------------------------- %
        % start/stop sequence

        function startStopSequence_stateTransitions(testCase)
            plm = testCase.makeConnectedPlm();
            plm.configureTrigger('external');
            plm.startSequence();
            testCase.verifyEqual(plm.getStatus().state, 'running');
            plm.stopSequence();
            testCase.verifyEqual(plm.getStatus().state, 'armed');
        end

        % ---------------------------------------------------------------- %
        % uploadTwoPatternFlipTest

        function uploadTwoPatternFlipTest_computesExposureFromFreq(testCase)
            plm  = testCase.makeConnectedPlm();
            flat = zeros(plm.nRows, plm.nCols, 'uint8');
            grat = flat;
            grat(:, 1:2:end) = uint8(16);

            plm.uploadTwoPatternFlipTest(flat, grat, 100);

            entries = plm.getLog();
            iFlip = find(strcmp({entries.eventType}, 'uploadTwoPatternFlipTest'), 1);
            testCase.verifyNotEmpty(iFlip);
            % 100 Hz full cycle → 5000 µs per half-cycle
            testCase.verifyEqual(entries(iFlip).payload.exposure_us, 5000);

            iUpload = find(strcmp({entries.eventType}, 'uploadPatternSequence'), 1);
            testCase.verifyEqual(entries(iUpload).payload.nPatterns,  2);
            testCase.verifyEqual(entries(iUpload).payload.triggerMode, 'internal');
        end

        function uploadTwoPatternFlipTest_rejectsBadFreq(testCase)
            plm  = testCase.makeConnectedPlm();
            flat = zeros(plm.nRows, plm.nCols, 'uint8');
            testCase.verifyError( ...
                @() plm.uploadTwoPatternFlipTest(flat, flat, 0), ...
                'tfp:hardware:DLPC900_PLM:badFrequency');
            testCase.verifyError( ...
                @() plm.uploadTwoPatternFlipTest(flat, flat, -5), ...
                'tfp:hardware:DLPC900_PLM:badFrequency');
        end

        % ---------------------------------------------------------------- %
        % Default (no connect) path preserves existing stub behaviour

        function configureTrigger_notConnectedThrowsNotImplemented(testCase)
            plm = testCase.makePlm();
            testCase.verifyError(@() plm.configureTrigger(), ...
                'tfp:hardware:DLPC900_PLM:notImplemented');
        end

        function advancePattern_notConnectedThrowsNotImplemented(testCase)
            plm = testCase.makePlm();
            testCase.verifyError(@() plm.advancePattern(), ...
                'tfp:hardware:DLPC900_PLM:notImplemented');
        end

        % ---------------------------------------------------------------- %
        % cleanup

        function cleanup_clearsConnection(testCase)
            plm = testCase.makeConnectedPlm();
            plm.cleanup();
            testCase.verifyFalse(plm.isInitialized);
            testCase.verifyFalse(plm.getStatus().isConnected);
            testCase.verifyEqual(plm.getStatus().state, 'idle');
        end

    end
end
