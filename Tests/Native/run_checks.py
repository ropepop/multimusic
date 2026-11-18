#!/usr/bin/env python3
"""Run isolated macOS boundary checks with methods taken directly from MusicSession."""
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
output = Path(os.environ.get('MULTIMUSIC_NATIVE_CHECK_OUTPUT', root / 'build/opus-fix-verification/native'))
output.mkdir(parents=True, exist_ok=True)
session = (root / 'Multimusic/MusicSession.swift').read_text()
core = sorted((root / 'Multimusic/Core').glob('*.swift'))
configuration = root / 'Multimusic/AppConfiguration.swift'
ownership = root / 'Multimusic/SharedPlaybackOwnership.swift'
checkpoint = root / 'Multimusic/PlaybackCheckpoint.swift'

def body(name, strip_private=False):
    match = re.search(r'^    (?:private )?(?:func|var|final class) ' + re.escape(name) + r'\b', session, re.M)
    if not match:
        raise RuntimeError(f'Missing production method: {name}')
    end = session.index('\n    }', match.start()) + len('\n    }')
    source = session[match.start():end]
    return source.replace('    private func ', '    func ', 1) if strip_private else source

checks = [
    ('SharedPlaybackOwnership', core + [configuration, ownership], None, []),
    ('PlaybackCheckpoint', core + [checkpoint], None, []),
    ('RestoreSavedQueue', core + [checkpoint], 'RestoreSessionFixture', ['restore', 'updateQueueStatus']),
    ('MatchingRetry', core + [checkpoint], 'MatchingRetryFixture', ['retryMatching', 'retryableSkippedCount', 'retrySkipped', 'mayRetryResolution', 'scheduleMatchingResume', 'checkpoint', 'setCheckpoint', 'invalidateSelection']),
    ('SkipReasons', core + [checkpoint], 'SkipReasonsFixture', ['outcome'], True),
    ('TransportObservation', core + [checkpoint, configuration, ownership], 'TransportSessionFixture', ['Completion', 'serialized', 'observeTransport', 'acceptOwnedReading', 'confirmsNativeObservation']),
    ('CommandDedup', core, 'CommandDedupFixture', ['deduplicated']),
    ('DiagnosticSanitizer', [], None, []),
    ('WebsiteDiagnostics', core + [root / 'Multimusic/AppConfiguration.swift'], None, []),
    ('AppConfiguration', core + [root / 'Multimusic/AppConfiguration.swift'], None, []),
    ('LocalDiagnostics', core + [root / 'Multimusic/AppConfiguration.swift', root / 'Multimusic/TestDiagnostics.swift'], None, []),
]
for name, sources, fixture, methods, *extra in checks:
    strip_private = extra[0] if extra else False
    test = root / f'Tests/Native/{name}Checks.swift'
    if fixture:
        combined = output / f'{name}Bodies.swift'
        combined.write_text(test.read_text() + '\nextension ' + fixture + ' {\n' + '\n'.join(body(method, strip_private) for method in methods) + '\n}\n')
        test = combined
    if name == 'DiagnosticSanitizer':
        diagnostics = (root / 'Multimusic/TestDiagnostics.swift').read_text()
        start = diagnostics.index('    private static let allowedEvents:')
        end = diagnostics.index('\n}\n\nprivate enum DiagnosticsHTTPError', start)
        combined = output / f'{name}Bodies.swift'
        combined.write_text('import Foundation\nprivate enum DiagnosticSanitizer {\n' + diagnostics[start:end] + '\n}\n' + test.read_text())
        test = combined
    binary = output / name
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, sources), str(test), '-o', str(binary)]
    print('+ ' + ' '.join(command), flush=True)
    subprocess.run(command, cwd=root, check=True)
    if name == 'LocalDiagnostics':
        with tempfile.TemporaryDirectory(prefix='multimusic-local-diagnostics-') as home:
            bundle = Path(home) / 'DiagnosticsChecks.app' / 'Contents'
            (bundle / 'MacOS').mkdir(parents=True)
            executable = bundle / 'MacOS' / name
            shutil.copy2(binary, executable)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'org.multimusic.app.checks.' + uuid.uuid4().hex,
                'CFBundleExecutable': name, 'CFBundlePackageType': 'APPL'}))
            subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)', str(executable)], cwd=root, env=dict(os.environ, CFFIXED_USER_HOME=home), check=True)
    else:
        subprocess.run([str(binary)], cwd=root, check=True)
print(f'All {len(checks)} native boundary check programs passed.', flush=True)
