#!/usr/bin/env python3
"""Regenerate Telegram/OrderFiles/*.order from real app launches.

Usage (the simulator app must be installed and logged in, ideally a fresh debug build):
    python3 tools/dev/orderfile.py --udid <SIMULATOR_UDID> [--runs 3]

What it does:
1. Records --runs cold launches with the Instruments "App Launch" template (xctrace).
2. Collects every function seen in the samples of each framework, in order of first
   appearance (outermost frame first, so callers come before callees).
3. Maps the profiler's simplified names back to linker symbols with nm + swift-demangle,
   using the installed simulator binaries (Swift symbol names do not depend on the build
   configuration). Overloads that share a simplified name are all listed; that is harmless.
4. Writes one order file per framework. The release link passes them with -order_file.

The lists are an approximation from 1 ms sampling: they cover the launch's hot path, not every
function. A symbol the linker cannot find is ignored, so stale entries never break the build.
"""
import argparse
import collections
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FRAMEWORKS = {
    'TelegramUIFramework': 'TelegramUI',
    'TelegramCoreFramework': 'TelegramCore',
    'PostboxFramework': 'Postbox',
    'SwiftSignalKitFramework': 'SwiftSignalKit',
    'MtProtoKitFramework': 'MtProtoKit',
}
BUNDLE_ID = 'ph.telegra.Telegraph'
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def run(args, **kwargs):
    return subprocess.run(args, check=False, capture_output=True, text=True, **kwargs)


def samples_from_trace(trace_path, xml_path):
    with open(xml_path, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace_path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                       stdout=out, stderr=subprocess.DEVNULL, check=False)
    if os.path.getsize(xml_path) == 0:
        return []
    root = ET.parse(xml_path).getroot()
    ids = {el.get('id'): el for el in root.iter() if el.get('id') is not None}
    resolve = lambda el: ids[el.get('ref')] if el.get('ref') is not None else el
    samples = []
    for row in root.iter('row'):
        t, frames = None, []
        for c in row:
            c = resolve(c)
            if c.tag == 'sample-time':
                t = int(c.text)
            elif c.tag in ('backtrace', 'tagged-backtrace'):
                for f in c:
                    f = resolve(f)
                    if f.tag != 'frame':
                        continue
                    binary = None
                    for b in f:
                        b = resolve(b)
                        if b.tag == 'binary':
                            binary = b.get('name')
                    frames.append((f.get('name') or '', binary or ''))
        if t is not None:
            samples.append((t, frames))
    return samples


def symbol_map(binary_path):
    names = run(['nm', '-j', binary_path]).stdout.split('\n')
    names = sorted(set(n for n in names if n))
    joined = '\n'.join(names) + '\n'
    full = run(['xcrun', 'swift-demangle'], input=joined).stdout.split('\n')
    simplified = run(['xcrun', 'swift-demangle', '--simplified'], input=joined).stdout.split('\n')
    mapping = collections.defaultdict(list)
    for name, a, b in zip(names, full, simplified):
        for key in (name, a, b, name[1:] if name.startswith('_') else None):
            if key:
                mapping[key].append(name)
    return mapping


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--udid', required=True)
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()

    app = run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE_ID, 'app']).stdout.strip()
    if not app:
        sys.exit('Telegram is not installed on the simulator')

    first_seen = collections.OrderedDict()
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(args.runs):
            run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE_ID])
            trace = os.path.join(tmp, f'launch{i}.trace')
            run(['xcrun', 'xctrace', 'record', '--template', 'App Launch', '--device', args.udid,
                 '--time-limit', '8s', '--output', trace, '--launch', '--', app])
            samples = samples_from_trace(trace, os.path.join(tmp, f'launch{i}.xml'))
            print(f'launch {i + 1}: {len(samples)} samples')
            for _, frames in sorted(samples, key=lambda s: s[0]):
                for name, binary in reversed(frames):
                    if binary in FRAMEWORKS:
                        first_seen.setdefault((binary, name), None)
        run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE_ID])

    out_dir = os.path.join(ROOT, 'Telegram', 'OrderFiles')
    for framework, short in FRAMEWORKS.items():
        mapping = symbol_map(os.path.join(app, 'Frameworks', f'{framework}.framework', framework))
        symbols, missed = [], 0
        for binary, name in first_seen:
            if binary != framework:
                continue
            candidates = mapping.get(name)
            if candidates:
                symbols.extend(candidates[:4])
            else:
                missed += 1
        symbols = list(dict.fromkeys(symbols))
        with open(os.path.join(out_dir, f'{short}.order'), 'w') as f:
            f.write('\n'.join(symbols) + '\n')
        print(f'{short}.order: {len(symbols)} symbols ({missed} profiled names not found)')


if __name__ == '__main__':
    main()
