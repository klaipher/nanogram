def _plist_key(key, value):
    return "<key>%s</key>\n%s\n" % (key, value)

def extension_entitlements(team_id, bundle_id, suffix, extras = []):
    return "".join([
        _plist_key(
            "com.apple.security.application-groups",
            "<array>\n    <string>group.%s</string>\n</array>" % bundle_id,
        ),
        _plist_key(
            "application-identifier",
            "<string>%s.%s.%s</string>" % (team_id, bundle_id, suffix),
        ),
    ] + extras)

def enhanced_security_fragment():
    return "".join([
        _plist_key("com.apple.security.hardened-process", "<true/>"),
        _plist_key("com.apple.security.hardened-process.enhanced-security-version-string", "<string>1</string>"),
        _plist_key("com.apple.security.hardened-process.checked-allocations", "<true/>"),
        _plist_key("com.apple.security.hardened-process.checked-allocations.soft-mode", "<true/>"),
    ])

def enhanced_security_restrictions_fragment():
    return "".join([
        _plist_key("com.apple.security.hardened-process.platform-restrictions-string", "<string>2</string>"),
        _plist_key("com.apple.security.hardened-process.dyld-ro", "<true/>"),
    ])
