#!/bin/bash
# Author: GASSAI Hamza
# Script to configure OTP as a required action for all Keycloak users
# Usage: ./CONFIGURE_TOTP.sh <keycloak-url> <realm> <admin-username> <admin-password>

# Check if all arguments are provided
if [ $# -ne 4 ]; then
  echo "Usage: $0 <keycloak-url> <realm> <admin-username> <admin-password>"
  echo "Example: $0 https://keycloak.example.com master admin password123"
  exit 1
fi

# Assign arguments to variables
KEYCLOAK_URL=$1
REALM=$2
ADMIN_USERNAME=$3
ADMIN_PASSWORD=$4

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting OTP configuration for all users in realm: $REALM${NC}"

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

# Get all users
echo "Retrieving users from realm $REALM..."
USERS_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json")

# Check if the API call was successful
if [[ $USERS_RESPONSE == *"error"* ]]; then
  echo -e "${RED}Failed to retrieve users:${NC}"
  echo $USERS_RESPONSE
  exit 1
fi

# Extract user IDs and usernames
echo "Parsing user information..."
USER_IDS=($(echo $USERS_RESPONSE | grep -o '"id":"[^"]*' | cut -d'"' -f4))
USER_NAMES=($(echo $USERS_RESPONSE | grep -o '"username":"[^"]*' | cut -d'"' -f4))

# Check if any users were found
if [ ${#USER_IDS[@]} -eq 0 ]; then
  echo -e "${RED}No users found in realm $REALM${NC}"
  exit 1
fi

echo -e "${GREEN}Found ${#USER_IDS[@]} users in realm $REALM${NC}"

# For each user, add the CONFIGURE_TOTP required action
for i in "${!USER_IDS[@]}"; do
  USER_ID=${USER_IDS[$i]}
  USERNAME=${USER_NAMES[$i]}
  
  echo "Setting required action CONFIGURE_TOTP for user: $USERNAME (ID: $USER_ID)"
  
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
  else
    echo -e "${RED}Failed to update user $USERNAME:${NC}"
    echo $UPDATE_RESPONSE
  fi
done

echo -e "${GREEN}OTP configuration completed for all users in realm $REALM${NC}"
echo "Users will be prompted to configure OTP on their next login."