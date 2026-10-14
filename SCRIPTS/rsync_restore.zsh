#!/bin/zsh

DRY_RUN_FLAG=""
DELETE_FLAG=""
SKIP_PATHS=()

BACKUP_FOLDER="$1"
shift

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN_FLAG="--dry-run"
      ;;
    --delete)
      DELETE_FLAG="--delete"
      ;;
    --skip-path=*)
      SKIP_PATHS+=("${arg#--skip-path=}")
      ;;
  esac
done

TARGET_USER=$(whoami)
TARGET_FOLDER="/Users/$TARGET_USER"

echo "RUNNING_AS=$TARGET_USER" >&2

[[ -z "$BACKUP_FOLDER" ]] && echo "ERROR: No backup folder path passed. Usage: rsync_restore.zsh <BackupFolderPath>" && exit 2
[[ ! -d "$BACKUP_FOLDER" ]] && echo "ERROR: Backup folder not found: $BACKUP_FOLDER" && exit 2

TOTAL_KB=$(du -sk "$BACKUP_FOLDER" 2>/dev/null | awk 'NR==1{print $1}')
[[ "$TOTAL_KB" =~ '^[0-9]+$' ]] || TOTAL_KB=1
echo "TOTAL_KB=$TOTAL_KB" >&2
echo "RAW_SOURCE_KB=$TOTAL_KB" >&2
echo "SOURCE=$BACKUP_FOLDER" >&2

FILE_COUNT=$(find "$BACKUP_FOLDER" -not -type d 2>/dev/null | wc -l | tr -d ' ')
[[ "$FILE_COUNT" =~ '^[0-9]+$' ]] || FILE_COUNT=0
echo "FILE_COUNT=$FILE_COUNT" >&2

echo "🔄 Restoring from $BACKUP_FOLDER to $TARGET_FOLDER ..."

# Exclude-Liste fürs Zurückspielen. Absichtlich eine eigene Liste (nicht die
# vom Backup-Script): beim Restore dürfen zusätzlich Dinge nicht angefasst
# werden, die macOS beim ersten Login selbst anlegt.
# Merke: ein "/" am Anfang heißt "nur direkt im User-Ordner". Ohne "/" trifft
# das Muster überall, also auch tiefer verschachtelte Ordner gleichen Namens.
RSYNC_EXCLUDES=(
    # --- Cloud & Sync ---
    "--exclude=Library/CloudStorage"
    "--exclude=Library/Mobile Documents"
    "--exclude=Library/Application Support/FileProvider"
    "--exclude=Library/Application Support/CloudDocs"
    "--exclude=Library/Group Containers/NKUJUXUJ3B.com.nextcloud.desktopclient"
    "--exclude=/Nextcloud*"

    # --- Browser & Chat-Apps (Chrome, Teams, Webex, Asana usw.): Session files /
    # zwischendateien, die sich dauernd ändern solange die App läuft und beim
    # nächsten Start sowieso neu angelegt werden ---
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

    # --- Dateien, die macOS beim ersten Login selbst anlegt: nicht anfassen,
    # sonst gibt es Fehler bzw. der Spiegel-Modus würde sie löschen ---
    "--exclude=/.Trash*"
    "--exclude=/.localized"
    # exakt der Ordner "iCloud Drive" — NICHT mit Muster, sonst wäre auch
    # ein echter Ordner wie "iCloud Drive (Archiv)" vom Restore ausgeschlossen
    "--exclude=/iCloud Drive/"
    "--exclude=/.CFUserTextEncoding"
    "--exclude=/.bash_history"
    "--exclude=/.zsh_history"
    "--exclude=/.zsh_sessions"

    # --- Caches & Logs ---
    "--exclude=.DS_Store"
    "--exclude=Library/Caches"
    "--exclude=Library/NGL"
    "--exclude=Library/Logs/Adobe"
    "--exclude=Library/Logs/NGL"
    "--exclude=Library/Logs/DiagnosticReports/Retired"
    "--exclude=Library/Application Support/Adobe/Common/Media Cache Files"
    "--exclude=Library/Application Support/Adobe/Common/Media Cache"
    "--exclude=Library/Application Support/Adobe/Common/Peak Files"
    "--exclude=Library/Google/GoogleSoftwareUpdate"
    "--exclude=Library/Application Support/com.apple.wallpaper/aerials"

    # --- macOS-Systemdaten (Siri, Vorschläge, Nutzungsstatistik usw.):
    # gehören zu genau diesem Mac, das System legt sie von alleine neu an ---
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
    "--exclude=Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/SolutionPackagesLock"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/TemporaryItems"
    "--exclude=Library/Group Containers/UBF8T346G9.Office/.com.apple.containermanagerd.metadata.plist"

    # --- Adobe ---
    "--exclude=Library/Containers/com.adobe.*"

    # --- Apple App-Container: Mail, Safari, etc. sind mitzunehmen
    # der Rest sind Systemdienste ohne Wert fürs Backup.

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

for skip in "${SKIP_PATHS[@]}"; do
    RSYNC_EXCLUDES+=("--exclude=$skip")
done

# Measure home with the same RSYNC_EXCLUDES, emitted as sentinels for the dry-run summary.
# Runs here so Swift always gets the value before rsync output starts.
if [[ -n "$DRY_RUN_FLAG" ]]; then
    HOME_RAW_KB=$(/usr/bin/du -sk "$TARGET_FOLDER" 2>/dev/null | /usr/bin/awk 'NR==1{print $1}')
    echo "HOME_RAW_KB=${HOME_RAW_KB:-0}" >&2

    setopt nullglob
    EXCLUDED_PATHS=()
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        pat="${excl#--exclude=}"
        pat="${pat%/}"
        [[ "$pat" == */* ]] || continue          # skip bare filename patterns
        for fp in "$TARGET_FOLDER"/$~pat(N/); do # (N/) = nullglob, dirs only
            EXCLUDED_PATHS+=("$fp")
        done
    done
    unsetopt nullglob
    EXCLUDED_PATHS=(${(u)EXCLUDED_PATHS})          # deduplicate

    EXCLUDED_KB=0
    if [[ ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
        EXCLUDED_KB=$(/usr/bin/du -sk -- "${EXCLUDED_PATHS[@]}" 2>/dev/null | /usr/bin/awk '{s+=$1} END{print s+0}')
    fi
    HOME_SCOPED_KB=$(( HOME_RAW_KB > EXCLUDED_KB ? HOME_RAW_KB - EXCLUDED_KB : 0 ))
    echo "HOME_SCOPED_KB=$HOME_SCOPED_KB" >&2
fi

# Pre-scan (real restores only; a dry run already emits --stats itself):
# bytes/files rsync will actually move, the basis for progress and ETA.
if [[ -z "$DRY_RUN_FLAG" ]]; then
    echo "SCAN_START" >&2
    # --out-format='%l %n' records the real byte size of every file this run
    # will transfer; Swift sums those sizes for exact progress.
    SCAN_LIST=$(mktemp "${TMPDIR:-/tmp}/rsync_scan_list.XXXXXX")
    rsync -a --dry-run --stats --modify-window=2 --out-format='%l %n' \
        ${DELETE_FLAG:+$DELETE_FLAG} \
        "${RSYNC_EXCLUDES[@]}" \
        "$BACKUP_FOLDER/" "$TARGET_FOLDER/" >"$SCAN_LIST" 2>/dev/null
    echo "SCAN_END" >&2
    XFER_KB=$(awk '/^Total transferred file size:/ { gsub(",", "", $(NF-1)); printf "%d", $(NF-1) / 1024 }' "$SCAN_LIST")
    [[ "$XFER_KB" =~ ^[0-9]+$ ]] && echo "XFER_KB=$XFER_KB" >&2
    echo "XFER_LIST=$SCAN_LIST" >&2
fi

rsync -av --no-specials --partial --ignore-errors --human-readable --modify-window=2 \
    ${DRY_RUN_FLAG:+$DRY_RUN_FLAG} \
    ${DRY_RUN_FLAG:+--stats} \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    "${RSYNC_EXCLUDES[@]}" \
    "$BACKUP_FOLDER/" "$TARGET_FOLDER/" 2>"$HOME/Desktop/RsyncRettung_restore_errors.log" &

RSYNC_PID=$!
# Swift's Cancel sends SIGTERM to this zsh only — forward it, otherwise rsync
# keeps restoring (or deleting, in mirror mode) as an orphan.
trap 'kill -TERM "$RSYNC_PID" 2>/dev/null; wait "$RSYNC_PID"; exit 20' TERM INT
wait "$RSYNC_PID"
RSYNC_EXIT=$?
trap - TERM INT

if [ "$RSYNC_EXIT" -eq 0 ]; then
    echo "✅ Restore complete!"
elif [[ "$RSYNC_EXIT" -ne 12 && "$RSYNC_EXIT" -ne 23 && "$RSYNC_EXIT" -ne 24 ]]; then
    echo "❌ Restore failed (code: $RSYNC_EXIT)"
fi

exit "$RSYNC_EXIT"
