#!/bin/bash

# Brave Search CLI Tool Handler
# Receives JSON input from stdin and outputs JSON result to stdout
# Input:  {"command": "search", "flags": {"query": "...", "limit": 10, "apiKey": "..."}}
# Output: {"success": true, "data": {...}} or {"success": false, "error": "..."}

# Read input from stdin
input=$(cat 2>/dev/null)

if [[ -z "$input" ]]; then
  echo '{"success": false, "error": "No input provided"}'
  exit 0
fi

# Extract command, query, limit, and apiKey from JSON input
# Use defensive parsing to handle invalid JSON
command=$(echo "$input" | jq -r '.command // empty' 2>/dev/null)
query=$(echo "$input" | jq -r '.flags.query // empty' 2>/dev/null)
limit=$(echo "$input" | jq -r '.flags.limit // 10' 2>/dev/null)
apiKey=$(echo "$input" | jq -r '.flags.apiKey // empty' 2>/dev/null)

# Check if jq parsing failed
if [[ $? -ne 0 ]]; then
  echo '{"success": false, "error": "Invalid JSON input"}'
  exit 0
fi

# Validate inputs
if [[ -z "$command" ]]; then
  echo '{"success": false, "error": "Missing command"}'
  exit 0
fi

if [[ "$command" != "search" ]]; then
  echo "{\"success\": false, \"error\": \"Unknown command: $command\"}"
  exit 0
fi

if [[ -z "$query" ]]; then
  echo '{"success": false, "error": "Missing query parameter"}'
  exit 0
fi

if [[ -z "$apiKey" ]]; then
  echo '{"success": false, "error": "Missing apiKey parameter"}'
  exit 0
fi

# Ensure limit is a valid number
if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
  limit=10
fi

# Call Brave Search API
# URL encode the query
encoded_query=$(echo -n "$query" | jq -sRr @uri 2>/dev/null || echo "$query")

response=$(curl -s \
  -H "Accept: application/json" \
  -H "X-Subscription-Token: $apiKey" \
  "https://api.search.brave.com/res/v1/web/search?q=$encoded_query&count=$limit" 2>/dev/null)

# Check curl success
if [[ $? -ne 0 ]]; then
  echo '{"success": false, "error": "Failed to call Brave Search API"}'
  exit 0
fi

# Check if response is valid JSON
if ! echo "$response" | jq empty 2>/dev/null; then
  echo '{"success": false, "error": "Invalid response from Brave Search API"}'
  exit 0
fi

# Check for API errors
status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null)
if [[ "$status" != "" && "$status" != "200" ]]; then
  error_msg=$(echo "$response" | jq -r '.detail // .error // "Unknown error"' 2>/dev/null)
  echo "{\"success\": false, \"error\": \"Brave Search API error: $error_msg\"}"
  exit 0
fi

# Check for code field (error indicator)
code=$(echo "$response" | jq -r '.code // empty' 2>/dev/null)
if [[ ! -z "$code" ]]; then
  detail=$(echo "$response" | jq -r '.detail // "Unknown error"' 2>/dev/null)
  echo "{\"success\": false, \"error\": \"Brave Search API error: $detail\"}"
  exit 0
fi

# Parse and format results
results_array=$(echo "$response" | jq '[.web[]? | {title: .title, link: .url, snippet: .description}]' 2>/dev/null)

if [[ $? -ne 0 ]]; then
  results_array="[]"
fi

# Return success response
count=$(echo "$results_array" | jq 'length' 2>/dev/null || echo "0")
echo "{\"success\": true, \"data\": {\"engine\": \"Brave Search\", \"query\": $query_escaped, \"count\": $count, \"results\": $results_array}}"

exit 0
