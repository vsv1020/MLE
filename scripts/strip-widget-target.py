#!/usr/bin/env python3
"""Ship the app without the widget extension, without touching code (docs/WIDGET-PLAN.md §3.2).

Deletes exactly two lines from VocabLoop.xcodeproj/project.pbxproj, both inside the app
target (1A2B3C000000000000000004):

  - the PBXTargetDependency on VocabLoopWidgets, from its `dependencies`
  - the "Embed Foundation Extensions" copy phase, from its `buildPhases`

The extension target stays defined but is never built, so the archive carries no .appex.
release.yml also removes the App Group entitlement from the app in the same step, so
SharedStorage falls back to Application Support exactly as 1.0.7 did.

    python3 scripts/strip-widget-target.py           # edit the project in place
    python3 scripts/strip-widget-target.py --check   # dry run: prove both anchors exist once

Fails (exit 1) unless each anchor is found exactly once, so a project-file edit that moves
them breaks CI's sanity step rather than the release that needs this.
"""
import pathlib
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent / 'VocabLoop.xcodeproj' / 'project.pbxproj'
APP_TARGET = '1A2B3C000000000000000004 /* VocabLoop */ = {'
ANCHORS = [
    '\t\t\t\t1A2B3C000000000000000050 /* PBXTargetDependency */,\n',
    '\t\t\t\t1A2B3C00000000000000004F /* Embed Foundation Extensions */,\n',
]


def app_target_span(text):
    """Start and end offsets of the app target's object, so only its lines can match."""
    start = text.find('\t\t' + APP_TARGET)
    if start < 0 or text.count('\t\t' + APP_TARGET) != 1:
        return None
    end = text.find('\n\t\t};\n', start)
    return (start, end) if end > start else None


def main():
    check_only = '--check' in sys.argv[1:]
    text = PROJECT.read_text(encoding='utf-8')
    span = app_target_span(text)
    if span is None:
        print(f'error: app target object not found exactly once in {PROJECT}')
        return 1
    start, end = span
    target = text[start:end]

    problems = []
    for anchor in ANCHORS:
        in_target = target.count(anchor)
        in_file = text.count(anchor)
        if in_target != 1 or in_file != 1:
            problems.append(f'{anchor.strip()!r}: {in_target} in the app target, {in_file} in the file (want 1 and 1)')
    if problems:
        print('error: cannot strip the widget extension:')
        for problem in problems:
            print('  ' + problem)
        return 1

    if check_only:
        print('strip-widget-target: both anchors present exactly once in the app target (dry run)')
        return 0

    for anchor in ANCHORS:
        target = target.replace(anchor, '', 1)
    PROJECT.write_text(text[:start] + target + text[end:], encoding='utf-8')
    print('strip-widget-target: removed the extension dependency and embed phase from the app target')
    return 0


if __name__ == '__main__':
    sys.exit(main())
