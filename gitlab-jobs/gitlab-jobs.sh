#!/bin/bash

# CONFIGURATION
GITLAB_API="https://gitlab.com/api/v4"
ACCESS_TOKEN="your_access_token_here"  # Replace with your token
GROUP_PATH="your_group_path_here"      # Example: my-group or my-group/subgroup

# Function to get all projects in the group (with pagination)
get_all_projects() {
    local page=1
    while : ; do
        response=$(curl --silent --header "PRIVATE-TOKEN: $ACCESS_TOKEN" \
            "$GITLAB_API/groups/${GROUP_PATH//\//%2F}/projects?per_page=100&page=$page")
        
        # Break if response is empty or null
        if [[ "$(echo "$response" | jq 'length')" -eq 0 ]]; then
            break
        fi

        echo "$response" | jq -r '.[].id'
        ((page++))
    done
}

# Function to get the most recent job date for a project's latest pipeline
get_latest_job_date() {
    local project_id=$1

    # Get the latest pipeline for the project
    pipeline=$(curl --silent --header "PRIVATE-TOKEN: $ACCESS_TOKEN" \
        "$GITLAB_API/projects/$project_id/pipelines?per_page=1&page=1")

    pipeline_id=$(echo "$pipeline" | jq -r '.[0].id')

    if [[ "$pipeline_id" == "null" || -z "$pipeline_id" ]]; then
        return
    fi

    # Get jobs from the latest pipeline
    jobs=$(curl --silent --header "PRIVATE-TOKEN: $ACCESS_TOKEN" \
        "$GITLAB_API/projects/$project_id/pipelines/$pipeline_id/jobs")

    echo "$jobs" | jq -r '.[].created_at'
}

# MAIN
echo "Fetching latest job dates from projects in group: $GROUP_PATH"
latest_date=""

for project_id in $(get_all_projects); do
    for job_date in $(get_latest_job_date "$project_id"); do
        if [[ -z "$latest_date" || "$job_date" > "$latest_date" ]]; then
            latest_date="$job_date"
        fi
    done
done

if [[ -n "$latest_date" ]]; then
    echo "Most recent job date: $latest_date"
else
    echo "No jobs found in the group."
fi