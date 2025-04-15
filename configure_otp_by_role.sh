#!/bin/bash
# Author: GASSAI Hamza
# Script to configure OTP for users who have specific roles
# Usage: ./CONFIGURE_TOTP_BY_ROLES.sh <keycloak-url> <realm> <admin-username> <admin-password> <comma-separated-role-names>

# Check if all arguments are provided
if [ $# -ne 5 ]; then
  echo "Usage: $0 <keycloak-url> <realm> <admin-username> <admin-password> <comma-separated-role-names>"
  echo "Example: $0 https://keycloak.example.com master admin password123 'admin,superuser'"
  exit 1
fi

# Assign arguments to variables
KEYCLOAK_URL=$1
REALM=$2
ADMIN_USERNAME=$3
ADMIN_PASSWORD=$4
ROLE_NAMES=$5

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting OTP configuration for users with roles [$ROLE_NAMES] in realm: $REALM${NC}"

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

# Convert comma-separated role names to array
IFS=',' read -ra TARGET_ROLES <<< "$ROLE_NAMES"

# Initialize counters
TOTAL_USERS=0
USERS_WITH_OTP=0

# Process each role individually
for ROLE_NAME in "${TARGET_ROLES[@]}"; do
  echo -e "\nProcessing role: $ROLE_NAME"
  
  # First, get the role ID
  echo "Getting ID for role: $ROLE_NAME"
  ROLE_ID_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/roles/$ROLE_NAME" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json")
  
  ROLE_ID=$(echo $ROLE_ID_RESPONSE | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$ROLE_ID" ]; then
    echo -e "${RED}Failed to find role: $ROLE_NAME${NC}"
    continue
  fi
  
  echo -e "${GREEN}Found role ID: $ROLE_ID${NC}"
  
  # Get users with this role (no pagination needed as this returns all users with the role)
  echo "Getting users with role: $ROLE_NAME"
  USERS_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/roles/$ROLE_NAME/users" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json")
  
  # Check if the API call was successful
  if [[ $USERS_RESPONSE == *"error"* ]]; then
    echo -e "${RED}Failed to retrieve users for role $ROLE_NAME:${NC}"
    echo $USERS_RESPONSE
    continue
  fi
  
  # Extract user IDs and usernames
  USER_IDS=($(echo $USERS_RESPONSE | grep -o '"id":"[^"]*' | cut -d'"' -f4))
  USER_NAMES=($(echo $USERS_RESPONSE | grep -o '"username":"[^"]*' | cut -d'"' -f4))
  
  if [ ${#USER_IDS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No users found with role $ROLE_NAME${NC}"
    continue
  fi
  
  echo -e "${GREEN}Found ${#USER_IDS[@]} users with role $ROLE_NAME${NC}"
  ((TOTAL_USERS+=${#USER_IDS[@]}))
  
  # For each user, add the CONFIGURE_TOTP required action
  for i in "${!USER_IDS[@]}"; do
    USER_ID=${USER_IDS[$i]}
    USERNAME=${USER_NAMES[$i]}
    
    echo "Processing user: $USERNAME (ID: $USER_ID)"
    
    # Get current user details
    USER_DETAILS=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json")
    
    # Check if the user already has required actions
    if [[ $USER_DETAILS == *"requiredActions"* ]]; then
      # Add CONFIGURE_TOTP to existing required actions if not already present
      if [[ $USER_DETAILS != *"CONFIGURE_TOTP"* ]]; then
        # Extract current required actions and add CONFIGURE_TOTP
        REQUIRED_ACTIONS=$(echo $USER_DETAILS | grep -o '"requiredActions":\[[^]]*' | cut -d':' -f2)
        
        # Remove trailing bracket if present
        REQUIRED_ACTIONS=${REQUIRED_ACTIONS%]}
        
        # Add CONFIGURE_TOTP to the list
        if [[ $REQUIRED_ACTIONS == *"["* ]]; then
          if [[ $REQUIRED_ACTIONS == *","* ]]; then
            UPDATE_PAYLOAD="{\"requiredActions\":${REQUIRED_ACTIONS},\"CONFIGURE_TOTP\"]}"
          else
            UPDATE_PAYLOAD="{\"requiredActions\":${REQUIRED_ACTIONS}\"CONFIGURE_TOTP\"]}"
          fi
        else
          UPDATE_PAYLOAD="{\"requiredActions\":[\"CONFIGURE_TOTP\"]}"
        fi
      else
        echo -e "${YELLOW}User $USERNAME already has CONFIGURE_TOTP as a required action. Skipping.${NC}"
        continue
      fi
    else
      # No required actions, add CONFIGURE_TOTP as the first one
      UPDATE_PAYLOAD="{\"requiredActions\":[\"CONFIGURE_TOTP\"]}"
    fi
    
    # Update the user with the new required action
    UPDATE_RESPONSE=$(curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$UPDATE_PAYLOAD")
    
    # Check if update was successful (PUT returns empty response on success)
    if [ -z "$UPDATE_RESPONSE" ]; then
      echo -e "${GREEN}Successfully updated user $USERNAME with CONFIGURE_TOTP required action.${NC}"
      ((USERS_WITH_OTP++))
    else
      echo -e "${RED}Failed to update user $USERNAME:${NC}"
      echo $UPDATE_RESPONSE
    fi
  done
done

echo -e "\n${GREEN}OTP configuration completed for $USERS_WITH_OTP out of $TOTAL_USERS users with specified roles in realm $REALM${NC}"
echo "Affected users will be prompted to configure OTP on their next login."
