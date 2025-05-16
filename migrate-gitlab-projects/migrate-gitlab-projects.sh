#!/bin/bash

# === CONFIGURATION ===

SRC_GITLAB_URL="https://gitlab.com"
SRC_GROUP_ID="your-source-group-id-or-path"
SRC_ACCESS_TOKEN="${SRC_ACCESS_TOKEN:-your-source-access-token}"

TARGET_GITLAB_URL="https://gitlab.example.com"
TARGET_ROOT_NAMESPACE_PATH="your-target-group-path"  # e.g., mycompany/dev
TARGET_ACCESS_TOKEN="${TARGET_ACCESS_TOKEN:-your-target-access-token}"
TARGET_PROXY="${TARGET_PROXY:-}"
ALLOW_INSECURE_SSL="${ALLOW_INSECURE_SSL:-false}"

OUTPUT_DIR="./gitlab_exports"
LOG_FILE="gitlab_migration.log"

# === INTERNAL SETUP ===

mkdir -p "$OUTPUT_DIR"
echo "=== GitLab Migration Started at $(date) ===" > "$LOG_FILE"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

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

# === FUNCTIONS ===

get_all_projects_recursive() {
    local GROUP_ID=$1
    local RECURSIVE_PROJECTS=""

    # Get immediate projects
    local PROJECTS=$(curl_src "$SRC_GITLAB_URL/api/v4/groups/$GROUP_ID/projects?include_subgroups=true&per_page=100")
    echo "$PROJECTS" | jq -c '.[]'  # Output each project JSON as one line

    # Get subgroups
    local SUBGROUPS=$(curl_src "$SRC_GITLAB_URL/api/v4/groups/$GROUP_ID/subgroups?per_page=100")
    local SUBGROUP_IDS=$(echo "$SUBGROUPS" | jq -r '.[].id')

    for SG_ID in $SUBGROUP_IDS; do
        get_all_projects_recursive "$SG_ID"
    done
}

get_target_namespace_id() {
    local REL_PATH="$1"
    local FULL_PATH="$TARGET_ROOT_NAMESPACE_PATH/$REL_PATH"
    local ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FULL_PATH', safe=''))")

    local NS_ID=$(curl_target "$TARGET_GITLAB_URL/api/v4/namespaces/$ENCODED_PATH" | jq -r '.id')
    echo "$NS_ID"
}

# === MAIN ===

log "Fetching all projects from source group and subgroups..."
ALL_PROJECTS=$(get_all_projects_recursive "$SRC_GROUP_ID")

echo "$ALL_PROJECTS" | while read -r PROJECT_JSON; do
    PROJECT_ID=$(echo "$PROJECT_JSON" | jq -r '.id')
    PROJECT_NAME=$(echo "$PROJECT_JSON" | jq -r '.path')
    PATH_WITH_NAMESPACE=$(echo "$PROJECT_JSON" | jq -r '.path_with_namespace')
    RELATIVE_GROUP_PATH=$(dirname "$PATH_WITH_NAMESPACE" | sed "s|^$(echo "$SRC_GROUP_ID" | sed 's/\//\\\//g')||" | sed 's|^/||')

    TARGET_NAMESPACE_ID=$(get_target_namespace_id "$RELATIVE_GROUP_PATH")

    if [ "$TARGET_NAMESPACE_ID" == "null" ] || [ -z "$TARGET_NAMESPACE_ID" ]; then
        log "❌ Could not find target namespace for: $RELATIVE_GROUP_PATH — skipping $PROJECT_NAME"
        continue
    fi

    EXPORT_FILE="$OUTPUT_DIR/$(echo "$PATH_WITH_NAMESPACE" | tr '/' '_').tar.gz"

    log "Processing $PATH_WITH_NAMESPACE (ID: $PROJECT_ID) → target namespace ID: $TARGET_NAMESPACE_ID"

    # Trigger export
    curl_src -X POST "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export" > /dev/null
    log "Triggered export for $PROJECT_NAME"

    # Wait for export to finish
    while true; do
        STATUS=$(curl_src "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export" | jq -r '.export_status')
        if [ "$STATUS" == "finished" ]; then
            log "Export ready for $PROJECT_NAME"
            break
        elif [ "$STATUS" == "none" ]; then
            log "❌ Failed to export $PROJECT_NAME — skipping"
            continue 2
        else
            sleep 5
        fi
    done

    # Download export
    curl_src "$SRC_GITLAB_URL/api/v4/projects/$PROJECT_ID/export/download" \
        --output "$EXPORT_FILE"
    log "Downloaded export to $EXPORT_FILE"

    # Create project on target
    NEW_PROJECT=$(curl_target -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$PROJECT_NAME\", \"namespace_id\": \"$TARGET_NAMESPACE_ID\"}" \
        "$TARGET_GITLAB_URL/api/v4/projects")

    NEW_PROJECT_ID=$(echo "$NEW_PROJECT" | jq -r '.id')
    if [ "$NEW_PROJECT_ID" == "null" ]; then
        ERR=$(echo "$NEW_PROJECT" | jq -r '.message')
        log "❌ Failed to create $PROJECT_NAME on target GitLab: $ERR"
        continue
    fi

    # Upload export archive
    curl_target -X POST \
        -F "file=@$EXPORT_FILE" \
        "$TARGET_GITLAB_URL/api/v4/projects/$NEW_PROJECT_ID/import" > /dev/null
    log "✅ Imported $PROJECT_NAME to target namespace $RELATIVE_GROUP_PATH"
done

log "✅ All projects processed."