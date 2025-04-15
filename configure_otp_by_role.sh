#!/bin/bash
# Author: GASSAI Hamza
# Modified script to configure OTP for users with specific roles (with pagination support)
# Usage: ./CONFIGURE_TOTP_FOR_ROLES.sh <keycloak-url> <realm> <admin-username> <admin-password> <comma-separated-role-names>

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

# Pagination variables
MAX_USERS_PER_PAGE=100
FIRST=0
TOTAL_USERS=0
PROCESSED_USERS=0
USERS_WITH_ROLES=0

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

# First, get the total number of users
echo "Getting total user count..."
TOTAL_USERS_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users/count" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json")

TOTAL_USERS=$(echo $TOTAL_USERS_RESPONSE | grep -o '[0-9]*')
echo -e "${GREEN}Found $TOTAL_USERS users in realm $REALM${NC}"

# Process users in batches
while [ $FIRST -lt $TOTAL_USERS ]; do
  echo "Processing users $FIRST to $((FIRST + MAX_USERS_PER_PAGE))..."
  
  # Get users for current page
  USERS_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users?first=$FIRST&max=$MAX_USERS_PER_PAGE" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json")

  # Check if the API call was successful
  if [[ $USERS_RESPONSE == *"error"* ]]; then
    echo -e "${RED}Failed to retrieve users:${NC}"
    echo $USERS_RESPONSE
    exit 1
  fi

  # Extract user IDs and usernames for current page
  USER_IDS=($(echo $USERS_RESPONSE | grep -o '"id":"[^"]*' | cut -d'"' -f4))
  USER_NAMES=($(echo $USERS_RESPONSE | grep -o '"username":"[^"]*' | cut -d'"' -f4))

  # For each user in current page, check roles and add CONFIGURE_TOTP if they have the target roles
  for i in "${!USER_IDS[@]}"; do
    USER_ID=${USER_IDS[$i]}
    USERNAME=${USER_NAMES[$i]}
    ((PROCESSED_USERS++))
    
    echo -n "[$PROCESSED_USERS/$TOTAL_USERS] Checking roles for user: $USERNAME (ID: $USER_ID)... "
    
    # Get user's realm roles
    USER_ROLES_RESPONSE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/role-mappings/realm" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json")
    
    # Extract role names
    USER_ROLE_NAMES=($(echo $USER_ROLES_RESPONSE | grep -o '"name":"[^"]*' | cut -d'"' -f4))
    
    # Check if user has any of the target roles
    HAS_TARGET_ROLE=0
    for role in "${USER_ROLE_NAMES[@]}"; do
      for target_role in "${TARGET_ROLES[@]}"; do
        if [ "$role" == "$target_role" ]; then
          HAS_TARGET_ROLE=1
          break 2
        fi
      done
    done
    
    if [ $HAS_TARGET_ROLE -eq 0 ]; then
      echo -e "${YELLOW}No target roles${NC}"
      continue
    fi
    
    echo -e "${GREEN}Has target role${NC}"
    ((USERS_WITH_ROLES++))
    
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
  
  # Move to next page
  FIRST=$((FIRST + MAX_USERS_PER_PAGE))
done

echo -e "${GREEN}OTP configuration completed for $USERS_WITH_ROLES users with roles [$ROLE_NAMES] in realm $REALM${NC}"
echo "Processed $PROCESSED_USERS out of $TOTAL_USERS total users."
echo "Affected users will be prompted to configure OTP on their next login."