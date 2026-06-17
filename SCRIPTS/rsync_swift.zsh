#!/bin/zsh
########################################################

# Test mit dem neuen rsync installiert von homebrew:

# sudo /opt/homebrew/bin/rsync -aAXHv --progress --info=progress2 \
# --exclude "Nextcloud" /Users/mustafa.sibak /Volumes/Mustafa-1208492

# backup script (user ordner) excluding Nextcloud

########################################################
DELETE_FLAG=""
INCLUDE_TRASH=false
DRY_RUN_FLAG=""


USER_FOLDER="/Users/$(whoami)"
USERNAME=$(whoami)


TARGET_DRIVE="$1"
shift


for arg in "$@"; do
  case "$arg" in
    --delete)
      DELETE_FLAG="--delete"
      ;;
    --include-trash)
      INCLUDE_TRASH=true
      ;;
    --dry-run)
      DRY_RUN_FLAG="--dry-run"
      ;;
  esac
done


# Shared exclude list — used for both the preliminary scan and the real backup
# so that both see exactly the same files.
RSYNC_EXCLUDES=()
if [ "$INCLUDE_TRASH" = false ]; then
    RSYNC_EXCLUDES+=("--exclude=.Trash*")
fi
RSYNC_EXCLUDES+=(
    "--exclude=Library/CloudStorage"
    "--exclude=Library/NGL"
    "--exclude=Library/Group Containers/group.com.apple.PegasusConfiguration/rawSessions"
    "--exclude=Library/Group Containers/com.apple.MessagesLegacyTransferArchive"
    "--exclude=Library/Caches"
    "--exclude=Library/Google/GoogleSoftwareUpdate"
    "--exclude=Library/Containers/com.adobe.*"
    "--exclude=Library/Containers/com.microsoft.teams2"
    "--exclude=Library/Group Containers/NKUJUXUJ3B.com.nextcloud.desktopclient"
    "--exclude=Library/Logs/Adobe"
    "--exclude=Library/Logs/NGL"
    "--exclude=Library/Application Support/Google/Chrome/Default/Sessions"
    "--exclude=Library/Application Support/Google/Chrome/GraphiteDawnCache"
    "--exclude=Library/Application Support/Google/Chrome/Safe Browsing"
    "--exclude=Library/Containers/com.apple.VoiceMemos"
    "--exclude=Library/Containers/com.apple.archiveutility"
    "--exclude=Library/Containers/com.apple.Maps"
    "--exclude=Library/Containers/com.apple.Home"
    "--exclude=Library/Containers/com.apple.corerecents.recentsd"
    "--exclude=Library/Containers/com.apple.stocks"
    "--exclude=Library/Containers/com.apple.Safari.WebApp"
    "--exclude=Library/Containers/com.apple.configurator.xpc.DeviceService/Data/tmp"
    "--exclude=Library/Containers/com.apple.geod/Data/tmp"
    "--exclude=Library/ContainerManager"
    "--exclude=Library/PersonalizationPortrait"
    "--exclude=Library/Metadata/CoreSpotlight"
    "--exclude=Library/Metadata/com.apple.IntelligentSuggestions"
    "--exclude=Library/Cookies"
    "--exclude=Library/CoreFollowUp"
    "--exclude=Library/StatusKit"
    "--exclude=Library/DoNotDisturb"
    "--exclude=Library/Application Support/FileProvider"
    "--exclude=Library/Mobile Documents"
    "--exclude=Library/Containers/*/.com.apple.containermanagerd.metadata.plist"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/SolutionPackages"
    "--exclude=Library/Preferences/com.apple.AddressBook.plist"
    "--exclude=Library/Preferences/com.apple.MobileSMS.plist"
    "--exclude=Library/Preferences/com.apple.homed.notbackedup.plist"
    "--exclude=Library/Preferences/com.apple.homed.plist"
    "--exclude=Library/Preferences/com.apple.madrid.plist"
    "--exclude=Library/Preferences/com.apple.mail-shared.plist"
    "--exclude=Library/Preferences/com.apple.messages.pinning.plist"
    "--exclude=Library/Group Containers/group.com.apple.CoreSpeech/Caches"
    "--exclude=Library/Group Containers/group.com.apple.secure-control-center-preferences/Library/Preferences/group.com.apple.secure-control-center-preferences.av.plist"
    "--exclude=Library/Group Containers/group.com.apple.*"
    "--exclude=Library/Group Containers/com.apple.*"
    "--exclude=Nextcloud*"
)


echo "RUNNING_AS=$(whoami)" >&2
echo "PWD=$(pwd)" >&2

# The du estimate so Swift has a fallback for the space check before the accurate scan completesss
TOTAL_KB=$(du -sk "$USER_FOLDER" 2>/tmp/du_debug.txt | awk 'NR==1{print $1}')

[[ "$TOTAL_KB" =~ '^[0-9]+$' ]] || TOTAL_KB=1

echo "TOTAL_KB=$TOTAL_KB" >&2

DRIVE_NAME="$TARGET_DRIVE"

[[ -z "$DRIVE_NAME" ]] && echo "ERROR: No drive passed. Usage: rsync_swift.zsh <DriveName>" && exit 2

BACKUP_VOLUME="/Volumes/$DRIVE_NAME"

# Festplatte existiert? beschreibbar?
if [ ! -w "$BACKUP_VOLUME" ]; then
    echo "Cannot write to $BACKUP_VOLUME. Exiting."
    exit 1
fi

# Ziel Ordner erstellen (/Volumes/festplatte/vorname.nachname)
TARGET="$BACKUP_VOLUME/$USERNAME"
mkdir -p "$TARGET"
echo "TARGET=$TARGET" >&2

# Preliminary dry-run scan: computes the actual source size after excludes so
# that Swift can show accurate progress, speed, and ETA instead of the
# inflated du estimate (which includes excluded paths like Caches, CloudStorage).
echo "SCAN_START" >&2
SCAN_KB=$(rsync -a --dry-run --stats \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    "${RSYNC_EXCLUDES[@]}" \
    "$USER_FOLDER/" "$TARGET/" 2>/dev/null | \
    awk '/^Total file size:/ { gsub(",", "", $(NF-1)); printf "%d", $(NF-1) / 1024 }')
echo "SCAN_END" >&2

if [[ "$SCAN_KB" =~ ^[0-9]+$ ]] && [ "$SCAN_KB" -gt 0 ]; then
    echo "TOTAL_KB=$SCAN_KB" >&2
fi

# Rsync mit progress flags
echo "📦 Backing up $USER_FOLDER to $TARGET ..."

rsync -av --no-specials --partial --human-readable \
    ${DRY_RUN_FLAG:+$DRY_RUN_FLAG} \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    "${RSYNC_EXCLUDES[@]}" \
    "$USER_FOLDER/" "$TARGET/" 2> "$TARGET/rsync_errors.log"

RSYNC_EXIT=$?

if [ "$RSYNC_EXIT" -eq 0 ]; then
  echo "✅ Backup complete! User folder copied to $TARGET"
else
  echo "EXIT CODE: $RSYNC_EXIT (see $TARGET/rsync_errors.log)"
fi


exit "$RSYNC_EXIT"
