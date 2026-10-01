"""Case selection for the phone's existing XCTest runner.

Shared app inputs select the whole UI suite. Feature inputs select reviewed case
families. Unknown/new app files keep the conservative shared-input behavior.
Harness changes are proved by merge-check-scope.test.sh, not by phone features.
"""
from pathlib import Path
import re
import hashlib
import shlex
import sys

NATIVE = 'richos/mobile/native-ios/'
# Prefixes name XCTest families, not a second inventory of individual tests.
FEATURES = {
    'Pairing': ('ScreenshotTests/testPairing', 'ScreenshotTests/testRecovery',
                'ScreenshotTests/testUpdates', 'ScreenshotTests/testLaunch', 'PairWaitInteractionTests/',
                'InteractionTests/testTheyMatch', 'InteractionTests/testAWait', 'InteractionTests/testLeaving',
                'AccessibilityLayoutTests/testEveryPairing', 'AccessibilityLayoutTests/testThePairing',
                'AccessibilityLayoutTests/testATakeover', 'AccessibilityLayoutTests/testSystemAccessibilityAudit'),
    'Composer': ('ScreenshotTests/testComposer', 'ScreenshotTests/testConversation', 'ScreenshotTests/testConnection',
                 'InteractionTests/testCompose', 'InteractionTests/testReading', 'InteractionTests/testScrolling', 'QuestionTests/',
                 'AccessibilityLayoutTests/'),
    'Voice': ('ScreenshotTests/testVoice', 'InteractionTests/testHold', 'InteractionTests/testATap',
              'InteractionTests/testSlide', 'InteractionTests/testBackground', 'InteractionTests/testAPress',
              'InteractionTests/testTheMicrophone', 'AccessibilityLayoutTests/testLockedRecording',
              'AccessibilityLayoutTests/testTheMicrophone', 'AccessibilityLayoutTests/testTheKeptVoice',
              'AccessibilityLayoutTests/testSystemAccessibilityAudit'),
    'Settings': ('ScreenshotTests/testSettings', 'ScreenshotTests/testNotifications', 'InteractionTests/testSettings',
                 'InteractionTests/testNotNow', 'AccessibilityLayoutTests/testOverlays',
                 'AccessibilityLayoutTests/testSettings', 'AccessibilityLayoutTests/testADialog',
                 'AccessibilityLayoutTests/testTheMicrophone',
                 'AccessibilityLayoutTests/testSystemAccessibilityAudit'),
    'Conversation': ('ScreenshotTests/', 'QuestionTests/', 'InteractionTests/testCompose',
                     'InteractionTests/testReading', 'InteractionTests/testScrolling', 'AccessibilityLayoutTests/'),
    'Attachments': ('ScreenshotTests/testConversation', 'ScreenshotTests/testComposer',
                    'InteractionTests/testCompose', 'AccessibilityLayoutTests/testSystemAccessibilityAudit'),
}


# Adding a source file or test case requires a new scope review. Until then,
# the selector falls back to full coverage rather than guessing its dependencies.
REVIEWED_CASES = '2f51b646f1616b4836dbdd000a6aa2be53515c4da39da0f91a02a055c294f7eb'
REVIEWED_FEATURE_FILES = {
    'App/Features/Attachments/AttachmentModel.swift',
    'App/Features/Attachments/AttachmentViews.swift',
    'App/Features/Attachments/PhotoScene.swift',
    'App/Features/Composer/ComposerView.swift',
    'App/Features/Conversation/ConnectionWords.swift',
    'App/Features/Conversation/ConversationChrome.swift',
    'App/Features/Conversation/PulseSchedule.swift',
    'App/Features/Conversation/QuestionCardView.swift',
    'App/Features/Conversation/Rows.swift',
    'App/Features/Conversation/TranscriptView.swift',
    'App/Features/Conversation/TranscriptViewportGeometry.swift',
    'App/Features/Conversation/VoiceBubble.swift',
    'App/Features/Pairing/PairingLinkSheet.swift',
    'App/Features/Pairing/Scanner.swift',
    'App/Features/Pairing/Takeovers.swift',
    'App/Features/Settings/Overlays.swift',
    'App/Features/Voice/TooShortLine.swift',
    'App/Features/Voice/VoiceChrome.swift',
}
UNIT_FAMILIES = {'Conversation': 'TranscriptViewportGeometryTests',
                 'Composer': 'TooShortLineTests', 'Voice': 'TooShortLineTests'}

def inventory(root):
    cases = {}
    for path in sorted((Path(root) / NATIVE / 'UITests').glob('*.swift')):
        text = path.read_text()
        names = re.findall(r'\b(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase', text)
        methods = re.findall(r'\bfunc\s+(test\w+)\s*\(', text)
        if methods and len(names) != 1:
            raise ValueError(f'cannot attribute UI cases in {path}')
        if names:
            cases[path.name] = [names[0] + '/' + method for method in methods]
    return cases


def select(root, paths):
    cases = inventory(root)
    selected = set()
    for path in paths:
        if not path.startswith(NATIVE):
            continue
        relative = path[len(NATIVE):]
        if relative.startswith('UITests/') and Path(relative).name in cases:
            selected.update(cases[Path(relative).name])
        elif relative.startswith('UnitTests/'):
            source = Path(root) / NATIVE / relative
            name = source.stem
            if not source.is_file() or not re.search(r'\b(?:struct|class)\s+' + re.escape(name) + r'\b', source.read_text()):
                return None
            selected.update(['RichOSNativeTests/' + name,
                             'RichOSNativeTests/BuildStampTests/testTheBundleCarriesItsBuildStamp'])
        elif relative in REVIEWED_FEATURE_FILES:
            names = sorted(case for group in cases.values() for case in group)
            if hashlib.sha256('\n'.join(names).encode()).hexdigest() != REVIEWED_CASES:
                return None
            family = relative.split('/')[2]
            prefixes = FEATURES[family]
            if family in UNIT_FAMILIES:
                selected.add('RichOSNativeTests/' + UNIT_FAMILIES[family])
                selected.add('RichOSNativeTests/BuildStampTests/testTheBundleCarriesItsBuildStamp')
            selected.update(case for group in cases.values() for case in group
                            if case.startswith(prefixes))
            # ComposerView embeds VoiceChrome: a composer change can affect its gestures too.
            if family == 'Composer':
                selected.update(case for group in cases.values() for case in group
                                if case.startswith(FEATURES['Voice']))
        else:
            # Core, root wiring, shared design, project/package/build resources and
            # new input shapes can affect every feature. Never silently omit them.
            return None
    if paths and not selected:
        return None
    return sorted(selected)


def main():
    root, changed = sys.argv[1:]
    selected = select(root, Path(changed).read_text().splitlines())
    if selected is not None:
        print(' '.join('--only ' + shlex.quote(case) for case in selected))


if __name__ == '__main__':
    main()
