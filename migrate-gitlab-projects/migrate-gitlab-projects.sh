#!/bin/bash

# ==== Configuration ====

SOURCE_GITLAB="https://source.gitlab.com"
SOURCE_TOKEN="source_token_here"
SOURCE_GROUP_ID="source_group_id_here"

DEST_GITLAB="https://destination.gitlab.com"
DEST_TOKEN="destination_token_here"
DEST_GROUP_ID="destination_group_id_here"

DEST_PROXY="http://your.proxy:port"

# Temporary folder to store exports
EXPORT_DIR="./gitlab_exports"
mkdir -p "$EXPORT_DIR"

# ==== Functions ====

# Get all top-level projects from source group (no subgroups)
get_source_projects() {
  curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
    "$SOURCE_GITLAB/api/v4/groups/$SOURCE_GROUP_ID/projects?include_subgroups=false&per_page=100" | jq -c '.[]'
}

# Export a project and wait until it's ready
export_project() {
  local project_id=$1
  echo "Requesting export for project ID $project_id..."
  curl -sk --request POST \
    --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
    "$SOURCE_GITLAB/api/v4/projects/$project_id/export"

  # Wait for export to be ready
  echo "Waiting for export to be ready..."
  while true; do
    status=$(curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
      "$SOURCE_GITLAB/api/v4/projects/$project_id/export" | jq -r '.export_status')
    [ "$status" == "finished" ] && break
    sleep 5
  done
}

# Download export file
download_export() {
  local project_id=$1
  local slug=$2
  echo "Downloading export for $slug..."
  curl -sk --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
    "$SOURCE_GITLAB/api/v4/projects/$project_id/export/download" \
    -o "$EXPORT_DIR/$slug.tar.gz"
}

# Import project into destination GitLab
import_project() {
  local slug=$1
  echo "Importing $slug into destination GitLab..."

  curl -sk --proxy "$DEST_PROXY" --request POST \
    --header "PRIVATE-TOKEN: $DEST_TOKEN" \
    --form "path=$slug" \
    --form "namespace_id=$DEST_GROUP_ID" \
    --form "file=@$EXPORT_DIR/$slug.tar.gz" \
    "$DEST_GITLAB/api/v4/projects/import"
}

# ==== Main Script ====

echo "Fetching projects from source GitLab group..."
get_source_projects | while read -r project; do
  id=$(echo "$project" | jq -r '.id')
  slug=$(echo "$project" | jq -r '.path')

  echo "Processing project: $slug (ID: $id)"
  export_project "$id"
  download_export "$id" "$slug"
  import_project "$slug"
done

echo "Done!"