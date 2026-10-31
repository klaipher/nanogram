#!/usr/bin/env python3
"""Signing for installing your own build on your own iPhone with a paid Apple Developer account.

Subcommands:
  profiles   Let Xcode register the app and extension IDs (push + app group) on your team and
             create development provisioning profiles for them, then collect the profiles into
             ~/.config/telegram-ios/codesigning/profiles for `tg device`.
  apns-csr   Create the private key and certificate signing request for the push certificate.
  apns-pem   Combine the downloaded push certificate (aps.cer) with that key into the .pem file
             that my.telegram.org/apps expects, so Telegram's servers can push to your app.

Everything is written under ~/.config/telegram-ios (private, outside the repository).
Xcode must be signed in to the Apple ID of the team (Xcode > Settings > Accounts).
"""
import argparse
import glob
import json
import os
import plistlib
import shutil
import subprocess
import sys

HOME_DIR = os.path.expanduser('~/.config/telegram-ios')
CONFIG = os.path.join(HOME_DIR, 'device-configuration.json')
CODESIGNING = os.path.join(HOME_DIR, 'codesigning')
APNS_DIR = os.path.join(HOME_DIR, 'apns')
XCODE_PROFILES = os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles')

# Suffixes match build-system/Make/BuildConfiguration.py (profile_name_mapping).
# The watch app is not built for device installs, so it is left out.
EXTENSIONS = ['.Share', '.NotificationService', '.NotificationContent', '.Widget', '.SiriIntents', '.BroadcastUpload']


def load_config():
    with open(CONFIG) as f:
        return json.load(f)


def save_config(config):
    old_umask = os.umask(0o077)
    try:
        with open(CONFIG, 'w') as f:
            json.dump(config, f, indent=1)
    finally:
        os.umask(old_umask)


def read_profile(path):
    data = subprocess.run(['security', 'cms', '-D', '-i', path], capture_output=True, check=True).stdout
    return plistlib.loads(data)


def entitlements_plist(groups, push):
    entries = ['<key>com.apple.security.application-groups</key><array><string>{}</string></array>'.format(g) for g in groups]
    if push:
        entries.append('<key>aps-environment</key><string>development</string>')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>' + ''.join(entries) + '</dict></plist>\n')


def write_project(directory, team_id, targets):
    """A minimal Xcode project with one app target per bundle id. It only exists so that
    Xcode's automatic signing registers the ids and creates their profiles."""
    counter = [0]

    def new_id():
        counter[0] += 1
        return 'B0{:022X}'.format(counter[0])

    os.makedirs(os.path.join(directory, 'App.xcodeproj'), exist_ok=True)
    with open(os.path.join(directory, 'main.swift'), 'w') as f:
        f.write('import UIKit\nfinal class AppDelegate: UIResponder, UIApplicationDelegate {}\n'
                'UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))\n')

    objects = []
    source_ref = new_id()
    objects.append('{} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; }};'.format(source_ref))
    group_children = [source_ref]
    product_refs = []
    target_ids = []
    for name, bundle_id, push in targets:
        with open(os.path.join(directory, name + '.entitlements'), 'w') as f:
            f.write(entitlements_plist(['group.' + targets[0][1]], push))
        build_file, product_ref, sources, target, config, config_list = (new_id() for _ in range(6))
        objects += [
            '{} = {{isa = PBXBuildFile; fileRef = {}; }};'.format(build_file, source_ref),
            '{} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {}.app; sourceTree = BUILT_PRODUCTS_DIR; }};'.format(product_ref, name),
            '{} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({}); runOnlyForDeploymentPostprocessing = 0; }};'.format(sources, build_file),
            '{} = {{isa = PBXNativeTarget; buildConfigurationList = {}; buildPhases = ({}); buildRules = (); dependencies = (); name = {}; productName = {}; productReference = {}; productType = "com.apple.product-type.application"; }};'.format(target, config_list, sources, name, name, product_ref),
            '{} = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_BUNDLE_IDENTIFIER = "{}"; PRODUCT_NAME = {}; DEVELOPMENT_TEAM = {}; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "Apple Development"; CODE_SIGN_ENTITLEMENTS = {}.entitlements; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; TARGETED_DEVICE_FAMILY = "1,2"; }}; name = Debug; }};'.format(config, bundle_id, name, team_id, name),
            '{} = {{isa = XCConfigurationList; buildConfigurations = ({}); defaultConfigurationName = Debug; }};'.format(config_list, config),
        ]
        product_refs.append(product_ref)
        target_ids.append(target)
    main_group, products_group, project, project_config, project_config_list = (new_id() for _ in range(5))
    objects += [
        '{} = {{isa = PBXGroup; children = ({}); sourceTree = "<group>"; }};'.format(main_group, ', '.join(group_children + [products_group])),
        '{} = {{isa = PBXGroup; children = ({}); name = Products; sourceTree = "<group>"; }};'.format(products_group, ', '.join(product_refs)),
        '{} = {{isa = XCBuildConfiguration; buildSettings = {{SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0; }}; name = Debug; }};'.format(project_config),
        '{} = {{isa = XCConfigurationList; buildConfigurations = ({}); defaultConfigurationName = Debug; }};'.format(project_config_list, project_config),
        '{} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; }}; buildConfigurationList = {}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {}; productRefGroup = {}; projectDirPath = ""; projectRoot = ""; targets = ({}); }};'.format(project, project_config_list, main_group, products_group, ', '.join(target_ids)),
    ]
    with open(os.path.join(directory, 'App.xcodeproj', 'project.pbxproj'), 'w') as f:
        f.write('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n\t\t'
                + '\n\t\t'.join(objects) + '\n\t};\n\trootObject = ' + project + ';\n}\n')


def first_physical_device():
    out = subprocess.run(['xcrun', 'devicectl', 'list', 'devices'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if 'physical' in parts:
            for part in parts:
                if len(part) == 25 and part[8] == '-':
                    return part
    return None


def cmd_profiles(args):
    config = load_config()
    if args.team:
        config['team_id'] = args.team
        save_config(config)
    team_id, bundle_id = config['team_id'], config['bundle_id']
    device = args.device or first_physical_device()
    if device is None:
        sys.exit('No iPhone found: connect it (cable or same Wi-Fi) and unlock it')

    targets = [('Telegram', bundle_id, True)] + [(suffix[1:], bundle_id + suffix, False) for suffix in EXTENSIONS]
    work = os.path.join(HOME_DIR, 'profilegen')
    shutil.rmtree(work, ignore_errors=True)
    write_project(work, team_id, targets)

    for name, target_bundle_id, _ in targets:
        print('Signing {} ({})'.format(name, target_bundle_id), flush=True)
        result = subprocess.run(['xcodebuild', '-project', os.path.join(work, 'App.xcodeproj'), '-scheme', name,
                                 '-configuration', 'Debug', '-destination', 'id=' + device,
                                 '-derivedDataPath', os.path.join(work, 'dd'),
                                 '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build'],
                                capture_output=True, text=True)
        if result.returncode != 0:
            errors = [l for l in result.stdout.splitlines() + result.stderr.splitlines() if 'error:' in l]
            sys.exit('Xcode could not sign {}:\n{}'.format(name, '\n'.join(errors[:10]) or result.stdout[-2000:]))

    profiles_dir = os.path.join(CODESIGNING, 'profiles')
    shutil.rmtree(profiles_dir, ignore_errors=True)
    os.makedirs(profiles_dir)
    os.makedirs(os.path.join(CODESIGNING, 'certs'), exist_ok=True)
    found = {}
    for path in glob.glob(os.path.join(XCODE_PROFILES, '*.mobileprovision')):
        profile = read_profile(path)
        app_id = profile['Entitlements'].get('application-identifier', '')
        if team_id not in profile.get('TeamIdentifier', []) or not app_id.startswith(team_id + '.'):
            continue
        target_bundle_id = app_id[len(team_id) + 1:]
        if target_bundle_id not in [t[1] for t in targets]:
            continue
        if target_bundle_id not in found or profile['ExpirationDate'] > found[target_bundle_id][1]['ExpirationDate']:
            found[target_bundle_id] = (path, profile)
    for name, target_bundle_id, push in targets:
        if target_bundle_id not in found:
            sys.exit('No profile was created for ' + target_bundle_id)
        path, profile = found[target_bundle_id]
        if push and 'aps-environment' not in profile['Entitlements']:
            sys.exit('The profile for {} has no push entitlement: is {} a paid team?'.format(target_bundle_id, team_id))
        shutil.copyfile(path, os.path.join(profiles_dir, name + '.mobileprovision'))
        print('{:<20} expires {}'.format(name, profile['ExpirationDate']))
    print('Profiles are in ' + profiles_dir)


def cmd_apns_csr(args):
    os.makedirs(APNS_DIR, mode=0o700, exist_ok=True)
    key = os.path.join(APNS_DIR, 'apns.key')
    csr = os.path.join(APNS_DIR, 'apns.csr')
    if os.path.exists(key) and not args.force:
        print('Keeping the existing key (pass --force to replace it)')
    else:
        old_umask = os.umask(0o077)
        try:
            subprocess.run(['openssl', 'genrsa', '-out', key, '2048'], check=True, capture_output=True)
        finally:
            os.umask(old_umask)
    subprocess.run(['openssl', 'req', '-new', '-key', key, '-out', csr, '-subj', '/CN=TelegramDev Push/C=UA'], check=True)
    print('Upload this file to Apple when it asks for a Certificate Signing Request:\n  ' + csr)


def cmd_apns_pem(args):
    key = os.path.join(APNS_DIR, 'apns.key')
    cer = os.path.expanduser(args.cer)
    out = os.path.join(APNS_DIR, 'telegram-apns.pem')
    cert_pem = subprocess.run(['openssl', 'x509', '-inform', 'der', '-in', cer], capture_output=True, text=True, check=True).stdout
    # The certificate must belong to the key from `apns-csr`; compare the public keys.
    cert_pub = subprocess.run(['openssl', 'x509', '-noout', '-pubkey'], input=cert_pem, capture_output=True, text=True, check=True).stdout
    key_pub = subprocess.run(['openssl', 'pkey', '-in', key, '-pubout'], capture_output=True, text=True, check=True).stdout
    if cert_pub.strip() != key_pub.strip():
        sys.exit('This certificate was not made from ~/.config/telegram-ios/apns/apns.csr')
    subject = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-enddate'], input=cert_pem, capture_output=True, text=True).stdout
    with open(key) as f:
        key_pem = f.read()
    old_umask = os.umask(0o077)
    try:
        with open(out, 'w') as f:
            f.write(cert_pem + key_pem)
    finally:
        os.umask(old_umask)
    print(subject.strip())
    print('Upload this file at my.telegram.org/apps (APNS certificate, both sandbox and production):\n  ' + out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('profiles')
    p.add_argument('--team', help='paid team id; saved to the device configuration')
    p.add_argument('--device', help='iPhone UDID (default: the first connected iPhone)')
    p.set_defaults(func=cmd_profiles)
    p = sub.add_parser('apns-csr')
    p.add_argument('--force', action='store_true')
    p.set_defaults(func=cmd_apns_csr)
    p = sub.add_parser('apns-pem')
    p.add_argument('cer', help='the aps.cer downloaded from developer.apple.com')
    p.set_defaults(func=cmd_apns_pem)
    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
