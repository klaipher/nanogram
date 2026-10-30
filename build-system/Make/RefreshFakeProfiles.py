"""Give the fake provisioning profiles a new validity period.

The profiles in build-system/fake-codesigning/profiles let device builds compile and
link without an Apple developer account (the result cannot be installed). They carry
an ExpirationDate, and rules_apple refuses expired ones ("provisioning profile
ExpirationDate ... is in the past"), so every device build fails once they expire.

This rewrites CreationDate/ExpirationDate and re-signs each profile with the fake
identity in build-system/fake-codesigning/certs/SelfSigned.p12, using the system
openssl, so no keychain is touched.

    python3 build-system/Make/RefreshFakeProfiles.py [--days 365]
"""

import argparse
import datetime
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FAKE = os.path.join(ROOT, 'build-system', 'fake-codesigning')
OPENSSL = '/usr/bin/openssl'  # LibreSSL: reads the legacy-encrypted p12 without -legacy


def refresh(days):
    work = tempfile.mkdtemp(prefix='fake-profiles-')
    try:
        identity = os.path.join(work, 'identity.pem')
        subprocess.run([OPENSSL, 'pkcs12', '-in', os.path.join(FAKE, 'certs', 'SelfSigned.p12'),
                        '-passin', 'pass:', '-nodes', '-out', identity],
                       check=True, capture_output=True)
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        expiration = now + datetime.timedelta(days=days)
        profiles = os.path.join(FAKE, 'profiles')
        for name in sorted(os.listdir(profiles)):
            if not name.endswith('.mobileprovision'):
                continue
            path = os.path.join(profiles, name)
            decoded = subprocess.run(['security', 'cms', '-D', '-i', path],
                                     check=True, capture_output=True).stdout
            profile = plistlib.loads(decoded)
            profile['CreationDate'] = now
            profile['ExpirationDate'] = expiration
            profile['TimeToLive'] = days
            profile.pop('DER-Encoded-Profile', None)
            unsigned = os.path.join(work, name + '.plist')
            with open(unsigned, 'wb') as file:
                plistlib.dump(profile, file)
            subprocess.run([OPENSSL, 'smime', '-sign', '-binary', '-nodetach', '-noattr',
                            '-outform', 'DER', '-in', unsigned, '-signer', identity, '-out', path],
                           check=True, capture_output=True)
            print('{}: valid until {}'.format(name, expiration.isoformat()))
    finally:
        shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument('--days', type=int, default=365, help='validity period (default: 365)')
    refresh(parser.parse_args().days)
    return 0


if __name__ == '__main__':
    sys.exit(main())
