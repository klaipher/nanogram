#!/usr/bin/env python3
"""Signing for installing your own build on your own iPhone with a paid Apple Developer account.

Subcommands:
  profiles   Let Xcode register the app and extension IDs (push + app group) on your team, plus the watch app and
             its widget extension with the App Group group.<bundle id>.watch (the group itself is registered by
             Xcode from the entitlements), and create development provisioning profiles for them, then collect the profiles into
             ~/.config/telegram-ios/codesigning/profiles for `tg device`.
  apns-csr   Create the private key and certificate signing request for the push certificate.
  apns-pem   Combine the downloaded push certificate (aps.cer) with that key into the .pem file
             that my.telegram.org/apps expects, so Telegram's servers can push to your app.
  testflight Wrap a built Telegram.ipa (its bundle is Nanogram.app) into an Xcode archive, let Xcode re-sign it for the App
             Store (distribution certificate and profiles are created automatically) and upload
             it to App Store Connect with the Apple ID signed in to Xcode, or with an App Store
             Connect API team key when asc/asc.json and asc/AuthKey_<key id>.p8 exist. The app
             record must exist in App Store Connect first.

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
ASC_DIR = os.path.join(HOME_DIR, 'asc')
XCODE_PROFILES = os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles')

# Suffixes match build-system/Make/BuildConfiguration.py (profile_name_mapping).
EXTENSIONS = ['.Share', '.NotificationService', '.NotificationContent', '.Widget', '.SiriIntents', '.BroadcastUpload']

# The embedded Apple Watch app and its unread-widget extension (Telegram/WatchApp). They share the App Group
# group.<bundle id>.watch (Shared/WatchUnreadSnapshot.swift), not the phone's group. Names match build-system/Make/BuildConfiguration.py.
WATCH_TARGETS = [('WatchApp', '.watchkitapp'), ('WatchWidget', '.watchkitapp.widget')]


def watch_app_group(app_bundle_id):
    return 'group.{}.watch'.format(app_bundle_id)


def is_watch_bundle(bundle_id, app_bundle_id):
    return any(bundle_id == app_bundle_id + suffix for _, suffix in WATCH_TARGETS)


def target_groups(bundle_id, app_bundle_id):
    """The App Groups one bundle asks for: the watch pair uses its own group, everything else the phone's."""
    if is_watch_bundle(bundle_id, app_bundle_id):
        return [watch_app_group(app_bundle_id)]
    return ['group.' + app_bundle_id]


def payload_app_name(unpacked):
    """The app bundle in an unpacked .ipa: 'Nanogram.app' (Telegram/BUILD bundle_name), found rather than assumed, so an
    .ipa from before the rename (Telegram.app) still works. Exactly one .app must be in Payload/."""
    apps = sorted(name for name in os.listdir(os.path.join(unpacked, 'Payload')) if name.endswith('.app'))
    if len(apps) != 1:
        sys.exit('expected one .app in %s/Payload, found %s' % (unpacked, apps or 'none'))
    return apps[0]


def exported_ipa(out_dir):
    """The one .ipa xcodebuild exported; its name follows the app's CFBundleName (Nanogram.ipa), not Bazel's target."""
    ipas = sorted(glob.glob(os.path.join(out_dir, '*.ipa')))
    if len(ipas) != 1:
        sys.exit('Expected one exported .ipa in %s, found %s' % (out_dir, [os.path.basename(p) for p in ipas] or 'none'))
    return ipas[0]


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


# Enhanced Security (soft mode) as Telegram/entitlements.bzl signs it; the App IDs of these three have the capability.
ENHANCED_SECURITY_SUFFIXES = ['', '.NotificationService', '.Share']
ENHANCED_SECURITY_ENTRIES = [
    '<key>com.apple.security.hardened-process</key><true/>',
    '<key>com.apple.security.hardened-process.enhanced-security-version-string</key><string>1</string>',
    '<key>com.apple.security.hardened-process.checked-allocations</key><true/>',
    '<key>com.apple.security.hardened-process.checked-allocations.soft-mode</key><true/>',
]


def wants_enhanced_security(bundle_id, app_bundle_id):
    return any(bundle_id == app_bundle_id + suffix for suffix in ENHANCED_SECURITY_SUFFIXES)


HARDENED_PROCESS_KEY = 'com.apple.security.hardened-process'
ENHANCED_SECURITY_REQUIRED = {
    HARDENED_PROCESS_KEY: True,
    'com.apple.security.hardened-process.enhanced-security-version-string': '1',
    'com.apple.security.hardened-process.checked-allocations': True,
    'com.apple.security.hardened-process.checked-allocations.soft-mode': True,
}


def enhanced_security_problems(label, signed, profile=None):
    """What is missing for one bundle: its signed entitlements, and (when given) what its profile grants."""
    problems = []
    for key, value in ENHANCED_SECURITY_REQUIRED.items():
        if signed.get(key) != value:
            problems.append('{}: signed without {} = {}'.format(label, key, value))
    if profile is not None and profile.get(HARDENED_PROCESS_KEY) is not True:
        problems.append('{}: its provisioning profile does not grant {}'.format(label, HARDENED_PROCESS_KEY))
    return problems


def codesign_entitlements(bundle):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', bundle], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return {}


def embedded_profile_entitlements(bundle):
    path = os.path.join(bundle, 'embedded.mobileprovision')
    if not os.path.exists(path):
        return None
    return read_profile(path).get('Entitlements', {})


def app_enhanced_security_problems(app, check_profiles, entitlements_of=codesign_entitlements,
                                   profile_of=embedded_profile_entitlements):
    """Problems of the three hardened bundles (app, NotificationService, Share) inside an .app."""
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        app_id = plistlib.load(f)['CFBundleIdentifier']
    found = {app_id: app}
    for appex in sorted(glob.glob(os.path.join(app, 'PlugIns', '*.appex'))):
        with open(os.path.join(appex, 'Info.plist'), 'rb') as f:
            found[plistlib.load(f)['CFBundleIdentifier']] = appex
    problems = []
    for suffix in ENHANCED_SECURITY_SUFFIXES:
        bundle_id = app_id + suffix
        if bundle_id not in found:
            problems.append('{}: the bundle is not in the app'.format(bundle_id))
            continue
        profile = None
        if check_profiles:
            profile = profile_of(found[bundle_id])
            if profile is None:
                problems.append('{}: no embedded provisioning profile to check'.format(bundle_id))
        problems += enhanced_security_problems(bundle_id, entitlements_of(found[bundle_id]), profile)
    return problems


def require_enhanced_security(app, check_profiles, stage, entitlements_of=codesign_entitlements,
                              profile_of=embedded_profile_entitlements):
    problems = app_enhanced_security_problems(app, check_profiles, entitlements_of, profile_of)
    if not problems:
        print('Enhanced Security (soft mode) present on the app, NotificationService and Share ({}).'.format(stage), flush=True)
        return
    sys.exit('Enhanced Security is missing {}:\n  {}\n'
             'Nothing was uploaded. The three App IDs (app, .NotificationService, .Share) need the Enhanced Security '
             'capability in the developer portal and the profiles regenerated '
             '(tools/dev/device_signing.py profiles, then let Xcode create the distribution profiles). '
             'To ship without it on purpose: TG_TF_ENHANCED_SECURITY=0 tools/dev/tg testflight ...'.format(
                 stage, '\n  '.join(problems)))


def wants_time_sensitive(bundle_id, app_bundle_id):
    return any(bundle_id == app_bundle_id + suffix for suffix in ['', '.NotificationService'])


def entitlements_plist(groups, push, communication=False, enhanced_security=False, time_sensitive=False):
    entries = ['<key>com.apple.security.application-groups</key><array><string>{}</string></array>'.format(g) for g in groups]
    if communication:
        # The main app is signed with it (Telegram/BUILD, communication_notifications_bundle_ids); a profile
        # without it makes the phone refuse the install (0xe8008015).
        entries.append('<key>com.apple.developer.usernotifications.communication</key><true/>')
    if time_sensitive:
        # The app and the NotificationService extension are signed with it (Telegram/BUILD,
        # time_sensitive_notifications_bundle_ids); a profile without it makes the phone refuse the install.
        entries.append('<key>com.apple.developer.usernotifications.time-sensitive</key><true/>')
    if enhanced_security:
        entries += ENHANCED_SECURITY_ENTRIES
    if push:
        # Development profiles only ever grant development push. The release_arm64 build `tg device`
        # signs with them registers its token with Telegram as production, so such an install gets
        # no pushes; `tg device` warns about it. TestFlight builds are re-signed with production push.
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
            f.write(entitlements_plist(target_groups(bundle_id, targets[0][1]), push, communication=(bundle_id == targets[0][1]),
                                       enhanced_security=wants_enhanced_security(bundle_id, targets[0][1]),
                                       time_sensitive=wants_time_sensitive(bundle_id, targets[0][1])))
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
        '{} = {{isa = XCBuildConfiguration; buildSettings = {{SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 26.0; SWIFT_VERSION = 5.0; }}; name = Debug; }};'.format(project_config),
        '{} = {{isa = XCConfigurationList; buildConfigurations = ({}); defaultConfigurationName = Debug; }};'.format(project_config_list, project_config),
        '{} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; }}; buildConfigurationList = {}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {}; productRefGroup = {}; projectDirPath = ""; projectRoot = ""; targets = ({}); }};'.format(project, project_config_list, main_group, products_group, ', '.join(target_ids)),
    ]
    with open(os.path.join(directory, 'App.xcodeproj', 'project.pbxproj'), 'w') as f:
        f.write('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n\t\t'
                + '\n\t\t'.join(objects) + '\n\t};\n\trootObject = ' + project + ';\n}\n')


def physical_devices(devicectl_output):
    devices = []
    for line in devicectl_output.splitlines():
        parts = line.split()
        if 'physical' not in parts:
            continue
        udid = next((part for part in parts if len(part) == 25 and part[8] == '-'), None)
        if udid:
            devices.append((udid, 'connected' in parts, 'iPhone' in line))
    return devices


def first_physical_device(devicectl_output=None):
    """A connected iPhone first, then any connected device, then any physical one (an unavailable iPad listed first
    would otherwise be picked and xcodebuild fails to find its destination)."""
    if devicectl_output is None:
        devicectl_output = subprocess.run(['xcrun', 'devicectl', 'list', 'devices'], capture_output=True, text=True).stdout
    devices = physical_devices(devicectl_output)
    for wanted in (lambda d: d[1] and d[2], lambda d: d[1], lambda d: True):
        for device in devices:
            if wanted(device):
                return device[0]
    return None


def profile_targets(bundle_id):
    """(name, bundle id, push) of every bundle that gets a profile: the app, its extensions, the watch app and its widget."""
    return ([('Telegram', bundle_id, True)] + [(suffix[1:], bundle_id + suffix, False) for suffix in EXTENSIONS]
            + [(name, bundle_id + suffix, False) for name, suffix in WATCH_TARGETS])


def cmd_profiles(args):
    config = load_config()
    if args.team:
        config['team_id'] = args.team
        save_config(config)
    team_id, bundle_id = config['team_id'], config['bundle_id']
    device = args.device or first_physical_device()
    if device is None:
        sys.exit('No iPhone found: connect it (cable or same Wi-Fi) and unlock it')

    targets = profile_targets(bundle_id)
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


def adhoc_sign_unsigned_watch_code(app):
    """Give unsigned code inside the embedded watch app an ad-hoc signature.

    Without a watch provisioning profile the build embeds the watch app unsigned. App Store export
    re-signs bundles it can see, but leaves nested frameworks that were never signed as they are,
    and the upload then fails with ITMS-90035 on Watch/<app>/Frameworks/TDLibFramework.framework.
    Ad-hoc signing them first lets export re-sign everything with the distribution certificate.
    """
    for watch_app in glob.glob(os.path.join(app, 'Watch', '*.app')):
        frameworks = glob.glob(os.path.join(watch_app, 'Frameworks', '*.framework')) + \
            glob.glob(os.path.join(watch_app, 'Frameworks', '*.dylib'))
        signed_any = False
        for item in frameworks:
            if subprocess.run(['codesign', '--verify', item], capture_output=True).returncode != 0:
                subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', item], check=True)
                signed_any = True
        if signed_any or subprocess.run(['codesign', '--verify', watch_app], capture_output=True).returncode != 0:
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', watch_app], check=True)
            print('Ad-hoc signed the embedded watch app for App Store re-signing: ' + os.path.basename(watch_app), flush=True)


def app_store_connect_key():
    """The App Store Connect API key, if one is configured, else None.

    asc/asc.json holds {"key_id": "...", "issuer_id": "..."} next to asc/AuthKey_<key_id>.p8. It must be a
    team key with the Admin role: only Admin may use the cloud-managed distribution certificate. With a key,
    uploads do not depend on the Apple ID signed in to Xcode.
    """
    config_path = os.path.join(ASC_DIR, 'asc.json')
    if not os.path.exists(config_path):
        return None
    with open(config_path) as f:
        config = json.load(f)
    key_path = os.path.join(ASC_DIR, 'AuthKey_{}.p8'.format(config['key_id']))
    if not os.path.exists(key_path):
        sys.exit('App Store Connect key file not found: ' + key_path)
    return {'path': key_path, 'id': config['key_id'], 'issuer': config['issuer_id']}


def cmd_testflight(args):
    import tempfile
    import zipfile
    config = load_config()
    team_id = config['team_id']
    work = tempfile.mkdtemp(prefix='testflight-')
    archive = os.path.join(work, 'Nanogram.xcarchive')
    apps_dir = os.path.join(archive, 'Products', 'Applications')
    os.makedirs(apps_dir)
    os.makedirs(os.path.join(archive, 'dSYMs'))
    # ditto keeps symlinks and permissions inside the bundles.
    unpacked = os.path.join(work, 'ipa')
    subprocess.run(['ditto', '-x', '-k', args.ipa, unpacked], check=True)
    app_name = payload_app_name(unpacked)
    app = os.path.join(apps_dir, app_name)
    subprocess.run(['ditto', os.path.join(unpacked, 'Payload', app_name), app], check=True)
    adhoc_sign_unsigned_watch_code(app)
    if args.enhanced_security == 'require':
        require_enhanced_security(app, False, 'in the built app, before export')
    for dsym in glob.glob(os.path.join(os.path.dirname(os.path.realpath(args.ipa)), '*.dSYM')):
        subprocess.run(['ditto', dsym, os.path.join(archive, 'dSYMs', os.path.basename(dsym))], check=True)
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        info = plistlib.load(f)
    import datetime
    with open(os.path.join(archive, 'Info.plist'), 'wb') as f:
        plistlib.dump({
            'ApplicationProperties': {
                'ApplicationPath': 'Applications/' + app_name,
                'Architectures': ['arm64'],
                'CFBundleIdentifier': info['CFBundleIdentifier'],
                'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                'CFBundleVersion': info['CFBundleVersion'],
                'SigningIdentity': 'Apple Development',
                'Team': team_id,
            },
            'ArchiveVersion': 2,
            'CreationDate': datetime.datetime.now(datetime.timezone.utc),
            'Name': 'Nanogram',
            'SchemeName': 'Nanogram',
        }, f)
    key = app_store_connect_key()
    # With an API key xcodebuild can sign but its upload is refused ("Cannot verify client's JWT headers"),
    # so it only exports and altool uploads the signed package with the same key.
    xcodebuild_uploads = not args.export_only and key is None
    if xcodebuild_uploads and args.enhanced_security == 'require':
        sys.exit('The Enhanced Security check must run between export and upload, which needs the App Store Connect '
                 'API key (asc/asc.json); without one xcodebuild uploads by itself. Add the key, use --export-only, '
                 'or pass --enhanced-security off.')
    options = os.path.join(work, 'ExportOptions.plist')
    with open(options, 'wb') as f:
        plistlib.dump({
            'method': 'app-store-connect',
            'destination': 'upload' if xcodebuild_uploads else 'export',
            'teamID': team_id,
            'signingStyle': 'automatic',
            'uploadSymbols': True,
            'manageAppVersionAndBuildNumber': False,
        }, f)
    print('{} {} {} ({})'.format('Exporting' if args.export_only else 'Uploading', info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion']), flush=True)
    command = ['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportOptionsPlist', options,
               '-exportPath', os.path.join(work, 'out'), '-allowProvisioningUpdates']
    if key is not None:
        print('Using App Store Connect API key ' + key['id'], flush=True)
        command += ['-authenticationKeyPath', key['path'], '-authenticationKeyID', key['id'],
                    '-authenticationKeyIssuerID', key['issuer']]
    result = subprocess.run(command)
    if result.returncode != 0:
        sys.exit('Export failed; logs are in ' + work)
    if args.enhanced_security == 'require':
        exported = exported_ipa(os.path.join(work, 'out'))
        check_dir = os.path.join(work, 'exported')
        subprocess.run(['ditto', '-x', '-k', exported, check_dir], check=True)
        require_enhanced_security(os.path.join(check_dir, 'Payload', payload_app_name(check_dir)), True,
                                  'in the exported App Store build')
    if not args.export_only and not xcodebuild_uploads:
        env = dict(os.environ, API_PRIVATE_KEYS_DIR=ASC_DIR)
        result = subprocess.run(['xcrun', 'altool', '--upload-app', '-f', exported_ipa(os.path.join(work, 'out')),
                                 '-t', 'ios', '--apiKey', key['id'], '--apiIssuer', key['issuer']], env=env)
        if result.returncode != 0:
            sys.exit('Upload failed; logs are in ' + work)
    if args.export_only:
        print('Signed for the App Store (not uploaded): ' + os.path.join(work, 'out'))
    else:
        print('Uploaded. The build appears in App Store Connect > TestFlight after Apple processes it (10-30 min).')
    print(finish_testflight_work(work, uploaded=not args.export_only))


def finish_testflight_work(work, uploaded):
    """An uploaded build's staging folder (archive, .ipa, signed package: ~2 GB) is removed; the dSYMs are kept by
    `tg testflight` elsewhere. An export-only build keeps it, since the signed package is the result. A failed export
    or upload exits before this and keeps it for the logs."""
    if uploaded:
        shutil.rmtree(work, ignore_errors=True)
        return 'Removed the work files in ' + work
    return 'Work files: ' + work


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
    p = sub.add_parser('testflight')
    p.add_argument('ipa', nargs='?', default='bazel-bin/Telegram/Telegram.ipa')
    p.add_argument('--export-only', action='store_true', help='sign for the App Store but do not upload')
    p.add_argument('--enhanced-security', choices=['require', 'off'], default='require',
                   help='require (default): fail unless the app, NotificationService and Share keep the hardened-process '
                        'entitlements and their distribution profiles grant them')
    p.set_defaults(func=cmd_testflight)
    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
