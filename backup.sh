#!/bin/bash

# ============================================
# Automated Backup System
# ============================================

#  Global variables
LOG_FILE="./backup.log"
EMAIL_FILE="./email.txt"
LOCK_FILE="/tmp/backup.lock"
BACKUP_PATH=""  # Will be set during backup creation

#  Function for logging
log_message() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $LEVEL: $MESSAGE" | tee -a "$LOG_FILE"
}

#  Load configuration file or use defaults
if [ -f ./backup.config ]; then
    source ./backup.config
    log_message "INFO" "Configuration loaded from backup.config"
else
    echo "Warning: backup.config not found, using default values"
    log_message "WARN" "Configuration file not found, using defaults"
    
    # Default values
    BACKUP_DESTINATION="./backups"
    EXCLUDE_PATTERNS=".git,node_modules,.cache"
    DAILY_KEEP=7
    WEEKLY_KEEP=4
    MONTHLY_KEEP=3
    MIN_SPACE_MB=100
    EMAIL_RECIPIENT="admin@example.com"
    SNAPSHOT_FILE="./backup.snar"
fi

#  Simulate email notification
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

#  Acquire lock
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log_message "ERROR" "Another backup process is already running!"
        echo "Error: Another backup process is already running (lock file exists)"
        exit 1
    fi
    touch "$LOCK_FILE"
    log_message "INFO" "Lock acquired"
}

#  Release lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log_message "INFO" "Lock released"
    fi
}

#  Cleanup on normal exit
cleanup_on_exit() {
    release_lock
}

#  Cleanup on interruption (Ctrl+C, kill, etc.)
cleanup_on_interrupt() {
    echo ""  # New line after ^C
    log_message "WARN" "Backup interrupted! Cleaning up..."
    
    # Remove partial backup if exists
    if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
        rm -f "$BACKUP_PATH" "$BACKUP_PATH.sha256"
        log_message "INFO" "Removed partial backup file: $BACKUP_PATH"
    fi
    
    release_lock
    exit 130
}

# Set up traps
trap cleanup_on_interrupt INT TERM
trap cleanup_on_exit EXIT

#  Check disk space before backup
check_space() {
    local required_space_mb="${MIN_SPACE_MB:-100}"
    local available_space_mb
    available_space_mb=$(df --output=avail -m "$BACKUP_DESTINATION" 2>/dev/null | tail -n 1)
    
    if [ -z "$available_space_mb" ]; then
        log_message "ERROR" "Cannot determine available disk space"
        return 1
    fi

    if (( available_space_mb < required_space_mb )); then
        log_message "ERROR" "Not enough disk space. Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
        send_email " Backup Failed - Low Disk Space" "Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
        echo "Error: Not enough disk space for backup"
        exit 1
    else
        log_message "INFO" "Sufficient disk space available: ${available_space_mb}MB"
    fi
}

#  Create backup
create_backup() {
    local SOURCE_DIR=$1
    local DRY_RUN=$2

    # Validate source directory exists
    if [ ! -d "$SOURCE_DIR" ]; then
        log_message "ERROR" "Source folder not found: $SOURCE_DIR"
        send_email " Backup Failed - Source Missing" "Source folder not found: $SOURCE_DIR"
        echo "Error: Source folder not found"
        exit 1
    fi

    # Validate source directory is readable
    if [ ! -r "$SOURCE_DIR" ]; then
        log_message "ERROR" "Cannot read folder, permission denied: $SOURCE_DIR"
        send_email " Backup Failed - Permission Denied" "Cannot read folder: $SOURCE_DIR"
        echo "Error: Cannot read folder, permission denied"
        exit 1
    fi

    # Create backup destination directory if it doesn't exist
    if [ ! -d "$BACKUP_DESTINATION" ]; then
        log_message "INFO" "Backup destination doesn't exist, creating: $BACKUP_DESTINATION"
        if ! mkdir -p "$BACKUP_DESTINATION"; then
            log_message "ERROR" "Cannot create backup destination: $BACKUP_DESTINATION"
            send_email " Backup Failed" "Cannot create backup directory: $BACKUP_DESTINATION"
            echo "Error: Cannot create backup destination"
            exit 1
        fi
    fi

    check_space

    local TIMESTAMP=$(date +%Y-%m-%d-%H%M)
    local BACKUP_NAME="backup-$TIMESTAMP.tar.gz"
    BACKUP_PATH="$BACKUP_DESTINATION/$BACKUP_NAME"  # Set global variable

    # Build exclusion arguments
    IFS=',' read -ra EXCLUDES <<< "$EXCLUDE_PATTERNS"
    local EXCLUDE_ARGS=()
    for PATTERN in "${EXCLUDES[@]}"; do
        PATTERN=$(echo "$PATTERN" | xargs)  # Trim whitespace
        if [ -n "$PATTERN" ]; then
            EXCLUDE_ARGS+=(--exclude="$PATTERN")
        fi
    done

    # Handle dry run mode
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN MODE - No files will be created"
        log_message "INFO" "DRY RUN: Would backup folder $SOURCE_DIR"
        log_message "INFO" "DRY RUN: Would create $BACKUP_PATH"
        log_message "INFO" "DRY RUN: Would exclude patterns: $EXCLUDE_PATTERNS"
        log_message "INFO" "DRY RUN: Would verify backup integrity"
        log_message "INFO" "DRY RUN: Would run cleanup of old backups"
        send_email " Backup Dry Run" "Dry run completed for folder: $SOURCE_DIR"
        echo "DRY RUN: Would create backup: $BACKUP_NAME"
        exit 0
    fi

    # Create the backup
    log_message "INFO" "Starting backup of $SOURCE_DIR"
    
    if [ "$INCREMENTAL" = true ]; then
        log_message "INFO" "Performing incremental backup using snapshot: $SNAPSHOT_FILE"
        if ! tar --listed-incremental="$SNAPSHOT_FILE" -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" "$SOURCE_DIR" 2>>"$LOG_FILE"; then
            log_message "ERROR" "Incremental backup creation failed!"
            send_email " Backup Failed" "Incremental backup creation failed for folder: $SOURCE_DIR"
            echo "Error: Backup creation failed"
            rm -f "$BACKUP_PATH"
            exit 1
        fi
    else
        log_message "INFO" "Performing full backup"
        if ! tar -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" "$SOURCE_DIR" 2>>"$LOG_FILE"; then
            log_message "ERROR" "Backup creation failed!"
            send_email " Backup Failed" "Backup creation failed for folder: $SOURCE_DIR"
            echo "Error: Backup creation failed"
            rm -f "$BACKUP_PATH"
            exit 1
        fi
    fi

    log_message "SUCCESS" "Backup created: $BACKUP_PATH"

    # Generate checksum
    if ! sha256sum "$BACKUP_PATH" > "$BACKUP_PATH.sha256" 2>>"$LOG_FILE"; then
        log_message "ERROR" "Failed to create checksum file"
        send_email " Backup Failed" "Checksum generation failed"
        echo "Error: Checksum generation failed"
        exit 1
    fi
    log_message "INFO" "Checksum file created"

    # Verify the backup
    verify_backup "$BACKUP_PATH"
}

#  Verify backup integrity
verify_backup() {
    local BACKUP_FILE=$1
    local CHECKSUM_FILE="${BACKUP_FILE}.sha256"

    log_message "INFO" "Verifying backup integrity..."

    # Verify checksum
    log_message "INFO" "Verifying checksum..."
    if sha256sum -c "$CHECKSUM_FILE" >> "$LOG_FILE" 2>&1; then
        log_message "SUCCESS" "Checksum verified successfully"
    else
        log_message "ERROR" "Checksum verification FAILED!"
        send_email " Backup Failed - Checksum Mismatch" "Checksum verification failed for $BACKUP_FILE"
        echo "VERIFICATION: FAILED"
        echo "Error: Checksum verification failed"
        exit 1
    fi

    # Test archive extraction
    log_message "INFO" "Testing archive integrity..."
    if tar -tzf "$BACKUP_FILE" &> /dev/null; then
        log_message "SUCCESS" "Backup verification complete - archive is valid"
        send_email " Backup Success" "Backup completed and verified successfully.\nFile: $BACKUP_FILE\nSize: $(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1)"
        echo "VERIFICATION: SUCCESS"
    else
        log_message "ERROR" "Archive extraction test FAILED - backup is corrupted"
        send_email " Backup Failed - Corrupted Archive" "Archive failed extraction test: $BACKUP_FILE"
        echo "VERIFICATION: FAILED"
        echo "Error: Archive is corrupted"
        exit 1
    fi
}

#  Cleanup old backups with rotation policy
cleanup_backups() {
    log_message "INFO" "Starting cleanup of old backups (retention: ${DAILY_KEEP} daily, ${WEEKLY_KEEP} weekly, ${MONTHLY_KEEP} monthly)..."
    
    local DAILY_KEEP="${DAILY_KEEP:-7}"
    local WEEKLY_KEEP="${WEEKLY_KEEP:-4}"
    local MONTHLY_KEEP="${MONTHLY_KEEP:-3}"
    
    cd "$BACKUP_DESTINATION" || {
        log_message "ERROR" "Cannot access backup destination: $BACKUP_DESTINATION"
        return
    }
    
    # Get all backup files sorted by modification time (newest first)
    local all_backups=($(ls -t backup-*.tar.gz 2>/dev/null))
    
    if [ ${#all_backups[@]} -eq 0 ]; then
        log_message "INFO" "No backups found to clean up"
        return
    fi
    
    log_message "INFO" "Found ${#all_backups[@]} total backups"
    
    # Associative array to track which backups to keep
    declare -A keep_backups
    
    # 1. Keep last N daily backups (most recent)
    local count=0
    for backup in "${all_backups[@]}"; do
        if [ $count -lt $DAILY_KEEP ]; then
            keep_backups["$backup"]="daily"
            ((count++))
        else
            break
        fi
    done
    log_message "INFO" "Marked $count daily backups to keep"
    
    # 2. Keep last N weekly backups (one per week)
    local weekly_count=0
    local last_week=""
    for backup in "${all_backups[@]}"; do
        # Extract date from filename: backup-2024-11-03-1430.tar.gz
        if [[ $backup =~ backup-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{4})\.tar\.gz ]]; then
            local year="${BASH_REMATCH[1]}"
            local month="${BASH_REMATCH[2]}"
            local day="${BASH_REMATCH[3]}"
            
            # Validate date before processing
            if ! date -d "$year-$month-$day" &>/dev/null; then
                continue
            fi
            
            # Get week number of year
            local week_num=$(date -d "$year-$month-$day" +%Y-W%V 2>/dev/null)
            
            if [ -n "$week_num" ] && [ "$week_num" != "$last_week" ]; then
                if [ $weekly_count -lt $WEEKLY_KEEP ]; then
                    # Only mark if not already kept as daily
                    if [ -z "${keep_backups[$backup]}" ]; then
                        keep_backups["$backup"]="weekly"
                        ((weekly_count++))
                    fi
                    last_week="$week_num"
                fi
            fi
        fi
    done
    log_message "INFO" "Marked $weekly_count additional weekly backups to keep"
    
    # 3. Keep last N monthly backups (one per month)
    local monthly_count=0
    local last_month=""
    for backup in "${all_backups[@]}"; do
        if [[ $backup =~ backup-([0-9]{4})-([0-9]{2}) ]]; then
            local year_month="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
            
            if [ "$year_month" != "$last_month" ]; then
                if [ $monthly_count -lt $MONTHLY_KEEP ]; then
                    # Only mark if not already kept
                    if [ -z "${keep_backups[$backup]}" ]; then
                        keep_backups["$backup"]="monthly"
                        ((monthly_count++))
                    fi
                    last_month="$year_month"
                fi
            fi
        fi
    done
    log_message "INFO" "Marked $monthly_count additional monthly backups to keep"
    
    # 4. Delete backups not marked for keeping
    local deleted_count=0
    for backup in "${all_backups[@]}"; do
        if [ -z "${keep_backups[$backup]}" ]; then
            log_message "INFO" "Deleted old backup: $backup"
            rm -f "$backup" "${backup}.sha256"
            ((deleted_count++))
        fi
    done
    
    log_message "INFO" "Cleanup complete. Kept ${#keep_backups[@]} backups, deleted $deleted_count old backup(s)"
}

#  Restore a backup
restore_backup() {
    local BACKUP_FILE=$1
    local RESTORE_DIR=$2

    # Find backup file
    if [ ! -f "$BACKUP_FILE" ]; then
        if [ -f "$BACKUP_DESTINATION/$BACKUP_FILE" ]; then
            BACKUP_FILE="$BACKUP_DESTINATION/$BACKUP_FILE"
        else
            log_message "ERROR" "Backup file not found: $BACKUP_FILE"
            send_email " Restore Failed" "Backup file not found: $BACKUP_FILE"
            echo "Error: Backup file not found"
            exit 1
        fi
    fi

    # Verify checksum before restoring
    local CHECKSUM_FILE="${BACKUP_FILE}.sha256"
    if [ -f "$CHECKSUM_FILE" ]; then
        log_message "INFO" "Verifying backup integrity before restore..."
        if sha256sum -c "$CHECKSUM_FILE" >> "$LOG_FILE" 2>&1; then
            log_message "INFO" "Backup integrity verified"
        else
            log_message "ERROR" "Backup file is corrupted (checksum verification failed)"
            send_email " Restore Failed" "Backup file is corrupted: $BACKUP_FILE"
            echo "Error: Backup file is corrupted"
            exit 1
        fi
    else
        log_message "WARN" "No checksum file found, skipping verification"
    fi

    # Create restore directory
    if ! mkdir -p "$RESTORE_DIR"; then
        log_message "ERROR" "Cannot create restore directory: $RESTORE_DIR"
        send_email " Restore Failed" "Cannot create restore directory: $RESTORE_DIR"
        echo "Error: Cannot create restore directory"
        exit 1
    fi

    log_message "INFO" "Restoring $BACKUP_FILE to $RESTORE_DIR..."
    if tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR" 2>>"$LOG_FILE"; then
        log_message "SUCCESS" "Backup restored successfully to $RESTORE_DIR"
        send_email " Restore Successful" "Backup restored successfully.\nFrom: $BACKUP_FILE\nTo: $RESTORE_DIR"
        echo "Restore completed successfully"
    else
        log_message "ERROR" "Backup restore failed"
        send_email " Restore Failed" "Error occurred while restoring $BACKUP_FILE"
        echo "Error: Restore failed"
        exit 1
    fi
}

#  List all available backups
list_backups() {
    echo "Available backups in $BACKUP_DESTINATION:"
    echo "================================================================"
    if [ -d "$BACKUP_DESTINATION" ] && ls "$BACKUP_DESTINATION"/backup-*.tar.gz &>/dev/null; then
        ls -lh --time-style=long-iso "$BACKUP_DESTINATION"/backup-*.tar.gz 2>/dev/null | \
        awk '{print $6, $7, $5, $8}'
    else
        echo "No backups found"
    fi
    echo "================================================================"
}

# ============================================
# Main Execution
# ============================================

# Log script startup
log_message "INFO" "============================================"
log_message "INFO" "Backup script started"
log_message "INFO" "============================================"

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage:"
    echo "  ./backup.sh /path/to/folder                     → Create backup"
    echo "  ./backup.sh --dry-run /path/to/folder           → Simulate backup (no files created)"
    echo "  ./backup.sh --restore <backup-file> --to <dir>  → Restore backup"
    echo "  ./backup.sh --list                              → List available backups"
    echo "  ./backup.sh --incremental /path/to/folder       → Create incremental backup"
    exit 1
fi

acquire_lock

# Handle command-line arguments
case "$1" in
    --list)
        list_backups
        exit 0
        ;;
    --dry-run)
        if [ -z "$2" ]; then
            echo "Error: Missing source folder for dry run"
            echo "Usage: ./backup.sh --dry-run /path/to/folder"
            exit 1
        fi
        SOURCE_DIR="$2"
        create_backup "$SOURCE_DIR" true
        ;;
    --restore)
        if [ "$3" != "--to" ] || [ -z "$2" ] || [ -z "$4" ]; then
            echo "Usage: ./backup.sh --restore <backup-file> --to <restore-folder>"
            exit 1
        fi
        BACKUP_FILE="$2"
        RESTORE_DIR="$4"
        restore_backup "$BACKUP_FILE" "$RESTORE_DIR"
        ;;
    --incremental)
        if [ -z "$2" ]; then
            echo "Error: Missing source folder for incremental backup"
            echo "Usage: ./backup.sh --incremental /path/to/folder"
            exit 1
        fi
        SOURCE_DIR="$2"
        INCREMENTAL=true
        create_backup "$SOURCE_DIR" false
        cleanup_backups
        ;;
    *)
        SOURCE_DIR="$1"
        create_backup "$SOURCE_DIR" false
        cleanup_backups
        ;;
esac

log_message "INFO" "Backup process completed successfully"
log_message "INFO" "============================================"
