#!/bin/bash

# === CONFIGURATION ===

SRC_GITLAB_URL="https://gitlab.com"
SRC_GROUP_ID="your-source-group-id-or-path"
SRC_ACCESS_TOKEN="${SRC_ACCESS_TOKEN:-your-source-access-token}"

TARGET_GITLAB_URL="https://gitlab.example.com"
TARGET_ROOT_NAMESPACE_PATH="your-target-group-path"  # e.g. mycompany/dev
TARGET_ACCESS_TOKEN="${TARGET_ACCESS_TOKEN:-your-target-access-token}"
TARGET_PROXY="${TARGET_PROXY:-}"
ALLOW_INSECURE_SSL="${ALLOW_INSECURE_SSL:-false}"

OUTPUT_DIR="./gitlab_exports"
LOG_FILE="gitlab_migration.log"

mkdir -p "$OUTPUT_DIR"
echo "=== GitLab Migration Started at $(date) ===" > "$LOG_FILE"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# CURL OPTIONS
curl_args=()
[ "$ALLOW_INSECURE_SSL" = true ] && curl_args+=(--insecure)

curl_src() {
    curl "${curl_args[@]}" -s --header "PRIVATE-TOKEN: $SRC_ACCESS_TOKEN" "$@"
}

curl_target() {
    if [ -n "$TARGET_PROXY" ]; then
        curl "${curl_args[@]}" --proxy "$TARGET_PROXY" -s --header "PRIVATE-TOKEN: $TARGET_ACCESS_TOKEN" "$@"
    else
        curl "${curl_args[@]}" -s --header "PRIVATE-TOKEN: $TARGET_ACCESS_TOKEN" "$@"
    fi
}

# Get namespace ID from full path
get_target_namespace_id() {
    local FULL_PATH="$1"
    local NS=$(curl_target "$TARGET_GITLAB_URL/api/v4/namespaces?search=$(basename "$FULL_PATH")")
    echo "$NS" | jq -r ".[] | select(.full_path==\"$FULL_PATH\") | .id"
}

# Recursively fetch all projects in a group
get_all_projects() {
    local GROUP_ID=$1
    curl_src "$SRC_GITLAB_URL/api/v4/groups/$GROUP_ID/projects?include_subgroups=true&per_page=100"
}

# MAIN
log "Fetching all projects from source group..."
PROJECTS_JSON=$(get_all_projects "$SRC_GROUP_ID")

echo "$PROJECTS_JSON" | jq -c '.[]' | while read -r PROJECT; do
    PROJECT_ID=$(echo "$PROJECT" | jq -r '.id')
    PROJECT_NAME=$(echo "$PROJECT" | jq -r '.path')
    PATH_WITH_NAMESPACE=$(echo "$PROJECT" | jq -r '.path_with_namespace')
    
    # Get group-relative path (excluding root group)
    GROUP_PATH_ONLY=$(dirname "$PATH_WITH_NAMESPACE")
    RELATIVE_GROUP_PATH=$(echo "$GROUP_PATH_ONLY" | sed "s|^$SRC_GROUP_ID||" | sed 's|^/||')

    if [ -n "$RELATIVE_GROUP_PATH" ]; then
        DEST_NAMESPACE_PATH="$TARGET_ROOT_NAMESPACE_PATH/$RELATIVE_GROUP_PATH"
    else
        DEST_NAMESPACE_PATH="$TARGET_ROOT_NAMESPACE_PATH"
    fi

    TARGET_NAMESPACE_ID=$(get_target_namespace_id "$DEST_NAMESPACE_PATH")

    if [ -z "$TARGET_NAMESPACE_ID" ] || [ "$TARGET_NAMESPACE_ID" == "null" ]; then
        log "Could not find target namespace for $DEST_NAMESPACE_PATH — skipping $PROJECT_NAME"
        continue
    fi

    EXPORT_FILE="$OUTPUT_DIR/$(echo "$PATH_WITH_NAMESPACE" | tr '/' '_').tar.gz"
    log "Processing $PATH_WITH_NAMESPACE → target ns: $DEST_NAMESPACE_PATH (ID: $TARGET_NAMESPACE_ID)"

    # Trigger export
    curl_src -X POST "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export" > /dev/null
    log "Triggered export for $PROJECT_NAME"

    # Wait for export to complete
    while true; do
        STATUS=$(curl_src "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export" | jq -r '.export_status')
        [ "$STATUS" == "finished" ] && break
        [ "$STATUS" == "none" ] && log "Failed to export $PROJECT_NAME — skipping" && continue 2
        sleep 5
    done

    # Download archive
    curl_src "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export/download" --output "$EXPORT_FILE"
    log "Downloaded export to $EXPORT_FILE"

    # Create project on target
    NEW_PROJECT=$(curl_target -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$PROJECT_NAME\", \"namespace_id\": \"$TARGET_NAMESPACE_ID\"}" \
        "$TARGET_GITLAB_URL/api/v4/projects")

    NEW_PROJECT_ID=$(echo "$NEW_PROJECT" | jq -r '.id')
    [ "$NEW_PROJECT_ID" == "null" ] && log "Failed to create project $PROJECT_NAME" && continue

    # Upload export
    curl_target -X POST \
        -F "file=@$EXPORT_FILE" \
        "$TARGET_GITLAB_URL/api/v4/projects/$NEW_PROJECT_ID/import" > /dev/null
    log "Imported $PROJECT_NAME"
done

log "All projects processed."