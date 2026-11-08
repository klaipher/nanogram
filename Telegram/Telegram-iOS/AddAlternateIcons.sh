set -euo pipefail

ADD_PLIST="${0}.runfiles/__main__/Telegram/Telegram-iOS/AlternateIcons.plist"
ADD_PLIST_IPAD="${0}.runfiles/__main__/Telegram/Telegram-iOS/AlternateIcons-iPad.plist"

# The app bundle is Nanogram.app (Telegram/BUILD bundle_name); find it rather than assume its name.
INFO_PLIST=""
for candidate in "$1"/Payload/*.app/Info.plist "$1"/*.app/Info.plist; do
	if [ -f "$candidate" ]; then
		INFO_PLIST="$candidate"
		break
	fi
done
if [ -z "$INFO_PLIST" ]; then
	echo "AddAlternateIcons: no app bundle in $1" >&2
	exit 1
fi

/usr/libexec/PlistBuddy -c "add :CFBundleIcons:CFBundleAlternateIcons dict" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "add :CFBundleIcons~ipad:CFBundleAlternateIcons dict" "$INFO_PLIST"

/usr/libexec/PlistBuddy -c "merge $ADD_PLIST :CFBundleIcons:CFBundleAlternateIcons" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "merge $ADD_PLIST_IPAD :CFBundleIcons~ipad:CFBundleAlternateIcons" "$INFO_PLIST"
