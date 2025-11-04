#!/bin/bash

# 🧩 Load configuration file
if [ ! -f ./backup.config ]; then
    echo "Error: Configuration file backup.config not found!"
    exit 1
fi
source ./backup.config

# 🧩 Log & Email file paths
LOG_FILE="./backup.log"
EMAIL_FILE="./email.txt"

# 🧩 Lock file to prevent multiple runs
LOCK_FILE="/tmp/backup.lock"

# 🧩 Function for logging
log_message() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $LEVEL: $MESSAGE" | tee -a "$LOG_FILE"
}

# 🧩 Simulate email notification
send_email() {
    local SUBJECT=$1
    local BODY=$2
    echo "-----" >> "$EMAIL_FILE"
    echo "To: $EMAIL_RECIPIENT" >> "$EMAIL_FILE"
    echo "Subject: $SUBJECT" >> "$EMAIL_FILE"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$EMAIL_FILE"
    echo "" >> "$EMAIL_FILE"
    echo "$BODY" >> "$EMAIL_FILE"
    echo "-----" >> "$EMAIL_FILE"
}

# 🧩 Acquire lock
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log_message "ERROR" "Another backup process is already running!"
        exit 1
    fi
    touch "$LOCK_FILE"
}

# 🧩 Release lock
release_lock() {
    rm -f "$LOCK_FILE"
}

# 🧩 Check disk space before backup
check_space() {
    local required_space_mb="${MIN_SPACE_MB:-100}"
    local available_space_mb
    available_space_mb=$(df --output=avail -m . | tail -n 1)

    if (( available_space_mb < required_space_mb )); then
        log_message "ERROR" "Not enough disk space. Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
        send_email "❌ Backup Failed - Low Disk Space" "Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
        release_lock
        exit 1
    else
        log_message "INFO" "Sufficient disk space available: ${available_space_mb}MB"
    fi
}

# 🧩 Create backup
create_backup() {
    local SOURCE_DIR=$1
    local DRY_RUN=$2

    if [ ! -d "$SOURCE_DIR" ]; then
        log_message "ERROR" "Source folder not found: $SOURCE_DIR"
        send_email "❌ Backup Failed - Source Missing" "Source folder not found: $SOURCE_DIR"
        release_lock
        exit 1
    fi

    check_space

    mkdir -p "$BACKUP_DESTINATION"
    local TIMESTAMP=$(date +%Y-%m-%d-%H%M)
    local BACKUP_NAME="backup-$TIMESTAMP.tar.gz"
    local BACKUP_PATH="$BACKUP_DESTINATION/$BACKUP_NAME"

    IFS=',' read -ra EXCLUDES <<< "$EXCLUDE_PATTERNS"
    local EXCLUDE_ARGS=()
    for PATTERN in "${EXCLUDES[@]}"; do
        EXCLUDE_ARGS+=(--exclude="$PATTERN")
    done

    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "DRY RUN: Would backup folder $SOURCE_DIR to $BACKUP_PATH"
        send_email "🧪 Backup Dry Run" "Dry run completed for folder: $SOURCE_DIR"
        release_lock
        exit 0
    fi

    log_message "INFO" "Starting backup of $SOURCE_DIR"
    if [ "$INCREMENTAL" = true ]; then
        log_message "INFO" "Performing incremental backup using snapshot: $SNAPSHOT_FILE"
        tar --listed-incremental="$SNAPSHOT_FILE" -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" "$SOURCE_DIR" 2>>"$LOG_FILE"
    else
        log_message "INFO" "Performing full backup"
        tar --listed-incremental=/dev/null -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" "$SOURCE_DIR" 2>>"$LOG_FILE"
    fi

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Backup creation failed!"
        send_email "❌ Backup Failed" "Backup creation failed for folder: $SOURCE_DIR"
        release_lock
        exit 1
    fi

    log_message "SUCCESS" "Backup created: $BACKUP_PATH"
    sha256sum "$BACKUP_PATH" > "$BACKUP_PATH.sha256"
    log_message "INFO" "Checksum file created"

    verify_backup "$BACKUP_PATH"
}

# 🧩 Verify backup integrity
verify_backup() {
    local BACKUP_FILE=$1
    local CHECKSUM_FILE="${BACKUP_FILE}.sha256"

    log_message "INFO" "Verifying checksum..."
    sha256sum -c "$CHECKSUM_FILE" &>> "$LOG_FILE"

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Checksum verification FAILED!"
        send_email "⚠️ Backup Verification Failed" "Checksum failed for $BACKUP_FILE"
        release_lock
        exit 1
    fi

    tar -tzf "$BACKUP_FILE" &> /dev/null
    if [ $? -eq 0 ]; then
        log_message "SUCCESS" "Backup test extract successful — archive is not corrupted"
        send_email "✅ Backup Success" "Backup completed successfully.\nFile: $BACKUP_FILE"
    else
        log_message "ERROR" "Backup test extract FAILED — archive might be broken"
        send_email "⚠️ Backup May Be Corrupted" "Backup test extract failed for $BACKUP_FILE"
    fi
}

# 🧩 Cleanup old backups - CORRECTED VERSION WITH PROPER ROTATION
cleanup_backups() {
    log_message "INFO" "Cleaning up old backups using rotation policy..."
    
    local DAILY_KEEP="${DAILY_KEEP:-7}"
    local WEEKLY_KEEP="${WEEKLY_KEEP:-4}"
    local MONTHLY_KEEP="${MONTHLY_KEEP:-3}"
    
    cd "$BACKUP_DESTINATION" || {
        log_message "ERROR" "Cannot access backup destination"
        return
    }
    
    # Get all backup files sorted by date (newest first)
    local all_backups=($(ls -t backup-*.tar.gz 2>/dev/null))
    
    if [ ${#all_backups[@]} -eq 0 ]; then
        log_message "INFO" "No backups found to clean up."
        return
    fi
    
    log_message "INFO" "Found ${#all_backups[@]} total backups"
    
    # Arrays to track which backups to keep
    declare -A keep_backups
    
    # 1. Keep last N daily backups (most recent)
    local count=0
    log_message "INFO" "Marking daily backups to keep (last $DAILY_KEEP)..."
    for backup in "${all_backups[@]}"; do
        if [ $count -lt $DAILY_KEEP ]; then
            keep_backups["$backup"]="daily"
            log_message "INFO" "  ✓ Keeping daily backup: $backup"
            ((count++))
        else
            break
        fi
    done
    
    # 2. Keep last N weekly backups (one per week)
    local weekly_count=0
    local last_week=""
    log_message "INFO" "Marking weekly backups to keep (last $WEEKLY_KEEP weeks)..."
    for backup in "${all_backups[@]}"; do
        # Extract date from filename: backup-2024-11-03-1430.tar.gz
        if [[ $backup =~ backup-([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            local year="${BASH_REMATCH[1]}"
            local month="${BASH_REMATCH[2]}"
            local day="${BASH_REMATCH[3]}"
            
            # Get week number of year
            local week_num=$(date -d "$year-$month-$day" +%Y-W%V 2>/dev/null)
            
            if [ -n "$week_num" ] && [ "$week_num" != "$last_week" ]; then
                if [ $weekly_count -lt $WEEKLY_KEEP ]; then
                    # Only mark if not already kept as daily
                    if [ -z "${keep_backups[$backup]}" ]; then
                        keep_backups["$backup"]="weekly"
                        log_message "INFO" "  ✓ Keeping weekly backup: $backup (week $week_num)"
                    fi
                    last_week="$week_num"
                    ((weekly_count++))
                fi
            fi
        fi
    done
    
    # 3. Keep last N monthly backups (one per month)
    local monthly_count=0
    local last_month=""
    log_message "INFO" "Marking monthly backups to keep (last $MONTHLY_KEEP months)..."
    for backup in "${all_backups[@]}"; do
        if [[ $backup =~ backup-([0-9]{4})-([0-9]{2}) ]]; then
            local year_month="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
            
            if [ "$year_month" != "$last_month" ]; then
                if [ $monthly_count -lt $MONTHLY_KEEP ]; then
                    # Only mark if not already kept
                    if [ -z "${keep_backups[$backup]}" ]; then
                        keep_backups["$backup"]="monthly"
                        log_message "INFO" "  ✓ Keeping monthly backup: $backup (month $year_month)"
                    fi
                    last_month="$year_month"
                    ((monthly_count++))
                fi
            fi
        fi
    done
    
    # 4. Delete backups not marked for keeping
    local deleted_count=0
    log_message "INFO" "Removing old backups..."
    for backup in "${all_backups[@]}"; do
        if [ -z "${keep_backups[$backup]}" ]; then
            log_message "INFO" "  ✗ Deleting old backup: $backup"
            rm -f "$backup" "${backup}.sha256"
            ((deleted_count++))
        fi
    done
    
    log_message "INFO" "Cleanup complete. Kept ${#keep_backups[@]} backups, deleted $deleted_count old backup(s)."
}

# 🧩 Restore a backup
restore_backup() {
    local BACKUP_FILE=$1
    local RESTORE_DIR=$2

    if [ ! -f "$BACKUP_FILE" ]; then
        if [ -f "$BACKUP_DESTINATION/$BACKUP_FILE" ]; then
            BACKUP_FILE="$BACKUP_DESTINATION/$BACKUP_FILE"
        else
            log_message "ERROR" "Backup file not found: $BACKUP_FILE"
            send_email "❌ Restore Failed" "Backup file not found: $BACKUP_FILE"
            release_lock
            exit 1
        fi
    fi

    mkdir -p "$RESTORE_DIR"
    log_message "INFO" "Restoring $BACKUP_FILE to $RESTORE_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

    if [ $? -eq 0 ]; then
        log_message "SUCCESS" "Backup restored successfully to $RESTORE_DIR"
        send_email "✅ Restore Successful" "Backup restored successfully to $RESTORE_DIR"
    else
        log_message "ERROR" "Backup restore failed!"
        send_email "❌ Restore Failed" "Error occurred while restoring $BACKUP_FILE"
    fi

    release_lock
    exit 0
}

# 🧩 List all available backups
list_backups() {
    echo "Available backups in $BACKUP_DESTINATION:"
    echo "----------------------------------------"
    ls -lh --time-style=long-iso "$BACKUP_DESTINATION"/backup-*.tar.gz 2>/dev/null || echo "No backups found."
}

# 🧩 Main Execution
if [ $# -lt 1 ]; then
    echo "Usage:"
    echo "  ./backup.sh /path/to/folder                     → Create backup"
    echo "  ./backup.sh --dry-run /path/to/folder           → Simulate backup (no files created)"
    echo "  ./backup.sh --restore <backup-file> --to <dir>  → Restore backup"
    echo "  ./backup.sh --list                              → List available backups"
    exit 1
fi

acquire_lock

# Handle arguments
if [ "$1" == "--list" ]; then
    list_backups
    release_lock
    exit 0
elif [ "$1" == "--dry-run" ]; then
    SOURCE_DIR=$2
    create_backup "$SOURCE_DIR" true
elif [ "$1" == "--restore" ]; then
    BACKUP_FILE=$2
    if [ "$3" != "--to" ] || [ -z "$4" ]; then
        echo "Usage: ./backup.sh --restore <backup-file> --to <restore-folder>"
        release_lock
        exit 1
    fi
    RESTORE_DIR=$4
    restore_backup "$BACKUP_FILE" "$RESTORE_DIR"
elif [ "$1" == "--incremental" ]; then
    SOURCE_DIR=$2
    INCREMENTAL=true
    create_backup "$SOURCE_DIR" false
    cleanup_backups   
else
    SOURCE_DIR=$1
    create_backup "$SOURCE_DIR" false
    cleanup_backups
fi

release_lock
log_message "INFO" "Backup process completed."