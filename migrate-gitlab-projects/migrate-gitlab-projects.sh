#!/bin/bash

set -euo pipefail

LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="./gitlab_migration"
mkdir -p "$TEMP_DIR"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

require_env() {
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            log "Error: Environment variable $var is not set."
            exit 1
        fi
    done
}

require_env SOURCE_GITLAB SOURCE_TOKEN SOURCE_GROUP_ID DEST_GITLAB DEST_TOKEN DEST_GROUP_ID DEST_PROXY

get_all_projects() {
    local group_id="$1"
    local page=1
    local per_page=100
    local all_projects=()

    while :; do
        resp=$(curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
            "$SOURCE_GITLAB/api/v4/groups/$group_id/projects?include_subgroups=true&per_page=$per_page&page=$page")

        mapfile -t projects < <(echo "$resp" | grep -o '"id":[0-9]*' | cut -d ':' -f2)

        [[ "${#projects[@]}" -eq 0 ]] && break

        all_projects+=("${projects[@]}")
        ((page++))
    done

    echo "${all_projects[@]}"
}

export_project() {
    local project_id="$1"

    log "Requesting export for project $project_id"
    curl -sk -X POST --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
        "$SOURCE_GITLAB/api/v4/projects/$project_id/export" > /dev/null

    while true; do
        status=$(curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
            "$SOURCE_GITLAB/api/v4/projects/$project_id/export" | grep -o '"export_status":"[^"]*"' | cut -d':' -f2 | tr -d '"')

        [[ "$status" == "finished" ]] && break
        log "Waiting for export to finish for project $project_id (status: $status)"
        sleep 5
    done

    log "Downloading export for project $project_id"
    curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
        "$SOURCE_GITLAB/api/v4/projects/$project_id/export/download" \
        -o "$TEMP_DIR/project_${project_id}.tar.gz"
}

import_project() {
    local file="$1"
    local name="$2"
    local path="$3"

    log "Importing project: $name ($path) to destination group $DEST_GROUP_ID"

    curl -sk --proxy "$DEST_PROXY" \
        --header "PRIVATE-TOKEN: $DEST_TOKEN" \
        -F "path=$path" \
        -F "name=$name" \
        -F "namespace_id=$DEST_GROUP_ID" \
        -F "file=@$file" \
        "$DEST_GITLAB/api/v4/projects/import"
}

main() {
    project_ids=$(get_all_projects "$SOURCE_GROUP_ID")

    for pid in $project_ids; do
        meta=$(curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
            "$SOURCE_GITLAB/api/v4/projects/$pid")

        name=$(echo "$meta" | grep -o '"name":"[^"]*"' | cut -d':' -f2 | tr -d '"')
        path=$(echo "$meta" | grep -o '"path":"[^"]*"' | cut -d':' -f2 | tr -d '"')

        log "Processing project $pid: $name"
        export_project "$pid"
        import_project "$TEMP_DIR/project_${pid}.tar.gz" "$name" "$path"
        log "Finished importing $name"
    done

    log "All projects migrated."
}

main