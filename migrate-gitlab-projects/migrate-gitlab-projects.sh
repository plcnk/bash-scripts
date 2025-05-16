#!/bin/bash

# ========== CONFIGURATION ==========
SOURCE_GITLAB="https://source.gitlab.com"
DEST_GITLAB="https://destination.gitlab.com"
SOURCE_GROUP_ID="123456"  # Numeric ID of the group to export
SOURCE_TOKEN="source_gitlab_token"
DEST_TOKEN="destination_gitlab_token"
DEST_PROXY="http://proxy.example.com:8080"

TMP_DIR=$(mktemp -d)
EXPORT_POLL_INTERVAL=5
IMPORT_POLL_INTERVAL=5

# ========== EXPORT PROJECTS ==========
echo "Fetching projects from source group..."
projects=$(curl -s --header "PRIVATE-TOKEN: $SOURCE_TOKEN" "$SOURCE_GITLAB/api/v4/groups/$SOURCE_GROUP_ID/projects?include_subgroups=false&per_page=100" | jq -r '.[] | .id, .name, .path')

# Convert the flat output to an array of triplets
mapfile -t project_array <<< "$projects"

echo "Total projects: $((${#project_array[@]}/3))"

for ((i=0; i<${#project_array[@]}; i+=3)); do
  project_id="${project_array[$i]}"
  project_name="${project_array[$i+1]}"
  project_slug="${project_array[$i+2]}"

  echo "Exporting project: $project_name ($project_slug)..."

  # Trigger export
  curl -s --request POST --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
    "$SOURCE_GITLAB/api/v4/projects/$project_id/export"

  # Poll for export completion
  while true; do
    status=$(curl -s --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
      "$SOURCE_GITLAB/api/v4/projects/$project_id/export" | jq -r '.export_status')
    echo "  Status: $status"
    if [[ "$status" == "finished" ]]; then
      break
    fi
    sleep $EXPORT_POLL_INTERVAL
  done

  # Download export file
  echo "Downloading export..."
  curl -s --header "PRIVATE-TOKEN: $SOURCE_TOKEN" \
    "$SOURCE_GITLAB/api/v4/projects/$project_id/export/download" \
    -o "$TMP_DIR/${project_slug}.tar.gz"
done

# ========== IMPORT TO DESTINATION ==========
for ((i=0; i<${#project_array[@]}; i+=3)); do
  project_name="${project_array[$i+1]}"
  project_slug="${project_array[$i+2]}"
  export_file="$TMP_DIR/${project_slug}.tar.gz"

  echo "Importing project: $project_name ($project_slug)..."

  # Create the new project
  create_response=$(curl -sk -x "$DEST_PROXY" --request POST \
    --header "PRIVATE-TOKEN: $DEST_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\": \"$project_name\", \"path\": \"$project_slug\"}" \
    "$DEST_GITLAB/api/v4/projects")

  dest_project_id=$(echo "$create_response" | jq -r '.id')

  if [[ "$dest_project_id" == "null" || -z "$dest_project_id" ]]; then
    echo "  Failed to create project: $create_response"
    continue
  fi

  # Upload export file
  echo "  Uploading archive..."
  curl -sk -x "$DEST_PROXY" --request POST \
    --header "PRIVATE-TOKEN: $DEST_TOKEN" \
    -F "file=@$export_file" \
    "$DEST_GITLAB/api/v4/projects/$dest_project_id/import"

  # Optional: poll for import status
  while true; do
    status=$(curl -sk -x "$DEST_PROXY" \
      --header "PRIVATE-TOKEN: $DEST_TOKEN" \
      "$DEST_GITLAB/api/v4/projects/$dest_project_id/import" | jq -r '.import_status')

    echo "  Import status: $status"
    if [[ "$status" == "finished" || "$status" == "none" ]]; then
      break
    fi
    sleep $IMPORT_POLL_INTERVAL
  done
done

# Cleanup
rm -rf "$TMP_DIR"
echo "Migration completed."