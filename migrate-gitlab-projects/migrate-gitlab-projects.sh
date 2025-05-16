#!/bin/bash

# ==== CONFIGURATION ====
SRC_GITLAB_URL="https://source.gitlab.com"
SRC_TOKEN="your_source_token"
SRC_GROUP_ID="1234"  # Source group numeric ID

DEST_GITLAB_URL="https://destination.gitlab.com"
DEST_TOKEN="your_destination_token"

# Destination proxy
DEST_PROXY="http://your.proxy:port"

# =========================

if [ -z "$1" ]; then
  echo "Usage: $0 <target_group_id>"
  exit 1
fi

DEST_GROUP_ID="$1"
EXPORT_DIR="./exports"
mkdir -p "$EXPORT_DIR"

# ===== FUNCTION: extract value from JSON using grep & sed =====
extract_value() {
  echo "$1" | grep -o "\"$2\":[^,}]*" | head -n1 | sed -E "s/\"$2\":(null|\"|)//g" | sed -E 's/\"$//g'
}

# ===== GET PROJECT LIST =====
echo "Fetching projects from source group..."

project_list=$(curl -sk --header "PRIVATE-TOKEN: $SRC_TOKEN" \
  "$SRC_GITLAB_URL/api/v4/groups/$SRC_GROUP_ID/projects?per_page=100")

project_ids=($(echo "$project_list" | grep -o '"id":[0-9]*' | cut -d: -f2))

# ===== EXPORT EACH PROJECT =====
for project_id in "${project_ids[@]}"; do
  echo "Requesting export for project ID: $project_id"

  curl -sk --request POST --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export" > /dev/null

  echo "Waiting for export to finish..."
  while true; do
    status=$(curl -sk --header "PRIVATE-TOKEN: $SRC_TOKEN" \
      "$SRC_GITLAB_URL/api/v4/projects/$project_id/export")

    export_status=$(extract_value "$status" "export_status")

    if [ "$export_status" == "finished" ]; then
      break
    fi
    sleep 3
  done

  echo "Downloading export file for project $project_id"
  curl -sk --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export/download" \
    -o "$EXPORT_DIR/project_$project_id.tar.gz"
done

# ===== IMPORT TO DESTINATION =====
echo "Importing projects to destination group ID: $DEST_GROUP_ID"

for file in "$EXPORT_DIR"/*.tar.gz; do
  slug=$(basename "$file" .tar.gz | sed 's/project_//')

  echo "Importing project $slug"

  https_proxy="$DEST_PROXY" curl -sk --header "PRIVATE-TOKEN: $DEST_TOKEN" \
    -F "path=imported_project_$slug" \
    -F "namespace_id=$DEST_GROUP_ID" \
    -F "file=@$file" \
    "$DEST_GITLAB_URL/api/v4/projects/import"
done

echo "Done."