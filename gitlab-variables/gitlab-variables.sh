#!/bin/bash

# GitLab settings
GITLAB_API_URL="https://gitlab.com/api/v4"
SOURCE_PROJECT_ID="<source_project_id>"
TARGET_PROJECT_ID="<target_project_id>"
PRIVATE_TOKEN="<your_gitlab_personal_access_token>"

# Export variables from the source project
echo "Exporting variables from project ID: $SOURCE_PROJECT_ID..."
variables=$(curl -s --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  "$GITLAB_API_URL/projects/$SOURCE_PROJECT_ID/variables")

# Check if variables were fetched successfully
if [ -z "$variables" ] || [[ "$variables" == *"message"* ]]; then
  echo "Failed to fetch variables from source project."
  echo "$variables"
  exit 1
fi

# Parse and create each variable in the target project
echo "$variables" | grep -o '{[^}]*}' | while read -r var; do
  key=$(echo "$var" | grep -o '"key":"[^"]*"' | cut -d':' -f2 | tr -d '"')
  value=$(echo "$var" | grep -o '"value":"[^"]*"' | cut -d':' -f2- | tr -d '"')
  protected=$(echo "$var" | grep -o '"protected":[^,}]*' | cut -d':' -f2)
  masked=$(echo "$var" | grep -o '"masked":[^,}]*' | cut -d':' -f2)
  variable_type=$(echo "$var" | grep -o '"variable_type":"[^"]*"' | cut -d':' -f2 | tr -d '"')

  echo "Importing variable: $key"

  # Create the variable in the target project
  curl -s -X POST --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{
      \"key\": \"$key\",
      \"value\": \"$value\",
      \"protected\": $protected,
      \"masked\": $masked,
      \"variable_type\": \"$variable_type\"
    }" \
    "$GITLAB_API_URL/projects/$TARGET_PROJECT_ID/variables" > /dev/null
done

echo "Variable migration completed."