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


# Gemeinsame Exclude-Liste — gilt für den Vorab-Scan UND das echte Backup,
# damit beide exakt die gleichen Dateien sehen.
# Merke: ein "/" am Anfang heißt "nur direkt im User-Ordner". Ohne "/" trifft
# das Muster überall, also auch tiefer verschachtelte Ordner gleichen Namens.
RSYNC_EXCLUDES=()
if [ "$INCLUDE_TRASH" = false ]; then
    RSYNC_EXCLUDES+=("--exclude=/.Trash*")
fi
RSYNC_EXCLUDES+=(
    # --- Cloud & Sync ---
    "--exclude=Library/CloudStorage"
    "--exclude=Library/Mobile Documents"
    "--exclude=Library/Application Support/FileProvider"
    "--exclude=Library/Application Support/CloudDocs"
    "--exclude=Library/Group Containers/NKUJUXUJ3B.com.nextcloud.desktopclient"
    "--exclude=/Nextcloud*"

    # --- Browser & Chat-Apps (Chrome, Teams, Webex, Asana usw.): Session files /
    # zwischendateien, die sich dauernd ändern solange die App läuft und beim nächsten Start sowieso neu angelegt werden ---
    "--exclude=Library/Application Support/Google/Chrome/Default/Sessions"
    "--exclude=Library/Application Support/Google/Chrome/GraphiteDawnCache"
    "--exclude=Library/Application Support/Google/Chrome/Safe Browsing"
    "--exclude=Library/Application Support/Google/Chrome/Default/WebStorage/"
    "--exclude=Library/Application Support/Google/Chrome/Default/Service Worker/"
    "--exclude=Library/Application Support/*/IndexedDB/"
    "--exclude=Library/Application Support/*/Local Storage/leveldb/"
    "--exclude=Library/Application Support/*/Session Storage/"
    "--exclude=Library/Application Support/*/Cache/"
    "--exclude=Library/Application Support/*/Code Cache/"
    "--exclude=Library/Application Support/*/GPUCache/"
    "--exclude=Library/Application Support/*/Service Worker/"

    # --- Caches & Logs ---
    "--exclude=Library/Caches"
    "--exclude=Library/NGL"
    "--exclude=Library/Logs/Adobe"
    "--exclude=Library/Logs/NGL"
    "--exclude=Library/Google/GoogleSoftwareUpdate"
    "--exclude=Library/Application Support/com.apple.wallpaper/aerials"

    # --- macOS-Systemdaten (Siri, Vorschläge, Nutzungsstatistik usw.):
    # gehören zu genau diesem Mac, das System legt sie von alleine neu an,
    # und sie ändern sich bei jedem Backup ---
    "--exclude=Library/Biome/"
    "--exclude=Library/Daemon Containers/"
    "--exclude=Library/Metadata/CoreSpotlight"
    "--exclude=Library/Metadata/com.apple.IntelligentSuggestions"
    "--exclude=Library/PersonalizationPortrait"
    "--exclude=Library/ContainerManager"
    "--exclude=Library/StatusKit"
    "--exclude=Library/DoNotDisturb"
    "--exclude=Library/Trial"
    "--exclude=Library/DuetExpertCenter"
    "--exclude=Library/IntelligencePlatform"
    "--exclude=Library/com.apple.aiml.instrumentation"
    "--exclude=Library/Weather"
    "--exclude=Library/Suggestions"
    "--exclude=Library/Application Support/Knowledge"
    "--exclude=Library/Application Support/DifferentialPrivacy"

    # --- Microsoft Office ---
    # nur die Unterordner, die Office selbst wieder herunterlädt:
    "--exclude=Library/Containers/com.microsoft.teams2"
    "--exclude=Library/Containers/com.microsoft.Excel/Data/Library/Application Support/Microsoft/"
    "--exclude=Library/Containers/com.microsoft.Word/Data/Library/Application Support/Microsoft/"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/SolutionPackages"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/FontCache"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/ComRPC32"

    # --- Adobe ---
    "--exclude=Library/Containers/com.adobe.*"

    # --- Apple App-Container: Mail, Safari, etc. sind mitzunehmen
    # Rest sind Systemdienste ohne Wert fürs Backup.
    
    "--exclude=Library/Containers/*/.com.apple.containermanagerd.metadata.plist"
    "--include=Library/Containers/com.apple.mail"
    "--include=Library/Containers/com.apple.mail/**"
    "--include=Library/Containers/com.apple.Safari"
    "--include=Library/Containers/com.apple.Safari/**"
    "--include=Library/Containers/com.apple.Notes"
    "--include=Library/Containers/com.apple.Notes/**"
    "--include=Library/Containers/com.apple.MobileSMS"
    "--include=Library/Containers/com.apple.MobileSMS/**"
    "--exclude=Library/Containers/com.apple.*"

    # --- Apple Group-Container ---
    "--include=Library/Group Containers/group.com.apple.notes"
    "--include=Library/Group Containers/group.com.apple.notes/**"
    "--exclude=Library/Group Containers/group.com.apple.*"
    "--exclude=Library/Group Containers/com.apple.*"


    "--exclude=Library/CoreFollowUp"
    "--exclude=Library/Preferences/com.apple.networkserviceproxy.plist"
    "--exclude=Library/Preferences/com.apple.AddressBook.plist"
    "--exclude=Library/Preferences/com.apple.homed.notbackedup.plist"
    "--exclude=Library/Preferences/com.apple.homed.plist"

    # --- Misc.: Spezialfälle (aus Erfahrung)
    "--exclude=Library/Application Support/Claude/vm_bundles"
    "--exclude=Library/Developer/Xcode/DerivedData"
    "--exclude=Library/Developer/Xcode/iOS DeviceSupport"
    "--exclude=Library/Developer/Xcode/watchOS DeviceSupport"
    "--exclude=Library/Developer/Xcode/tvOS DeviceSupport"
    "--exclude=Library/Developer/Xcode/visionOS DeviceSupport"
    "--exclude=Library/Developer/CoreSimulator/Caches"
    "--exclude=Library/Developer/CoreSimulator/Devices"

)


echo "RUNNING_AS=$(whoami)" >&2
echo "PWD=$(pwd)" >&2

# The du estimate so Swift has a fallback for the space check before the accurate scan completesss
RAW_SOURCE_KB=$(du -sk "$USER_FOLDER" 2>/tmp/du_debug.txt | awk 'NR==1{print $1}')
[[ "$RAW_SOURCE_KB" =~ '^[0-9]+$' ]] || RAW_SOURCE_KB=0
echo "RAW_SOURCE_KB=$RAW_SOURCE_KB" >&2

RAW_FILE_COUNT=$(find "$USER_FOLDER" 2>/dev/null | wc -l | tr -d ' ')
[[ "$RAW_FILE_COUNT" =~ '^[0-9]+$' ]] || RAW_FILE_COUNT=0
echo "RAW_FILE_COUNT=$RAW_FILE_COUNT" >&2

DRIVE_NAME="$TARGET_DRIVE"

[[ -z "$DRIVE_NAME" ]] && echo "ERROR: No drive passed. Usage: rsync_swift.zsh <DriveName>" && exit 2

BACKUP_VOLUME="/Volumes/$DRIVE_NAME"

# Festplatte existiert? beschreibbar?
if [ ! -w "$BACKUP_VOLUME" ]; then
    echo "Cannot write to $BACKUP_VOLUME. Exiting."
    exit 1
fi

TARGET="$BACKUP_VOLUME/$USERNAME"
if [[ -z "$DRY_RUN_FLAG" ]]; then
    mkdir -p "$TARGET"
fi
echo "TARGET=$TARGET" >&2

# Preliminary dry-run scan: computes the actual source size after excludes so
# that Swift can show accurate progress, speed, and ETA instead of the
# inflated du estimate (which includes excluded paths like Caches, CloudStorage).
echo "SCAN_START" >&2
# --out-format='%l %n' records the real byte size of every file this run will
# transfer; Swift sums those sizes for exact progress (no size estimates).
SCAN_LIST=$(mktemp "${TMPDIR:-/tmp}/rsync_scan_list.XXXXXX")
rsync -a --dry-run --stats --modify-window=2 --out-format='%l %n' \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    "${RSYNC_EXCLUDES[@]}" \
    "$USER_FOLDER/" "$TARGET/" >"$SCAN_LIST" 2>/dev/null
echo "SCAN_END" >&2

SCAN_KB=$(awk '/^Total file size:/ { gsub(",", "", $(NF-1)); printf "%d", $(NF-1) / 1024 }' "$SCAN_LIST")
# Bytes rsync will actually move this run — basis for progress and ETA.
XFER_KB=$(awk '/^Total transferred file size:/ { gsub(",", "", $(NF-1)); printf "%d", $(NF-1) / 1024 }' "$SCAN_LIST")

if [[ "$SCAN_KB" =~ ^[0-9]+$ ]] && [ "$SCAN_KB" -gt 0 ]; then
    echo "TOTAL_KB=$SCAN_KB" >&2
fi
[[ "$XFER_KB" =~ ^[0-9]+$ ]] && echo "XFER_KB=$XFER_KB" >&2
if [[ -z "$DRY_RUN_FLAG" ]]; then
    echo "XFER_LIST=$SCAN_LIST" >&2
else
    rm -f "$SCAN_LIST"
fi

# Rsync mit progress flags
echo "📦 Backing up $USER_FOLDER to $TARGET ..."

ERROR_LOG="${DRY_RUN_FLAG:+/tmp/rsync_dryrun_errors.log}"
ERROR_LOG="${ERROR_LOG:-$TARGET/rsync_errors.log}"

rsync -av --no-specials --partial --human-readable --modify-window=2 \
    ${DRY_RUN_FLAG:+$DRY_RUN_FLAG} \
    ${DRY_RUN_FLAG:+--stats} \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    "${RSYNC_EXCLUDES[@]}" \
    "$USER_FOLDER/" "$TARGET/" 2> "$ERROR_LOG" &

RSYNC_PID=$!
# Swift's Cancel sends SIGTERM to this zsh only — forward it, otherwise rsync
# keeps copying (or deleting, in mirror mode) as an orphan.
trap 'kill -TERM "$RSYNC_PID" 2>/dev/null; wait "$RSYNC_PID"; exit 20' TERM INT
wait "$RSYNC_PID"
RSYNC_EXIT=$?
trap - TERM INT

if [ "$RSYNC_EXIT" -eq 0 ]; then
  echo "✅ Backup complete! User folder copied to $TARGET"
else
  echo "EXIT CODE: $RSYNC_EXIT (see $ERROR_LOG)"
fi


exit "$RSYNC_EXIT"
