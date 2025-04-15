#!/bin/bash

# Script to configure OTP as a required action for all Keycloak users in a specific group
# Usage: ./configure_group_otp.sh <keycloak-url> <realm> <admin-username> <admin-password> <group-name>

# Check if all arguments are provided
if [ $# -ne 5 ]; then
  echo "Usage: $0 <keycloak-url> <realm> <admin-username> <admin-password> <group-name>"
  echo "Example: $0 https://keycloak.example.com master admin password123 finance-team"
  exit 1
fi

# Assign arguments to variables
KEYCLOAK_URL=$1
REALM=$2
ADMIN_USERNAME=$3
ADMIN_PASSWORD=$4
GROUP_NAME=$5

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting OTP configuration for all users in group '$GROUP_NAME' (realm: $REALM)${NC}"

# Get an access token
echo "Obtaining admin access token..."
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$ADMIN_USERNAME" \
  -d "password=$ADMIN_PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

# Extract the access token
ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

if [ -z "$ACCESS_TOKEN" ]; then
  echo -e "${RED}Failed to obtain access token. Please check your credentials and Keycloak URL.${NC}"
  echo "Response: $TOKEN_RESPONSE"
  exit 1
fi

echo -e "${GREEN}Access token obtained successfully.${NC}"

# Find the group ID by name
echo -e "${BLUE}Searching for group: $GROUP_NAME${NC}"
GROUPS_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=$GROUP_NAME" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json")

# Check if the group exists
if [[ $GROUPS_RESPONSE == "[]" ]]; then
  echo -e "${RED}Group '$GROUP_NAME' not found in realm $REALM${NC}"
  exit 1
fi

# Extract the group ID
GROUP_ID=$(echo $GROUPS_RESPONSE | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)

if [ -z "$GROUP_ID" ]; then
  echo -e "${RED}Failed to extract group ID for '$GROUP_NAME'${NC}"
  exit 1
fi

echo -e "${GREEN}Found group '$GROUP_NAME' with ID: $GROUP_ID${NC}"

# Get all users in the group
echo "Retrieving users from group '$GROUP_NAME'..."
GROUP_MEMBERS=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/groups/$GROUP_ID/members" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json")

# Check if the API call was successful
if [[ $GROUP_MEMBERS == *"error"* ]]; then
  echo -e "${RED}Failed to retrieve group members:${NC}"
  echo $GROUP_MEMBERS
  exit 1
fi

# Extract user IDs and usernames
echo "Parsing user information..."
USER_IDS=($(echo $GROUP_MEMBERS | grep -o '"id":"[^"]*' | cut -d'"' -f4))
USER_NAMES=($(echo $GROUP_MEMBERS | grep -o '"username":"[^"]*' | cut -d'"' -f4))

# Check if any users were found
if [ ${#USER_IDS[@]} -eq 0 ]; then
  echo -e "${RED}No users found in group '$GROUP_NAME'${NC}"
  exit 1
fi

echo -e "${GREEN}Found ${#USER_IDS[@]} users in group '$GROUP_NAME'${NC}"

# Counter for successful updates
SUCCESS_COUNT=0

# For each user, add the CONFIGURE_OTP required action
for i in "${!USER_IDS[@]}"; do
  USER_ID=${USER_IDS[$i]}
  USERNAME=${USER_NAMES[$i]}
  
  echo -e "${BLUE}Processing user: $USERNAME (ID: $USER_ID)${NC}"
  
  # Get current user details
  USER_DETAILS=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json")
  
  # Extract current required actions, if any
  CURRENT_REQUIRED_ACTIONS=$(echo $USER_DETAILS | grep -o '"requiredActions":\[[^]]*\]' | sed 's/"requiredActions"://')
  
  # Check if the user already has CONFIGURE_OTP in required actions
  if [[ $CURRENT_REQUIRED_ACTIONS == *"CONFIGURE_OTP"* ]]; then
    echo -e "${YELLOW}User $USERNAME already has CONFIGURE_OTP as a required action. Skipping.${NC}"
    continue
  fi
  
  # Prepare the update payload
  if [ -z "$CURRENT_REQUIRED_ACTIONS" ] || [ "$CURRENT_REQUIRED_ACTIONS" == "[]" ]; then
    # No required actions yet
    UPDATE_PAYLOAD="{\"requiredActions\":[\"CONFIGURE_OTP\"]}"
  else
    # Add to existing required actions
    # Remove the closing bracket, add the new action, then close the bracket again
    MODIFIED_ACTIONS=$(echo $CURRENT_REQUIRED_ACTIONS | sed 's/\]$/,\"CONFIGURE_OTP\"]/')
    UPDATE_PAYLOAD="{\"requiredActions\":$MODIFIED_ACTIONS}"
  fi
  
  # Update the user with the new required action
  UPDATE_RESPONSE=$(curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$UPDATE_PAYLOAD")
  
  # Check if update was successful (PUT returns empty response on success)
  if [ -z "$UPDATE_RESPONSE" ]; then
    echo -e "${GREEN}Successfully updated user $USERNAME with CONFIGURE_OTP required action.${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo -e "${RED}Failed to update user $USERNAME:${NC}"
    echo $UPDATE_RESPONSE
  fi
done

echo ""
echo -e "${GREEN}Summary:${NC}"
echo -e "Total users in group '$GROUP_NAME': ${#USER_IDS[@]}"
echo -e "Successfully configured OTP for: $SUCCESS_COUNT users"
echo -e "${YELLOW}Users will be prompted to configure OTP on their next login.${NC}"