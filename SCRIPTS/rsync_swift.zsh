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



TRASH_EXCLUDE=""
    if [ "$INCLUDE_TRASH" = false ]; then
        TRASH_EXCLUDE="--exclude=.Trash*"
    fi

echo "RUNNING_AS=$(whoami)" >&2
echo "PWD=$(pwd)" >&2

# Gesamtgröße (KB) der Quelle grob bestimmen
TOTAL_KB=$(du -sk "$USER_FOLDER" 2>/tmp/du_debug.txt | awk 'NR==1{print $1}')

[[ "$TOTAL_KB" =~ '^[0-9]+$' ]] || TOTAL_KB=1

echo "TOTAL_KB=$TOTAL_KB" >&2

# Drive selection is handled by SwiftUI
# -------------------------------------------------------
DRIVE_NAME="$TARGET_DRIVE"

#VALID_VOLUMES=()
#
#for VOL in /Volumes/*; do
#  NAME=$(basename "$VOL")
#
#  # Interne Volumes skippen
#  [[ "$NAME" == "Macintosh HD" ]] && continue
#  [[ "$NAME" == "Preboot" ]] && continue
#  [[ "$NAME" == "VM" ]] && continue
#  [[ "$NAME" == "Recovery" ]] && continue
#
#  # Muss beschreibbar sein
#  [[ ! -w "$VOL" ]] && continue
#
#  VALID_VOLUMES+=("$NAME")
#done
#
## Liste als Text für das eine Dialogfenster bauen
#VOLUME_LIST=""
#for DRIVE in "${VALID_VOLUMES[@]}"; do
#  VOLUME_LIST="${VOLUME_LIST}${DRIVE}\n"
#done
#
## Ein einziges Fenster: Liste + Eingabe
#DRIVE_NAME=$(osascript -e "text returned of (display dialog \"SELECT A BACKUP DRIVE FROM THE LIST:\n\n$VOLUME_LIST\nEnter the EXACT name of the drive to use:\" default answer \"\" buttons {\"Cancel\",\"OK\"} default button \"OK\")")

# Wenn Cancel oder leer -> abbrechen
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

# Rsync mit progress flags
echo "📦 Backing up $USER_FOLDER to $TARGET ..."

rsync -av --partial --human-readable \
    ${DRY_RUN_FLAG:+$DRY_RUN_FLAG} \
    ${DELETE_FLAG:+$DELETE_FLAG} \
    ${TRASH_EXCLUDE:+$TRASH_EXCLUDE} \
    --exclude "*.app" \
    --exclude "Library/CloudStorage" \
    --exclude "Library/NGL" \
    --exclude "Library/Group Containers/group.com.apple.PegasusConfiguration/rawSessions" \
    --exclude "Library/Group Containers/com.apple.MessagesLegacyTransferArchive" \
    --exclude "Library/Caches" \
    --exclude "Library/Google/GoogleSoftwareUpdate" \
    --exclude "Library/Containers/com.apple.VoiceMemos" \
    --exclude "Library/Containers/com.apple.archiveutility" \
    --exclude "Library/Containers/com.apple.Maps" \
    --exclude "Library/Containers/com.apple.Home" \
    --exclude "Library/Containers/com.apple.Safari" \
    --exclude "Library/Containers/com.apple.mail" \
    --exclude "Library/Containers/com.apple.MobileSMS" \
    --exclude "Library/Containers/com.apple.Notes" \
    --exclude "Library/Containers/com.apple.corerecents.recentsd" \
    --exclude "Library/Containers/com.apple.stocks" \
    --exclude "Library/Containers/com.apple.Safari.WebApp" \
    --exclude "Library/Containers/com.apple.configurator.xpc.DeviceService/Data/tmp" \
    --exclude "Library/ContainerManager" \
    --exclude "Library/PersonalizationPortrait" \
    --exclude "Library/Metadata/CoreSpotlight" \
    --exclude "Library/Metadata/com.apple.IntelligentSuggestions" \
    --exclude "Library/Cookies" \
    --exclude "Library/CoreFollowUp" \
    --exclude "Library/StatusKit" \
    --exclude "Library/DoNotDisturb" \
    --exclude "Library/Application Support/FileProvider" \
    --exclude "Library/Mobile Documents" \
    --exclude "Library/Containers/*/.com.apple.containermanagerd.metadata.plist" \
    --exclude "Library/Group Containers/UBF8T346G9.Office/SolutionPackages" \
    --exclude "Library/Preferences/com.apple.AddressBook.plist" \
    --exclude "Library/Preferences/com.apple.MobileSMS.plist" \
    --exclude "Library/Preferences/com.apple.homed.notbackedup.plist" \
    --exclude "Library/Preferences/com.apple.homed.plist" \
    --exclude "Library/Preferences/com.apple.madrid.plist" \
    --exclude "Library/Preferences/com.apple.mail-shared.plist" \
    --exclude "Library/Preferences/com.apple.messages.pinning.plist" \
    --exclude "Library/Group Containers/group.com.apple.CoreSpeech/Caches" \
    --exclude "Library/Group Containers/group.com.apple.secure-control-center-preferences/Library/Preferences/group.com.apple.secure-control-center-preferences.av.plist" \
    --exclude "Library/Group Containers/group.com.apple.*" \
    --exclude "Library/Group Containers/com.apple.*" \
    --exclude "Nextcloud*" \
    "$USER_FOLDER/" "$TARGET/" 2> "$TARGET/rsync_errors.log"
    # --exclude ".Trash*"

RSYNC_EXIT=$?



# wegklickbares Info Fenster

#osascript -e "display dialog \"Relax baby, im syncing..💚\n\nZiel: $TARGET\n\nHinweis: Progress is shown as a Notification every 10%.\" buttons {\"Cancel\",\"OK\"} default button \"OK\" with title \"Backup\"" >/dev/null 2>&1


#CANCEL_FLAG="/tmp/rsync_cancel_${USERNAME}_$$"
#rm -f "$CANCEL_FLAG"

#if [ "$RSYNC_EXIT" -eq 0 ]; then
#  osascript -e "display notification \"Backup abgeschlossen.\" with title \"Backup\""
#else
#  osascript -e "display notification \"Backup beendet (Fehlercode: $RSYNC_EXIT).\" with title \"Backup\""
#fi

if [ "$RSYNC_EXIT" -eq 0 ]; then
  echo "✅ Backup complete! User folder copied to $TARGET"
else
  echo "EXIT CODE: $RSYNC_EXIT (see $TARGET/rsync_errors.log)"
fi


exit "$RSYNC_EXIT"
