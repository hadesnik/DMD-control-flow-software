classdef test_loadConfig < matlab.unittest.TestCase
    %test_loadConfig The hand-rolled YAML parser in tfp.io.loadConfig.
    %   Six experiment scripts and ScanImageBridge open with loadConfig, so
    %   a parse regression stops the rig before anything else runs — this
    %   file is that tripwire. Covers the shipped configs, block sequences
    %   of scalars and of mappings, inline arrays, and the limits the
    %   parser is documented to refuse.

    properties
        tmpDir
    end

    methods (TestMethodSetup)
        function makeTmpDir(testCase)
            testCase.tmpDir = tempname();
            mkdir(testCase.tmpDir);
        end
    end

    methods (TestMethodTeardown)
        function removeTmpDir(testCase)
            if exist(testCase.tmpDir, 'dir')
                rmdir(testCase.tmpDir, 's');
            end
        end
    end

    methods (Test)

        function shippedConfigsAllParse(testCase)
            % The regression that motivated block-sequence support:
            % real.yaml's digitalOutChannels/digitalInChannels are block
            % sequences, and every bringup snippet starts by loading it.
            configDir = fullfile(test_loadConfig.repoRoot(), 'configs');
            files = dir(fullfile(configDir, '*.yaml'));
            testCase.assertNotEmpty(files, 'no configs found');
            for k = 1:numel(files)
                p = fullfile(configDir, files(k).name);
                cfg = tfp.io.loadConfig(p);
                testCase.verifyTrue(isstruct(cfg), ['not a struct: ' p]);
                testCase.verifyTrue(isfield(cfg, 'hardwareKind'), ...
                    ['no hardwareKind: ' p]);
            end
        end

        function realYamlDaqLinesRoundTrip(testCase)
            % The wiring itself — the values the per-line comments annotate.
            cfg = tfp.io.loadConfig(fullfile( ...
                test_loadConfig.repoRoot(), 'configs', 'real.yaml'));
            testCase.verifyEqual(cfg.daq.digitalOutChannels, ...
                {'port0/line10', 'port0/line8'});
            testCase.verifyEqual(cfg.daq.digitalInChannels, ...
                {'port0/line1'});
            % Inline arrays in the same section still behave.
            testCase.verifyEqual(cfg.daq.analogInChannels, [2 3]);
            testCase.verifyEqual(cfg.daq.analogOutChannels, [0 3]);
        end

        function scalarSequenceNestedAndTopLevel(testCase)
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'daq:'
                '  lines:'
                '    - ''port0/line10''   # trigger'
                '    - ''port0/line8''    # slm ttl'
                '  gains:'
                '    - 1'
                '    - 2.5'
                '  after: 7'
                'toplevel:'
                '  - alpha'
                '  - beta'
                });
            cfg = tfp.io.loadConfig(p);
            % Strings -> cell; numbers -> numeric row vector (same shapes
            % the inline form yields).
            testCase.verifyEqual(cfg.daq.lines, {'port0/line10', 'port0/line8'});
            testCase.verifyEqual(cfg.daq.gains, [1 2.5]);
            % A sibling key after a sequence closes it correctly.
            testCase.verifyEqual(cfg.daq.after, 7);
            testCase.verifyEqual(cfg.toplevel, {'alpha', 'beta'});
        end

        function mappingSequenceStillWorks(testCase)
            % fakeCells is the pre-existing list-of-mappings shape.
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'fakeCells:'
                '  - tag: c1'
                '    dmdCol: 100'
                '    amplitude: 0.5'
                '  - tag: c2'
                '    dmdCol: 200'
                '    amplitude: 1.5'
                'trailing: 3'
                });
            cfg = tfp.io.loadConfig(p);
            testCase.verifySize(cfg.fakeCells, [1 2]);
            testCase.verifyEqual(cfg.fakeCells(1).tag, 'c1');
            testCase.verifyEqual(cfg.fakeCells(2).dmdCol, 200);
            testCase.verifyEqual(cfg.fakeCells(2).amplitude, 1.5);
            testCase.verifyEqual(cfg.trailing, 3);
        end

        function absentFakeCellsNormalisesToTypedEmpty(testCase)
            % A section key with no items must stay a plain section, not be
            % mistaken for an empty sequence.
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'imaging:'
                '  frameRate: 30'
                });
            cfg = tfp.io.loadConfig(p);
            testCase.verifyEmpty(cfg.fakeCells);
            testCase.verifyTrue(all(ismember({'tag', 'dmdCol', 'aiChannel'}, ...
                fieldnames(cfg.fakeCells))));
            testCase.verifyEqual(cfg.imaging.frameRate, 30);
        end

        function quotedScalarWithColonIsNotAMapping(testCase)
            % '- a: b' quoted is a scalar; the discriminator is a leading
            % identifier+colon, not "contains a colon".
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'notes:'
                '  - ''ratio a: b'''
                '  - ''plain'''
                });
            cfg = tfp.io.loadConfig(p);
            testCase.verifyEqual(cfg.notes, {'ratio a: b', 'plain'});
        end

        function deeperNestingStillRejected(testCase)
            % A nested key that opens nothing is still an unsupported
            % two-level mapping — the documented limit is unchanged.
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'a:'
                '  b:'
                '    c: 1'
                });
            testCase.verifyError(@() tfp.io.loadConfig(p), ...
                'tfp:io:loadConfig:badYaml');
        end

        function mixedSequenceItemsRejected(testCase)
            p = testCase.writeYaml({ ...
                'hardwareKind: mock'
                'mixed:'
                '  - alpha'
                '  - tag: c1'
                });
            testCase.verifyError(@() tfp.io.loadConfig(p), ...
                'tfp:io:loadConfig:badYaml');
        end

        function badHardwareKindAndMissingFile(testCase)
            p = testCase.writeYaml({'hardwareKind: banana'});
            testCase.verifyError(@() tfp.io.loadConfig(p), ...
                'tfp:io:loadConfig:badYaml');
            testCase.verifyError( ...
                @() tfp.io.loadConfig(fullfile(testCase.tmpDir, 'nope.yaml')), ...
                'tfp:io:loadConfig:fileNotFound');
        end
    end

    methods (Static, Access = private)
        function root = repoRoot()
            % The framework runs tests with cwd set to tests/, so repo
            % paths resolve from this file, not from pwd.
            root = fileparts(fileparts(mfilename('fullpath')));
        end
    end

    methods (Access = private)
        function p = writeYaml(testCase, lines)
            p = fullfile(testCase.tmpDir, 'cfg.yaml');
            fid = fopen(p, 'w');
            testCase.assertGreaterThan(fid, 0, 'could not open temp yaml');
            closer = onCleanup(@() fclose(fid));
            for k = 1:numel(lines)
                fprintf(fid, '%s\n', lines{k});
            end
        end
    end
end
