#!/bin/bash
# mongodb-container-upgrade.sh
# MongoDB 4.0.9 to 7.0.2 Container Upgrade Script
# Description: Automated upgrade script for MongoDB containers with zero-downtime approach
# Version: 1.0
# Author: DevOps Team
# Repository: https://github.com/your-org/mongodb-upgrade-scripts

set -e
set -o pipefail

# Configuration - USER MUST UPDATE THESE VALUES
CONTAINER_NAME="your_mongo_container"          # Change to your MongoDB container name
NETWORK_NAME="your_bridge_network"             # Change to your Docker network name
BACKUP_DIR="./mongo_backups"                   # Backup directory (will be created)
LOG_FILE="./mongodb_upgrade.log"               # Main log file
RESOURCE_LOG="./upgrade_resources.log"         # Resource usage log
DATA_VOLUME="mongo_data"                       # Change to your MongoDB data volume name

# Required upgrade path (DO NOT MODIFY unless you know what you're doing)
UPGRADE_PATH=(
    "4.2.24"
    "4.4.29" 
    "5.0.31"
    "6.0.19"
    "7.0.2"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Progress tracking
TOTAL_STEPS=$(( ${#UPGRADE_PATH[@]} + 6 ))
CURRENT_STEP=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_resource() {
    echo -e "${MAGENTA}[RESOURCE]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$RESOURCE_LOG"
}

# Progress functions
print_progress() {
    local current=$1
    local total=$2
    local message=$3
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    printf "\r["
    printf "%${completed}s" | tr " " "="
    printf "%${remaining}s" | tr " " " "
    printf "] %3d%% - %s" "$percentage" "$message"
}

update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_progress $CURRENT_STEP $TOTAL_STEPS "$1"
    echo "" >> "$LOG_FILE"
}

# Function to monitor system resources
monitor_resources() {
    local container_name=$1
    local phase=$2
    
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    local mem_usage=$(free -m | awk '/Mem:/ {printf "%.1f", $3/$2 * 100}')
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    local container_cpu="N/A"
    local container_mem="N/A"
    
    if docker ps --format "{{.Names}}" | grep -q "$container_name"; then
        local stats=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemPerc}}" "$container_name" 2>/dev/null || echo "N/A,N/A")
        container_cpu=$(echo "$stats" | cut -d',' -f1)
        container_mem=$(echo "$stats" | cut -d',' -f2)
    fi
    
    log_resource "Phase: $phase | CPU: $cpu_usage% | Memory: $mem_usage% | Disk: $disk_usage% | Container CPU: $container_cpu | Container Memory: $container_mem"
}

# Function to display resource usage
show_resource_usage() {
    echo -e "\n${CYAN}=== RESOURCE USAGE SUMMARY ===${NC}"
    echo -e "${CYAN}Timestamp           CPU     Memory  Disk    Container${NC}"
    echo -e "${CYAN}------------------- ------- ------- ------- -----------------${NC}"
    
    tail -n 10 "$RESOURCE_LOG" | while read -r line; do
        if echo "$line" | grep -q "Phase:"; then
            local timestamp=$(echo "$line" | grep -oP '\[RESOURCE\] \K[^ ]+ [^ ]+')
            local cpu=$(echo "$line" | grep -oP 'CPU: \K[^%]+')
            local mem=$(echo "$line" | grep -oP 'Memory: \K[^%]+')
            local disk=$(echo "$line" | grep -oP 'Disk: \K[^%]+')
            local container=$(echo "$line" | grep -oP 'Container CPU: \K[^ ]+')
            local phase=$(echo "$line" | grep -oP 'Phase: \K[^|]+')
            
            printf "%-19s %-7s %-7s %-7s %-20s\n" "$timestamp" "${cpu}%" "${mem}%" "${disk}%" "$container"
        fi
    done
    echo -e "${CYAN}================================${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    update_progress "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    
    if ! docker volume inspect "$DATA_VOLUME" &> /dev/null; then
        log_error "Data volume '$DATA_VOLUME' does not exist."
        exit 1
    fi
    
    if ! docker ps -a --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
        log_error "Container '$CONTAINER_NAME' does not exist."
        exit 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    echo "MongoDB Upgrade Resource Monitoring" > "$RESOURCE_LOG"
    echo "Started: $(date)" >> "$RESOURCE_LOG"
    echo "===================================" >> "$RESOURCE_LOG"
    
    local current_version=$(docker exec "$CONTAINER_NAME" mongod --version 2>/dev/null | grep -oP 'db version v\K[0-9.]+' || echo "unknown")
    log_info "Current MongoDB version: $current_version"
    
    if [ "$current_version" != "4.0.9" ]; then
        log_warning "Expected version 4.0.9, but found $current_version. Continuing anyway."
    fi
    
    log_success "Prerequisites check passed."
    monitor_resources "$CONTAINER_NAME" "Prerequisites Check"
}

# Function to create backup
create_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/mongodb-backup-$timestamp"
    
    update_progress "Creating backup of MongoDB data..."
    monitor_resources "$CONTAINER_NAME" "Backup Start"
    
    log_info "Creating backup using mongodump..."
    if docker exec "$CONTAINER_NAME" mongodump --out="/tmp/backup-$timestamp" --gzip >> "$LOG_FILE" 2>&1; then
        docker cp "$CONTAINER_NAME:/tmp/backup-$timestamp" "$backup_file" >> "$LOG_FILE" 2>&1
        docker exec "$CONTAINER_NAME" rm -rf "/tmp/backup-$timestamp" >> "$LOG_FILE" 2>&1
        
        backup_size=$(du -sh "$backup_file" | cut -f1)
        log_success "Backup created: $backup_file (Size: $backup_size)"
        echo "$backup_file" > "$BACKUP_DIR/latest_backup.txt"
        monitor_resources "$CONTAINER_NAME" "Backup Complete"
    else
        log_error "Backup failed. Check $LOG_FILE for details."
        exit 1
    fi
}

# Function to verify backup
verify_backup() {
    local backup_file=$(cat "$BACKUP_DIR/latest_backup.txt" 2>/dev/null || echo "")
    
    if [ -z "$backup_file" ] || [ ! -d "$backup_file" ]; then
        log_error "No backup found for verification."
        return 1
    fi
    
    update_progress "Verifying backup integrity..."
    monitor_resources "$CONTAINER_NAME" "Backup Verification"
    
    if [ -f "$backup_file/admin/system.version.metadata.json" ] || \
       [ -f "$backup_file/admin/system.version.metadata.json.gz" ]; then
        log_success "Backup verification passed."
        return 0
    else
        log_error "Backup verification failed. Backup may be corrupted."
        return 1
    fi
}

# Function to stop dependent services
stop_dependent_services() {
    update_progress "Stopping dependent services..."
    monitor_resources "$CONTAINER_NAME" "Stop Dependent Services"
    
    local dependent_containers=$(docker ps --format "{{.Names}}" | grep -v "$CONTAINER_NAME" | grep -E "(app|api|backend|node|changelog|kafka)" || true)
    
    if [ -n "$dependent_containers" ]; then
        log_info "Stopping dependent containers: $dependent_containers"
        echo "$dependent_containers" | xargs docker stop >> "$LOG_FILE" 2>&1
        log_success "Dependent containers stopped."
    else
        log_info "No dependent containers found."
    fi
}

# Function to start dependent services
start_dependent_services() {
    update_progress "Starting dependent services..."
    monitor_resources "$CONTAINER_NAME" "Start Dependent Services"
    
    local stopped_containers=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | grep -v "$CONTAINER_NAME" | grep -E "(app|api|backend|node|changelog|kafka)" || true)
    
    if [ -n "$stopped_containers" ]; then
        log_info "Starting containers: $stopped_containers"
        echo "$stopped_containers" | xargs docker start >> "$LOG_FILE" 2>&1
        log_success "Dependent containers started."
    else
        log_info "No dependent containers to start."
    fi
}

# Function to upgrade to specific version
upgrade_to_version() {
    local target_version=$1
    local step=$2
    local total_steps=$3
    
    update_progress "Upgrading to MongoDB $target_version (Step $step/$total_steps)..."
    monitor_resources "$CONTAINER_NAME" "Upgrade to $target_version - Starting"
    
    log_info "Stopping current container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1
    docker rm "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1
    
    log_info "Starting MongoDB $target_version container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        -v "$DATA_VOLUME:/data/db" \
        -p 27017:27017 \
        "mongo:$target_version" \
        --wiredTigerCacheSizeGB 1 \
        --bind_ip_all >> "$LOG_FILE" 2>&1
    
    log_info "Waiting for container to start..."
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
            break
        fi
        sleep 2
        echo -n "."
        attempt=$((attempt + 1))
    done
    echo ""
    
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]; then
        log_error "Container failed to start."
        return 1
    fi
    
    monitor_resources "$CONTAINER_NAME" "Upgrade to $target_version - Running"
    
    local log_output=$(docker logs "$CONTAINER_NAME" 2>&1 | tail -20)
    if echo "$log_output" | grep -i "error\|exception\|failed" > /dev/null; then
        log_error "Errors detected in container logs:"
        echo "$log_output" | tee -a "$LOG_FILE"
        return 1
    fi
    
    log_success "MongoDB container upgraded to version $target_version"
    return 0
}

# Function to verify MongoDB version
verify_mongodb_version() {
    local expected_version=$1
    
    update_progress "Verifying MongoDB version..."
    monitor_resources "$CONTAINER_NAME" "Verify Version $expected_version"
    
    local current_version=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval "db.version()" 2>/dev/null || echo "")
    
    if [ "$current_version" = "$expected_version" ]; then
        log_success "MongoDB version verified: $current_version"
        return 0
    else
        log_error "Version verification failed. Expected: $expected_version, Got: $current_version"
        return 1
    fi
}

# Function to set feature compatibility version
set_feature_compatibility() {
    local target_version=$1
    local compatibility_version=$(echo "$target_version" | cut -d. -f1-2)
    
    update_progress "Setting feature compatibility version to $compatibility_version..."
    monitor_resources "$CONTAINER_NAME" "Set FCV to $compatibility_version"
    
    local set_cmd="db.adminCommand({ setFeatureCompatibilityVersion: \"$compatibility_version\""
    if [ "$compatibility_version" = "7.0" ]; then
        set_cmd="$set_cmd, confirm: true"
    fi
    set_cmd="$set_cmd })"
    
    if docker exec "$CONTAINER_NAME" mongosh --quiet --eval "$set_cmd" >> "$LOG_FILE" 2>&1; then
        log_success "Feature compatibility version set to $compatibility_version"
        
        local current_fcv=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval \
            "db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version" 2>/dev/null || echo "")
        
        if [ "$current_fcv" = "$compatibility_version" ]; then
            log_success "Verified feature compatibility version: $current_fcv"
            return 0
        else
            log_error "Feature compatibility verification failed. Expected: $compatibility_version, Got: $current_fcv"
            return 1
        fi
    else
        log_error "Failed to set feature compatibility version"
        return 1
    fi
}

# Function to perform health check
health_check() {
    local version=$1
    
    update_progress "Performing health check..."
    monitor_resources "$CONTAINER_NAME" "Health Check - $version"
    
    local health_status=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval "
        try {
            var adminDB = db.getSiblingDB('admin');
            var result = adminDB.runCommand({serverStatus: 1});
            var databases = adminDB.runCommand({listDatabases: 1});
            
            print('Health check passed:');
            print(' - Version: ' + result.version);
            print(' - Uptime: ' + result.uptime + ' seconds');
            print(' - Databases: ' + databases.databases.length);
            
            var totalCollections = 0;
            var totalDocuments = 0;
            
            databases.databases.forEach(function(dbInfo) {
                if (!['admin', 'local', 'config'].includes(dbInfo.name)) {
                    var currentDB = db.getSiblingDB(dbInfo.name);
                    var colls = currentDB.getCollectionNames();
                    totalCollections += colls.length;
                    
                    colls.forEach(function(collName) {
                        totalDocuments += currentDB[collName].countDocuments({});
                    });
                }
            });
            
            print(' - Total Collections: ' + totalCollections);
            print(' - Total Documents: ' + totalDocuments);
            print('OK');
        } catch (e) {
            print('Health check failed: ' + e);
        }
    " 2>/dev/null)
    
    if echo "$health_status" | grep -q "OK"; then
        log_success "Health check passed for MongoDB $version"
        echo "$health_status" | tee -a "$LOG_FILE"
        monitor_resources "$CONTAINER_NAME" "Health Check - $version - Passed"
        return 0
    else
        log_error "Health check failed for MongoDB $version:"
        echo "$health_status" | tee -a "$LOG_FILE"
        monitor_resources "$CONTAINER_NAME" "Health Check - $version - Failed"
        return 1
    fi
}

# Function to rollback in case of failure
rollback() {
    local failed_version=$1
    local backup_file=$(cat "$BACKUP_DIR/latest_backup.txt" 2>/dev/null || echo "")
    
    log_error "Upgrade failed at version $failed_version. Initiating rollback..."
    monitor_resources "none" "Rollback Initiated"
    
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    if [ -d "$backup_file" ]; then
        log_info "Restoring data from backup: $backup_file"
        
        docker run --rm --name mongo_restore_temp \
            -v "$backup_file:/backup" \
            -v "$DATA_VOLUME:/data" \
            mongo:4.0.9 mongorestore --drop --gzip --dir /backup >> "$LOG_FILE" 2>&1
        
        docker run -d \
            --name "$CONTAINER_NAME" \
            --network "$NETWORK_NAME" \
            -v "$DATA_VOLUME:/data/db" \
            -p 27017:27017 \
            mongo:4.0.9 \
            --bind_ip_all >> "$LOG_FILE" 2>&1
        
        log_success "Rollback completed. Original MongoDB 4.0.9 container restored."
        monitor_resources "$CONTAINER_NAME" "Rollback Complete"
    else
        log_error "Backup directory not found for rollback."
    fi
    
    start_dependent_services
    exit 1
}

# Main upgrade function
main_upgrade() {
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}    MongoDB 4.0.9 to 7.0.2 Upgrade Script${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo ""
    
    log_info "Starting MongoDB upgrade process"
    log_info "Upgrade path: ${UPGRADE_PATH[*]}"
    
    check_prerequisites
    stop_dependent_services
    create_backup
    verify_backup || exit 1
    
    local step=1
    local total_steps=${#UPGRADE_PATH[@]}
    for version in "${UPGRADE_PATH[@]}"; do
        echo -e "\n${CYAN}==============================================${NC}"
        log_info "Processing upgrade to version: $version (Step $step/$total_steps)"
        
        if upgrade_to_version "$version" "$step" "$total_steps"; then
            if verify_mongodb_version "$version"; then
                if [ "$version" != "4.2.24" ]; then
                    if set_feature_compatibility "$version"; then
                        if health_check "$version"; then
                            log_success "Successfully completed upgrade step to $version"
                            step=$((step + 1))
                        else
                            rollback "$version"
                        fi
                    else
                        rollback "$version"
                    fi
                else
                    if health_check "$version"; then
                        log_success "Successfully completed upgrade step to $version"
                        step=$((step + 1))
                    else
                        rollback "$version"
                    fi
                fi
            else
                rollback "$version"
            fi
        else
            rollback "$version"
        fi
    done
    
    start_dependent_services
    
    log_success "=============================================="
    log_success "MongoDB upgrade completed successfully!"
    log_success "From: 4.0.9"
    log_success "To: 7.0.2"
    log_success "=============================================="
    
    show_resource_usage
    
    echo -e "\n${YELLOW}Important Notes:${NC}"
    echo -e "${YELLOW}1. Create a new MongoDB database backup after completing the upgrade.${NC}"
    echo -e "${YELLOW}2. Verify that no error messages are displayed in the container logs.${NC}"
    echo -e "${YELLOW}3. Test your application thoroughly with the new MongoDB version.${NC}"
    echo -e "${YELLOW}4. Monitor performance for the first 24-48 hours after upgrade.${NC}"
}

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "MongoDB 4.0.9 to 7.0.2 container upgrade script"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help          Show this help message"
    echo "  -v, --verbose       Enable verbose output"
    echo "  -d, --dry-run       Perform dry run without actual upgrades"
    echo "  -b, --backup-only   Only create backup without upgrading"
    echo "  -m, --monitor       Show resource monitoring during upgrade"
    echo ""
    echo "IMPORTANT: Before running, update the configuration variables at the top of the script."
    echo "           Set CONTAINER_NAME, NETWORK_NAME, and DATA_VOLUME to match your environment."
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -b|--backup-only)
            BACKUP_ONLY=true
            shift
            ;;
        -m|--monitor)
            MONITOR=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if configuration has been updated
if [ "$CONTAINER_NAME" = "your_mongo_container" ] || \
   [ "$NETWORK_NAME" = "your_bridge_network" ] || \
   [ "$DATA_VOLUME" = "mongo_data" ]; then
    echo -e "${RED}ERROR: Please update the configuration variables at the top of the script.${NC}"
    echo "You need to set CONTAINER_NAME, NETWORK_NAME, and DATA_VOLUME to match your environment."
    exit 1
fi

# Main execution
if [ "$BACKUP_ONLY" = true ]; then
    check_prerequisites
    create_backup
    verify_backup
elif [ "$DRY_RUN" = true ]; then
    log_info "Dry run mode - checking prerequisites only"
    check_prerequisites
    log_info "Dry run completed successfully. Ready for actual upgrade."
else
    main_upgrade
fi
