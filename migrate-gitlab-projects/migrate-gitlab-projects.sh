#!/bin/bash

# ====== Configuration ======
SRC_GITLAB_URL="https://source.gitlab.com"
SRC_TOKEN="your_source_token"
SRC_GROUP_ID="1234"  # Use numeric group ID

DEST_GITLAB_URL="https://destination.gitlab.com"
DEST_TOKEN="your_destination_token"
DEST_GROUP_ID="5678"  # Use numeric group ID

# Proxy for destination GitLab
export https_proxy="http://your.proxy:port"

EXPORT_DIR="./exports"
mkdir -p "$EXPORT_DIR"

# ====== Export projects from source GitLab ======
echo "Fetching projects from source group $SRC_GROUP_ID..."

projects=$(curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
  "$SRC_GITLAB_URL/api/v4/groups/$SRC_GROUP_ID/projects?per_page=100" | jq -r '.[].id')

for project_id in $projects; do
  echo "Requesting export for project ID: $project_id"
  
  curl -s -k --request POST --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export" > /dev/null

  echo "Waiting for export to finish..."
  while true; do
    status=$(curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
      "$SRC_GITLAB_URL/api/v4/projects/$project_id/export" | jq -r '.export_status')

    if [[ "$status" == "finished" ]]; then
      break
    fi
    sleep 3
  done

  echo "Downloading export file..."
  curl -s -k --header "PRIVATE-TOKEN: $SRC_TOKEN" \
    "$SRC_GITLAB_URL/api/v4/projects/$project_id/export/download" \
    -o "$EXPORT_DIR/project_$project_id.tar.gz"
done

# ====== Import to destination GitLab ======
for file in "$EXPORT_DIR"/*.tar.gz; do
  echo "Importing $file to destination GitLab..."

  curl -s -k --header "PRIVATE-TOKEN: $DEST_TOKEN" \
    -F "path=$(basename "$file" .tar.gz)" \
    -F "namespace_id=$DEST_GROUP_ID" \
    -F "file=@$file" \
    "$DEST_GITLAB_URL/api/v4/projects/import"
done

echo "Migration complete."