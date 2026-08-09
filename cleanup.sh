#!/bin/bash

CONFIG_FILE="$(dirname "$(readlink -f "$0")")/config.conf"

# Load configuration

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"


# Logging deletion and backup

log_message() {

    local level="$1"
    local message="$2"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "$timestamp [$level] $message" | tee -a "$LOG_FILE"
}

# Validate configuration

validate_config() {

    log_message "INFO" "Validating configuration..."

    # threshold
    if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "THRESHOLD must be a number."
        return 1
    fi

    if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
        log_message "ERROR" "THRESHOLD must be between 1 and 100."
        return 1
    fi

    #check interval
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "CHECK_INTERVAL must be a number."
        return 1
    fi

    # Validate BACKUP_ENABLED
    if [ "$BACKUP_ENABLED" != "true" ] &&
       [ "$BACKUP_ENABLED" != "false" ]; then

        log_message "ERROR" "BACKUP_ENABLED must be true or false."
        return 1
    fi
 
    if [ "$BACKUP_ENABLED" = "true" ]; then

        if [ ! -d "$BACKUP_DIR" ]; then
            log_message "ERROR" \
                "Backup directory does not exist: $BACKUP_DIR"
            return 1
        fi

        if [ ! -w "$BACKUP_DIR" ]; then
            log_message "ERROR" \
                "Backup directory is not writable: $BACKUP_DIR"
            return 1
        fi

    fi

    # mount point
    if [ ! -d "$MOUNT_POINT" ]; then
        log_message "ERROR" \
            "Mount point does not exist: $MOUNT_POINT"
        return 1
    fi

    # log directories
    for directory in $LOG_DIRS; do

        if [ ! -d "$directory" ]; then
            log_message "ERROR" \
                "Log directory does not exist: $directory"
            return 1
        fi

        if [ ! -r "$directory" ]; then
            log_message "ERROR" \
                "Cannot read log directory: $directory"
            return 1
        fi

    done

    log_message "INFO" "Configuration validation successful."
    log_message "INFO" "Backup enabled: $BACKUP_ENABLED"

    return 0
}

# disk usage

get_disk_usage() {

    df -P "$MOUNT_POINT" |
        awk 'NR==2 {
            gsub("%", "", $5);
            print $5
        }'
}

# Find oldest log file

find_oldest_log() {

    find $LOG_DIRS \
        -type f \
        -name "$FILE_PATTERN" \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -n |
        head -n 1 |
        cut -d' ' -f2-


























        
}

get_backup_path() {

    local source_file="$1"

    local file_name
    file_name=$(basename "$source_file")

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    echo "$BACKUP_DIR/${timestamp}_${file_name}"
}

# Backup file

backup_file() {

    local source_file="$1"

    local destination
    destination=$(get_backup_path "$source_file")

    log_message "INFO" "Backing up:"
    log_message "INFO" "Source      : $source_file"
    log_message "INFO" "Destination : $destination"

    if ! cp -- "$source_file" "$destination"; then

        log_message "ERROR" "Backup failed: $source_file"

        return 1
    fi

    # Verify backup exists
    if [ ! -f "$destination" ]; then

        log_message "ERROR" \
            "Backup file does not exist after copy."

        return 1
    fi

    # Verify backup size
    local original_size
    local backup_size

    original_size=$(stat -c '%s' "$source_file")
    backup_size=$(stat -c '%s' "$destination")

    if [ "$original_size" -ne "$backup_size" ]; then

        log_message "ERROR" \
            "Backup verification failed: size mismatch."

        return 1
    fi

    log_message "INFO" "Backup verified successfully."

    return 0
}

# Delete file

delete_file() {

    local file="$1"

    log_message "INFO" "Deleting: $file"

    if rm -- "$file"; then
       log_message "INFO" "Successfully deleted: $file"
        return 0

    else
        log_message "ERROR" "Failed to delete: $file"
        return 1
    fi
}

# Process oldest file
# ------------------------------------------------------------

process_oldest_file() {

    local oldest_file

    oldest_file=$(find_oldest_log)

    if [ -z "$oldest_file" ]; then

        log_message "WARNING" "No matching log files found."

        return 1
    fi

    log_message "INFO" "Oldest log file:"
    log_message "INFO" "$oldest_file"

    # Backup enabled

    if [ "$BACKUP_ENABLED" = "true" ]; then

        log_message "INFO" "Backup is ENABLED."

        if ! backup_file "$oldest_file"; then

            log_message "ERROR" "Backup failed."
            log_message "ERROR" \
                "Original file will NOT be deleted."

            return 1
        fi

        log_message "INFO" \
            "Backup successful. Proceeding with deletion."

    # --------------------------------------------------------
    # Backup disabled
    # --------------------------------------------------------

    else

        log_message "INFO" "Backup is DISABLED."
        log_message "WARNING" \
            "Original file will be deleted without backup."

    fi

    # --------------------------------------------------------
    # Delete file
    # --------------------------------------------------------

    if ! delete_file "$oldest_file"; then

        if [ "$BACKUP_ENABLED" = "true" ]; then
            log_message "ERROR" \
                "Backup succeeded but deletion failed."
        else
            log_message "ERROR" \
                "Deletion failed."
        fi

        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

perform_cleanup() {

    while true; do

        local usage

        usage=$(get_disk_usage)

        if [ -z "$usage" ]; then

            log_message "ERROR" \
                "Unable to determine disk usage."

            return 1
        fi

        log_message "INFO" \
            "Current disk usage: ${usage}%"

        log_message "INFO" \
            "Configured threshold: ${THRESHOLD}%"

        # ----------------------------------------------------
        # Below threshold
        # ----------------------------------------------------

        if [ "$usage" -lt "$THRESHOLD" ]; then

            log_message "INFO" \
                "Disk usage is below threshold."

            log_message "INFO" \
                "No cleanup required."

            break
        fi

        # ----------------------------------------------------
        # Threshold reached
        # ----------------------------------------------------

        log_message "WARNING" \
            "Disk usage threshold exceeded."

        log_message "INFO" \
            "Starting oldest-log cleanup."

        if ! process_oldest_file; then

            log_message "ERROR" \
                "Cleanup stopped because processing failed."

            return 1
        fi

    done

    return 0
}


# Lock file gen

acquire_lock() {

    if [ -e "$LOCK_FILE" ]; then

        log_message "WARNING" \
            "Another cleanup process is already running."

        log_message "WARNING" \
            "Lock file: $LOCK_FILE"

        return 1
    fi

    echo "$$" > "$LOCK_FILE"

    log_message "INFO" "Lock acquired."
    log_message "INFO" "Process ID: $$"

    return 0
}


# Release lock

release_lock() {

    if [ -e "$LOCK_FILE" ]; then

        rm -f "$LOCK_FILE"

        log_message "INFO" "Lock released."

    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {

    
    log_message "INFO" "Log cleanup cycle started."

    if ! acquire_lock; then
        return 1
    fi

    if ! validate_config; then

        log_message "ERROR" \
            "Configuration validation failed."

        release_lock

        return 1
    fi

    perform_cleanup

    local result=$?

    release_lock

    if [ "$result" -eq 0 ]; then

        log_message "INFO" \
            "Log cleanup cycle completed successfully."

    else

        log_message "ERROR" \
            "Log cleanup cycle completed with errors."

    fi

    return "$result"
}

# Cleanup lock when script exits

trap release_lock EXIT

# Continuous polling

while true; do

    main

    log_message "INFO" \
        "Next check in $CHECK_INTERVAL seconds."

    sleep "$CHECK_INTERVAL"

done
