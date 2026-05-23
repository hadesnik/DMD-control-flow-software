classdef test_read_scanimage_tiff < matlab.unittest.TestCase
    %test_read_scanimage_tiff Coverage for tfp.io.readScanImageTiff (T-EP-1b).
    %   Verifies the dispatch between mock .mat sidecars and real ScanImage
    %   TIFFs, the LOCKED output struct shape (SYNC_EPISODIC.md §6.2/§9.7),
    %   the synthesised-timestamps fallback, the unsupported-extension and
    %   file-not-found error paths, and the one-shot no-timestamps warning.

    properties
        TmpDir   % per-test temp directory, cleaned up in TestMethodTeardown
    end

    methods (TestMethodSetup)
        function makeTmp(testCase)
            testCase.TmpDir = tempname();
            mkdir(testCase.TmpDir);
        end
    end

    methods (TestMethodTeardown)
        function rmTmp(testCase)
            if isfolder(testCase.TmpDir)
                rmdir(testCase.TmpDir, 's');
            end
        end
    end

    methods (Test)
        function matSidecar_happyPath(testCase)
            % A .mat with a fully-shaped `meta` struct round-trips verbatim.
            matPath = fullfile(testCase.TmpDir, 'mock.mat');
            meta = makeLockedMockMeta(matPath); %#ok<NASGU>
            save(matPath, 'meta');

            out = tfp.io.readScanImageTiff(matPath);

            testCase.verifyEqual(out.numFrames,                uint32(7));
            testCase.verifyEqual(out.numChannels,              uint32(1));
            testCase.verifyEqual(out.frameRateHz,              30.0);
            testCase.verifyEqual(numel(out.frameTimestamps_s), 7);
            testCase.verifyFalse(out.timestampsAreSynthesised);
            testCase.verifyEqual(out.sourceTiff,        matPath);
            testCase.verifyEqual(out.scanImageVersion, 'mock');
        end

        function matSidecar_wrongShape_throws(testCase)
            % Missing `numFrames` field => badMatSidecar error.
            matPath = fullfile(testCase.TmpDir, 'bad.mat');
            meta = struct( ...
                'numChannels',              uint32(1), ...
                'frameRateHz',              30.0, ...
                'frameTimestamps_s',        zeros(3, 1), ...
                'timestampsAreSynthesised', false, ...
                'sourceTiff',               matPath, ...
                'scanImageVersion',         'mock'); %#ok<NASGU>
            save(matPath, 'meta');

            testCase.verifyError( ...
                @() tfp.io.readScanImageTiff(matPath), ...
                'tfp:io:readScanImageTiff:badMatSidecar');
        end

        function matSidecar_missingMetaVar_throws(testCase)
            % The variable in the .mat is not named `meta`.
            matPath = fullfile(testCase.TmpDir, 'wrongname.mat');
            notMeta = struct('x', 1); %#ok<NASGU>
            save(matPath, 'notMeta');

            testCase.verifyError( ...
                @() tfp.io.readScanImageTiff(matPath), ...
                'tfp:io:readScanImageTiff:badMatSidecar');
        end

        function realTiff_multiPage_synthesisesTimestamps(testCase)
            % Build a minimal 3-page uint16 TIFF (no ScanImage metadata)
            % and confirm frameTimestamps_s are synthesised from rate
            % (or all-NaN when neither is recoverable, with a warning).
            tifPath = fullfile(testCase.TmpDir, 'multipage.tif');
            writeMinimalTiff(tifPath, 3);

            % We expect noTimestamps warning since neither rate nor
            % per-frame timestamps are present. The warning is one-shot
            % so accept either the warning being raised or it having been
            % raised earlier in the same MATLAB session.
            out = tfp.io.readScanImageTiff(tifPath);

            testCase.verifyEqual(out.numFrames,   uint32(3));
            testCase.verifyEqual(out.numChannels, uint32(1));
            testCase.verifyTrue(out.timestampsAreSynthesised);
            testCase.verifyEqual(numel(out.frameTimestamps_s), 3);
            % With no frame rate, synthesised timestamps are all NaN.
            testCase.verifyTrue(all(isnan(out.frameTimestamps_s)));
            testCase.verifyEqual(out.scanImageVersion, 'unknown');
        end

        function unsupportedExtension_throws(testCase)
            % .png is not supported; the function must not attempt to read
            % it, so the file does not need to exist on disk for the
            % extension check to fire. We still need a real file because
            % the existence check runs first.
            pngPath = fullfile(testCase.TmpDir, 'foo.png');
            fid = fopen(pngPath, 'w'); fwrite(fid, 0, 'uint8'); fclose(fid);

            testCase.verifyError( ...
                @() tfp.io.readScanImageTiff(pngPath), ...
                'tfp:io:readScanImageTiff:unsupportedExtension');
        end

        function nonExistentFile_throws(testCase)
            ghost = fullfile(testCase.TmpDir, 'does_not_exist.tif');
            testCase.verifyError( ...
                @() tfp.io.readScanImageTiff(ghost), ...
                'tfp:io:readScanImageTiff:fileNotFound');
        end

        function noTimestamps_warning_isOneShot(testCase)
            % The first read of a no-metadata TIFF in a MATLAB session
            % must warn; a second read of an equivalent file must not.
            % Because the warning is `persistent`-gated inside the
            % function, earlier tests in this suite may have already
            % tripped it. Reset the persistent state with `clear
            % functions` before this test (clearing only the function
            % by name does not reset its persistents in R2023a).
            clear functions; %#ok<CLFUNC>

            tifA = fullfile(testCase.TmpDir, 'noTsA.tif');
            tifB = fullfile(testCase.TmpDir, 'noTsB.tif');
            writeMinimalTiff(tifA, 2);
            writeMinimalTiff(tifB, 2);

            testCase.verifyWarning( ...
                @() tfp.io.readScanImageTiff(tifA), ...
                'tfp:io:readScanImageTiff:noTimestamps');
            testCase.verifyWarningFree( ...
                @() tfp.io.readScanImageTiff(tifB));
        end
    end
end

% =========================================================================
% Helpers
% =========================================================================

function meta = makeLockedMockMeta(sourcePath)
%makeLockedMockMeta Build a fully-shaped mock meta struct.
N = 7;
meta = struct( ...
    'numFrames',                uint32(N), ...
    'numChannels',              uint32(1), ...
    'frameRateHz',              30.0, ...
    'frameTimestamps_s',        (0:N-1)' / 30.0, ...
    'timestampsAreSynthesised', false, ...
    'sourceTiff',               sourcePath, ...
    'scanImageVersion',         'mock');
end

function writeMinimalTiff(path, nFrames)
%writeMinimalTiff Write a tiny multi-page uint16 TIFF with `nFrames` pages.
%   No ScanImage metadata is embedded; the resulting file should drive the
%   timestamp-synthesis / no-timestamps-warning code paths.
w = 4;
h = 4;
t = Tiff(path, 'w');
closer = onCleanup(@() t.close()); %#ok<NASGU>

for k = 1:nFrames
    tagstruct.ImageLength         = h;
    tagstruct.ImageWidth          = w;
    tagstruct.Photometric         = Tiff.Photometric.MinIsBlack;
    tagstruct.BitsPerSample       = 16;
    tagstruct.SamplesPerPixel     = 1;
    tagstruct.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
    tagstruct.Compression         = Tiff.Compression.None;
    tagstruct.Software            = 'test_read_scanimage_tiff';
    t.setTag(tagstruct);
    t.write(uint16(zeros(h, w)));
    if k < nFrames
        t.writeDirectory();
    end
end
end
