#!/usr/bin/env bash

set -u

CONFIG_FILE="$(dirname "$(readlink -f "$0")")/config.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

log_message() {

    local level="$1"
    local message="$2"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "$timestamp [$level] $message" | tee -a "$LOG_FILE"
}

# Config validation
validate_config() {

    log_message "INFO" "Validating configuration..."

    # Threshold
    if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "THRESHOLD must be a number."
        return 1
    fi

    if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
        log_message "ERROR" "THRESHOLD must be between 1 and 100."
        return 1
    fi

    # Bundle percentage
    if ! [[ "$BUNDLE_PERCENT" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "BUNDLE_PERCENT must be a number."
        return 1
    fi

    if [ "$BUNDLE_PERCENT" -lt 1 ] || [ "$BUNDLE_PERCENT" -gt 100 ]; then
        log_message "ERROR" "BUNDLE_PERCENT must be between 1 and 100."
        return 1
    fi

    # Backup flag
    if [ "$BACKUP_ENABLED" != "true" ] &&
       [ "$BACKUP_ENABLED" != "false" ]; then

        log_message "ERROR" \
            "BACKUP_ENABLED must be true or false."

        return 1
    fi

    # Mount point
    if [ ! -d "$MOUNT_POINT" ]; then

        log_message "ERROR" \
            "Mount point does not exist: $MOUNT_POINT"

        return 1
    fi

    # Log directories
    IFS='~' read -ra LOG_DIR_ARRAY <<< "$LOG_DIRS"

    if [ "${#LOG_DIR_ARRAY[@]}" -eq 0 ]; then

        log_message "ERROR" \
            "No log directories configured."

        return 1
    fi

    for directory in "${LOG_DIR_ARRAY[@]}"; do

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


    log_message "INFO" "Configuration validation successful."
    log_message "INFO" "Backup enabled: $BACKUP_ENABLED"
    log_message "INFO" "Bundle size: ${BUNDLE_PERCENT}% of filesystem capacity."

    return 0
}

# File Sys info
get_filesystem_info() {

    df -P -B1 "$MOUNT_POINT" |
        awk 'NR==2 {
            gsub("%", "", $5);
            print $2, $3, $5
        }'
}

# disk usage percentage
get_disk_usage() {
    get_filesystem_info | awk '{print $3}'
}

# Get filesystem capacity in bytes

get_filesystem_capacity() {

    get_filesystem_info | awk '{print $1}'
}

# Calculate dynamic bundle size

calculate_bundle_size() {

    local capacity="$1"

    awk -v capacity="$capacity" \
        -v percent="$BUNDLE_PERCENT" \
        'BEGIN {
            printf "%.0f\n", capacity * percent / 100
        }'
}

# Build dynamic deletion bundle

build_bundle() {

    local required_bytes="$1"

    BUNDLE_FILES=()
    BUNDLE_TOTAL_BYTES=0

    log_message "INFO" \
        "Building dynamic deletion bundle..."

    log_message "INFO" \
        "Target bundle size: $required_bytes bytes"


    IFS='~' read -ra LOG_DIR_ARRAY <<< "$LOG_DIRS"


    while IFS=$'\t' read -r -d '' mtime file_size file_path; do

        # Add file to in-memory bundle
        BUNDLE_FILES+=("$file_path")

        BUNDLE_TOTAL_BYTES=$(
            awk -v a="$BUNDLE_TOTAL_BYTES" \
                -v b="$file_size" \
                'BEGIN { printf "%.0f\n", a + b }'
        )


        log_message "INFO" \
            "Bundle candidate: $file_path ($file_size bytes)"


        # Stop once the required amount is accumulated
        if [ "$BUNDLE_TOTAL_BYTES" -ge "$required_bytes" ]; then
            break
        fi

    done < <(

        find "${LOG_DIR_ARRAY[@]}" \
            -type f \
            -name "$FILE_PATTERN" \
            -printf '%T@\t%s\t%p\0' 2>/dev/null |
        sort -z -n -k1,1

    )


    if [ "${#BUNDLE_FILES[@]}" -eq 0 ]; then

        log_message "WARNING" \
            "No eligible log files found."

        return 1
    fi


    log_message "INFO" \
        "Dynamic bundle created."

    log_message "INFO" \
        "Files selected: ${#BUNDLE_FILES[@]}"

    log_message "INFO" \
        "Total selected size: $BUNDLE_TOTAL_BYTES bytes"

    return 0
}

# Generate unique backup path
get_backup_path() {

    local source_file="$1"

    local file_name
    file_name=$(basename "$source_file")

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S_%N')

    echo "$BACKUP_DIR/${timestamp}_$$_${file_name}"
}

# Backup one file

backup_file() {

    local source_file="$1"

    local destination
    destination=$(get_backup_path "$source_file")


    log_message "INFO" \
        "Backing up: $source_file"

    log_message "INFO" \
        "Destination: $destination"


    if ! cp -- "$source_file" "$destination"; then

        log_message "ERROR" \
            "Backup failed: $source_file"

        return 1
    fi


    # Check existence
    if [ ! -f "$destination" ]; then

        log_message "ERROR" \
            "Backup verification failed: destination does not exist."

        return 1
    fi


    # Check size
    local original_size
    local backup_size

    original_size=$(stat -c '%s' "$source_file")
    backup_size=$(stat -c '%s' "$destination")


    if [ "$original_size" -ne "$backup_size" ]; then

        log_message "ERROR" \
            "Backup verification failed: size mismatch."

        return 1
    fi


    log_message "INFO" \
        "Backup verified: $source_file"

    return 0
}

# Delete one file
delete_file() {

    local file="$1"

    log_message "INFO" \
        "Deleting: $file"


    if rm -- "$file"; then

        log_message "INFO" \
            "Successfully deleted: $file"

        return 0

    else

        log_message "ERROR" \
            "Failed to delete: $file"

        return 1
    fi
}

# Process dynamic bundle

process_bundle() {

    log_message "INFO" \
        "Processing bundle..."

    if [ "$BACKUP_ENABLED" = "true" ]; then

        log_message "INFO" \
            "Backup enabled. Starting backup phase."


        for file in "${BUNDLE_FILES[@]}"; do

            if ! backup_file "$file"; then

                log_message "ERROR" \
                    "Bundle backup failed."

                log_message "ERROR" \
                    "No files from this bundle will be deleted."

                return 1
            fi

        done

        log_message "INFO" \
            "All bundle files backed up successfully."

    else

        log_message "INFO" \
            "Backup disabled. Skipping backup phase."

    fi


    log_message "INFO" \
        "Starting deletion phase."


    local deletion_failed=0


    for file in "${BUNDLE_FILES[@]}"; do

        # File may have disappeared since discovery
        if [ ! -f "$file" ]; then

            log_message "WARNING" \
                "File no longer exists. Skipping: $file"

            continue
        fi


        if ! delete_file "$file"; then

            deletion_failed=1
        fi

    done


    if [ "$deletion_failed" -eq 1 ]; then

        log_message "ERROR" \
            "One or more files could not be deleted."

        return 1
    fi


    log_message "INFO" \
        "Bundle processed successfully."

    return 0
}

# Perform cleanup

perform_cleanup() {

    local usage
    local capacity
    local bundle_size


    usage=$(get_disk_usage)

    if [ -z "$usage" ]; then

        log_message "ERROR" \
            "Unable to determine disk usage."

        return 1
    fi


    capacity=$(get_filesystem_capacity)

    if [ -z "$capacity" ]; then

        log_message "ERROR" \
            "Unable to determine filesystem capacity."

        return 1
    fi


    bundle_size=$(calculate_bundle_size "$capacity")


    log_message "INFO" \
        "Current disk usage: ${usage}%"

    log_message "INFO" \
        "Configured threshold: ${THRESHOLD}%"

    log_message "INFO" \
        "Filesystem capacity: $capacity bytes"

    log_message "INFO" \
        "Dynamic bundle target: $bundle_size bytes"


    if [ "$usage" -lt "$THRESHOLD" ]; then

        log_message "INFO" \
            "Disk usage is below threshold."

        log_message "INFO" \
            "No cleanup required."

        return 0
    fi

    # Cleanup required

    log_message "WARNING" \
        "Disk usage threshold reached."

    log_message "INFO" \
        "Starting dynamic bundle cleanup."


    while true; do

        usage=$(get_disk_usage)


        if [ -z "$usage" ]; then

            log_message "ERROR" \
                "Unable to determine disk usage."

            return 1
        fi

        # Stop when below threshold

        if [ "$usage" -lt "$THRESHOLD" ]; then

            log_message "INFO" \
                "Disk usage is now below threshold: ${usage}%"

            break
        fi

        # Build a fresh in-memory bundle

        if ! build_bundle "$bundle_size"; then

            log_message "ERROR" \
                "Unable to build deletion bundle."

            return 1
        fi

        # Process bundle

        if ! process_bundle; then

            log_message "ERROR" \
                "Bundle processing failed."

            return 1
        fi


        log_message "INFO" \
            "Bundle completed. Rechecking disk usage..."

    done


    return 0
}

# Acquire lock

acquire_lock() {

    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then

        log_message "WARNING" \
            "Another cleanup process is already running."

        return 1
    fi


    log_message "INFO" \
        "Lock acquired."

    log_message "INFO" \
        "Process ID: $$"

    return 0
}

# Release lock

release_lock() {

    if [ -n "${LOCK_FILE:-}" ]; then

        flock -u 200 2>/dev/null || true

        rm -f "$LOCK_FILE" 2>/dev/null || true

        log_message "INFO" \
            "Lock released."

    fi
}

# Main

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

    if ! perform_cleanup; then

        log_message "ERROR" \
            "Cleanup failed."

        release_lock

        return 1
    fi

    release_lock

    log_message "INFO" \
        "Log cleanup cycle completed successfully."

    return 0
}

trap release_lock EXIT

main

exit $?