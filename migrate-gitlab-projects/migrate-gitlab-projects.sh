#!/bin/bash

# === Configuration ===
SRC_GITLAB_URL="https://source.gitlab.com"
DST_GITLAB_URL="https://destination.gitlab.com"
SRC_GROUP_ID="12345"  # Numeric group ID, not path
SRC_TOKEN="your_source_gitlab_token"
DST_TOKEN="your_destination_gitlab_token"
PROXY="http://your.proxy.server:port"

# Temporary storage
EXPORT_DIR="./exports"
mkdir -p "$EXPORT_DIR"

# === Step 1: Get all projects in the group (not including subgroups) ===
echo "[*] Fetching project list from source group..."

projects=$(curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
  "$SRC_GITLAB_URL/api/v4/groups/$SRC_GROUP_ID/projects?include_subgroups=false&per_page=100" | jq -c '.[]')

# === Step 2: Export and download each project ===
for project in $projects; do
  project_id=$(echo "$project" | jq '.id')
  project_name=$(echo "$project" | jq -r '.name')
  project_path=$(echo "$project" | jq -r '.path')

  echo "[*] Exporting project: $project_name"

  # Start export
  curl -s -k --request POST \
    --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export" >/dev/null

  # Wait for export to complete
  echo "    Waiting for export to finish..."
  while true; do
    export_status=$(curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
      "$SRC_GITLAB_URL/api/v4/projects/$project_id/export" | jq -r '.export_status')
    if [[ "$export_status" == "finished" ]]; then
      break
    fi
    sleep 2
  done

  # Download the export file
  echo "    Downloading export for $project_name..."
  curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export/download" \
    -o "$EXPORT_DIR/${project_path}.tar.gz"
done

# === Step 3: Import projects to destination GitLab ===
for file in "$EXPORT_DIR"/*.tar.gz; do
  slug=$(basename "$file" .tar.gz)

  echo "[*] Importing project: $slug"

  curl -s -k --proxy "$PROXY" --request POST \
    --header "PRIVATE-TOKEN: $DST_TOKEN" \
    -F "path=$slug" \
    -F "file=@$file" \
    "$DST_GITLAB_URL/api/v4/projects/import" | jq
done

echo "[*] Migration complete!"