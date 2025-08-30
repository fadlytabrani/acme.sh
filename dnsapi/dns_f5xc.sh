#!/usr/bin/env sh

## Add the following information to your provider config file:
##   DNSAPI=dns_f5xc
##   F5XC_TENANT='your_tenant_name'                 <-- Your F5 XC tenant name
##   F5XC_CLIENT_CERT='path/to/client.p12'          <-- Client certificate file path (P12 format)
##   F5XC_CERT_PASSWORD='your_cert_password'        <-- Password for P12 certificate
##   F5XC_API_TOKEN='your_api_token_here'           <-- Optional: API token (fallback)
##   F5XC_RRSET_IDENTIFIER='your_custom_name'       <-- Optional: Custom RRSet identifier (defaults to hostname)

##
## F5 Distributed Cloud Configuration:
## - Generate API token from F5 XC Console: Settings > API Tokens
## - Ensure the API token has DNS Zone Management permissions
## - Authentication: Client certificates (P12 format, preferred) or API token (fallback)

dns_f5xc_info='F5 Distributed Cloud (F5 XC)
  F5XC_TENANT Tenant Name
  F5XC_CLIENT_CERT Client certificate file path (P12 format, preferred)
  F5XC_CERT_PASSWORD Password for P12 certificate (required if using certificates)
  F5XC_API_TOKEN API Token (fallback)
  F5XC_RRSET_IDENTIFIER Custom RRSet identifier (optional, defaults to hostname)
  
'

########## Public Functions ##########

# Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
# ADD FUNCTION - UNIQUE IDENTIFIER
dns_f5xc_add() {
    fulldomain="$1"
    txtvalue="$2"
    
    # Read configuration variables first
    F5XC_API_TOKEN="${F5XC_API_TOKEN:-$(_readaccountconf_mutable F5XC_API_TOKEN)}"
    F5XC_TENANT="${F5XC_TENANT:-$(_readaccountconf_mutable F5XC_TENANT)}"
    F5XC_CLIENT_CERT="${F5XC_CLIENT_CERT:-$(_readaccountconf_mutable F5XC_CLIENT_CERT)}"
    F5XC_CERT_PASSWORD="${F5XC_CERT_PASSWORD:-$(_readaccountconf_mutable F5XC_CERT_PASSWORD)}"
    
    # Validate credentials early and set up cached certificate data
    if ! _validate_credentials; then
        return 1
    fi
    

    

    
    _debug "Adding TXT record for $fulldomain"
    
    # Get root domain and subdomain
    if ! _get_root "$fulldomain"; then
        _err "Could not find zone for domain: $fulldomain"
        return 1
    fi
    
    # Use the global variables set by _get_root
    domain="$_domain"
    actual_subdomain="$_subdomain"
    
    _debug "Adding TXT record for $actual_subdomain in zone $domain"
    
    # Get current zone configuration
    if ! _f5xc_rest "GET" "/api/config/dns/namespaces/system/dns_zones/$domain"; then
        _err "Failed to get zone configuration"
        return 1
    fi
    
    # Use the global response variable
    zone_config="$_F5XC_LAST_RESPONSE"
    
    # Add TXT record to zone configuration
    if ! _add_txt_record_to_zone "$zone_config" "$actual_subdomain" "$txtvalue"; then
        _err "Failed to add TXT record to zone"
        return 1
    fi
    
    # Update the zone with the modified configuration
    put_result=$(_f5xc_rest "PUT" "/api/config/dns/namespaces/system/dns_zones/$domain" "$_zone_data")
    put_exit_code=$?
    
    if [ $put_exit_code -eq 2 ]; then
        # Special case: Duplicate TXT record detected
        _err "Duplicate TXT record detected - cannot add duplicate"
        return 1
    elif [ $put_exit_code -ne 0 ]; then
        _err "Failed to update zone"
        return 1
    fi
    
    _debug "Successfully added TXT record"
    return 0
}

# Usage: rm  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_f5xc_rm() {
    fulldomain="$1"
    txtvalue="$2"
    
    # Read configuration variables first
    F5XC_API_TOKEN="${F5XC_API_TOKEN:-$(_readaccountconf_mutable F5XC_API_TOKEN)}"
    F5XC_TENANT="${F5XC_TENANT:-$(_readaccountconf_mutable F5XC_TENANT)}"
    F5XC_CLIENT_CERT="${F5XC_CLIENT_CERT:-$(_readaccountconf_mutable F5XC_CLIENT_CERT)}"
    F5XC_CERT_PASSWORD="${F5XC_CERT_PASSWORD:-$(_readaccountconf_mutable F5XC_CERT_PASSWORD)}"
    
    # Validate credentials early and set up cached certificate data
    if ! _validate_credentials; then
        return 1
    fi





    # Parse domain and subdomain
    if ! _get_root "$fulldomain"; then
        _err "invalid domain"
        return 1
    fi

    _debug "Removing TXT record for $_subdomain in zone $_domain"

    # Get the current zone configuration
    if ! _f5xc_rest GET "/api/config/dns/namespaces/system/dns_zones/$_domain"; then
        _err "Failed to get zone configuration"
        return 1
    fi

    # Parse the zone configuration and remove TXT record
    if ! _remove_txt_record_from_zone "$response" "$_subdomain" "$txtvalue"; then
        _debug "No TXT record found to remove for $_subdomain"
        return 0
    fi

    # Update the zone configuration
    put_result=$(_f5xc_rest PUT "/api/config/dns/namespaces/system/dns_zones/$_domain" "$_zone_data")
    put_exit_code=$?
    
    if [ $put_exit_code -eq 2 ]; then
        # Special case: Duplicate TXT record detected (shouldn't happen during removal)
        _err "Unexpected duplicate TXT record error during removal"
        return 1
    elif [ $put_exit_code -ne 0 ]; then
        _err "Failed to update zone configuration"
        return 1
    fi

    _debug "Successfully removed TXT record"
    return 0
}

########## Private Functions ##########

# Parse domain and subdomain from full domain
# _acme-challenge.www.domain.com
# returns
#   _subdomain=_acme-challenge.www
#   _domain=domain.com
_get_root() {
    fulldomain="$1"
    namespace="system" # Hardcode namespace to system
    
    _debug "Finding root zone for: $fulldomain"
    
    # First try to use cached domains for faster lookup
    if [ -n "$_F5XC_CACHED_DOMAINS" ]; then
        _debug "Using cached domains for root domain lookup"
        
        # Find the longest matching domain from cached list
        longest_match=""
        for domain in $_F5XC_CACHED_DOMAINS; do
            if [[ "$fulldomain" == *".$domain" ]] || [[ "$fulldomain" == "$domain" ]]; then
                if [ ${#domain} -gt ${#longest_match} ]; then
                    longest_match="$domain"
                fi
            fi
        done
        
        if [ -n "$longest_match" ]; then
            _debug "Zone found in cache: $longest_match"
            
            # Extract subdomain (everything to the left of the zone)
            subdomain=""
            if [ "$longest_match" != "$fulldomain" ]; then
                subdomain="${fulldomain%.$longest_match}"
            fi
            
            _debug "Subdomain: $subdomain"
            export _domain="$longest_match"
            export _subdomain="$subdomain"
            return 0
        fi
    fi
    
    # Fallback to API lookup if no cached domains or no match found
    _debug "No cached domain match found, falling back to API lookup"
    
    # Split domain into parts and try to find the zone
    domain="$fulldomain"
    
    while [ -n "$domain" ]; do
        _debug "Checking zone: $domain"
        
        # Check if this domain exists as a zone in F5 XC
        # Temporarily redirect stderr to suppress zone discovery errors
        if _f5xc_rest "GET" "/api/config/dns/namespaces/$namespace/dns_zones/$domain" 2>/dev/null; then
            response="$_F5XC_LAST_RESPONSE"
            if echo "$response" | grep -q '"name":\s*"'"$domain"'"'; then
                _debug "Zone found via API: $domain"
                
                # Extract subdomain (everything to the left of the zone)
                subdomain=""
                if [ "$domain" != "$fulldomain" ]; then
                    subdomain="${fulldomain%.$domain}"
                fi
                
                _debug "Subdomain: $subdomain"
                export _domain="$domain"
                export _subdomain="$subdomain"
                return 0
            fi
        fi
        
        # Remove the leftmost part and try again
        old_domain="$domain"
        domain="${domain#*.}"
        
        # Prevent infinite loop: if domain didn't change, break
        if [ "$old_domain" = "$domain" ]; then
            _debug "Domain unchanged, breaking loop: $domain"
            break
        fi
    done
    
    _debug "No zone found for: $fulldomain"
    return 1
}

# Add TXT record to zone configuration
_add_txt_record_to_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    
    # Create a machine-specific RRSet name
    machine_id=$(_get_machine_id 2>/dev/null)
    rrset_name="$machine_id"
    
    _debug "RRSet name: $rrset_name"
    
    # Parse the zone configuration and add TXT record
    if ! _parse_and_modify_zone "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "add"; then
        return 1
    fi
    
    return 0
}

# Remove TXT record from zone configuration
_remove_txt_record_from_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    
    # Create a machine-specific RRSet name
    machine_id=$(_get_machine_id 2>/dev/null)
    rrset_name="$machine_id"
    
    _debug "RRSet name: $rrset_name"
    
    # Parse the zone configuration and remove TXT record
    if ! _parse_and_modify_zone "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "remove"; then
        return 1
    fi
    
    return 0
}

# Parse zone configuration and modify TXT records
_parse_and_modify_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    rrset_name="$4"
    action="$5"
    
    # Use jq if available, otherwise use basic text processing
    if command -v jq >/dev/null 2>&1; then
        _debug "Using jq for zone modification"
        if ! _modify_zone_with_jq "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "$action"; then
            return 1
        fi
    else
        _debug "Using text processing (jq not available)"
        if ! _modify_zone_with_text "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "$action"; then
            return 1
        fi
    fi
    
    return 0
}

# Modify zone using jq (preferred method)
_modify_zone_with_jq() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    rrset_name="$4"
    action="$5"
    
    if [ "$action" = "add" ]; then
        # Check if RRSet already exists and update it, otherwise add new one
        # Get device name and timestamp for descriptions
        machine_id=$(_get_machine_id 2>/dev/null)
        timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
        
        export _zone_data=$(printf "%s" "$zone_config" | jq --arg name "$rrset_name" --arg subdomain "$subdomain" --arg value "$txt_value" --arg machine "$machine_id" --arg timestamp "$timestamp" 'if (.spec.primary.rr_set_group | map(select(.metadata.name == $name)) | length) > 0 then .spec.primary.rr_set_group |= map(if .metadata.name == $name then .rr_set += [{"ttl": 60, "txt_record": {"name": $subdomain, "values": [$value]}, "description": ("Created " + $timestamp)}] else . end) else .spec.primary.rr_set_group += [{"metadata":{"name":$name,"namespace":"system","description":("Managed by " + $machine)},"rr_set":[{"ttl":60,"txt_record":{"name":$subdomain,"values":[$value]},"description":("Created " + $timestamp)}]}] end')
        
        if [ $? -ne 0 ]; then
            _err "jq processing failed"
            return 1
        fi
    else
        # Remove TXT record from zone using jq
        _debug "Removing TXT record"
        
        # Remove the specific TXT record and clean up empty RRSets
        export _zone_data=$(printf "%s" "$zone_config" | jq --arg name "$rrset_name" --arg subdomain "$subdomain" --arg value "$txt_value" '.spec.primary.rr_set_group |= map(if .metadata.name == $name then .rr_set |= map(select(.txt_record.name != $subdomain or (.txt_record.values | index($value) | not))) else . end) | .spec.primary.rr_set_group |= map(select(.rr_set | length > 0))')
        
        if [ $? -ne 0 ]; then
            _err "jq removal processing failed"
            return 1
        fi
    fi
    
    if [ -z "$_zone_data" ]; then
        return 1
    fi
    
    return 0
}

# Modify zone using basic text processing (fallback method)
_modify_zone_with_text() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    rrset_name="$4"
    action="$5"
    
    # This is a simplified fallback - for production use, jq is recommended
    _info "Using basic text processing. Install jq for better zone management."
    
    if [ "$action" = "add" ]; then
        # Get current UTC timestamp and device name
        timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
        machine_id=$(_get_machine_id 2>/dev/null)
        
        # Simple approach: append to rr_set_group if it exists
        if _contains "$zone_config" '"rr_set_group"'; then
            # Zone has rr_set_group, append new RRSet
            _zone_data=$(printf "%s" "$zone_config" | sed 's/"rr_set_group": \[/"rr_set_group": [{"metadata":{"name":"'"$rrset_name"'","namespace":"system","description":"Managed by '"$machine_id"'"},"rr_set":[{"ttl":60,"txt_record":{"name":"'"$subdomain"'","values":["'"$txt_value"'"]},"description":"Created '"$timestamp"'"}],/')
        else
            # Zone doesn't have rr_set_group, create it
            _zone_data=$(printf "%s" "$zone_config" | sed 's/"primary": {/"primary": {"rr_set_group": [{"metadata":{"name":"'"$rrset_name"'","namespace":"system","description":"Managed by '"$machine_id"'"},"rr_set":[{"ttl":60,"txt_record":{"name":"'"$subdomain"'","values":["'"$txt_value"'"]},"description":"Created '"$timestamp"'"}],/')
        fi
    else
        # Remove TXT record from zone using basic text processing
        _debug "Removing TXT record (text processing)"
        
        # Simplified removal approach
        _zone_data=$(printf "%s" "$zone_config" | sed '
            # Find the RRSet with matching name and remove the TXT record
            /"metadata":\s*{\s*"name":\s*"'"$rrset_name"'"/,/}/ {
                # Within this RRSet, remove the TXT record with matching subdomain and value
                /"txt_record":\s*{\s*"name":\s*"'"$subdomain"'"/,/}/ {
                    # Skip this TXT record (remove it)
                    d
                }
            }
        ')
        
        # Clean up any empty RRSets
        _zone_data=$(printf "%s" "$_zone_data" | sed '
            # Remove empty RRSets (metadata followed immediately by closing brace)
            /"metadata":\s*{[^}]*}\s*}/d
        ')
        
        export _zone_data="$_zone_data"
        _debug "TXT record removal completed"
    fi
    
    if [ -z "$_zone_data" ]; then
        return 1
    fi
    
    return 0
}

# Note: This plugin uses _readaccountconf_mutable which is an acme.sh internal function

# Validate credentials early and set up cached certificate pair
_validate_credentials() {
    # Global variables for cached certificate data
    export _F5XC_CACHED_CERT_FILE=""
    export _F5XC_CACHED_CERT_PASSWORD=""
    export _F5XC_AUTH_METHOD=""
    export _F5XC_CACHED_DOMAINS=""
    
    _debug "Validating F5 XC credentials"
    
    # Check required environment variables
    if [ -z "$F5XC_TENANT" ]; then
        _err "F5XC_TENANT is required"
        return 1
    fi
    
    # Check if we have either certificates or API token
    if [ -z "$F5XC_CLIENT_CERT" ] && [ -z "$F5XC_API_TOKEN" ]; then
        _err "Either F5XC_CLIENT_CERT or F5XC_API_TOKEN is required"
        return 1
    fi
    
    # Validate client certificate if provided
    if [ -n "$F5XC_CLIENT_CERT" ]; then
        _debug "Validating client certificate: $F5XC_CLIENT_CERT"
        
        # Check if certificate file exists and is readable
        if [ ! -f "$F5XC_CLIENT_CERT" ]; then
            _err "Client certificate file not found: $F5XC_CLIENT_CERT"
            return 1
        fi
        
        if [ ! -r "$F5XC_CLIENT_CERT" ]; then
            _err "Client certificate file not readable: $F5XC_CLIENT_CERT"
            return 1
        fi
        
        # Check if certificate password is provided
        if [ -z "$F5XC_CERT_PASSWORD" ]; then
            _err "Certificate password (F5XC_CERT_PASSWORD) is required for P12 certificates"
            return 1
        fi
        
        # Test certificate conversion to ensure it's valid
        if [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.p12}" ] || [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.pfx}" ]; then
            _debug "Testing P12 certificate conversion"
            test_pem=$(_convert_p12_to_pem "$F5XC_CLIENT_CERT" "$F5XC_CERT_PASSWORD")
            if [ $? -ne 0 ]; then
                _err "Failed to convert P12 certificate - invalid certificate or password"
                return 1
            fi
            # Clean up test file
            rm -f "$test_pem"
            _debug "P12 certificate validation successful"
        fi
        
        # Set up cached certificate data
        _F5XC_CACHED_CERT_FILE="$F5XC_CLIENT_CERT"
        _F5XC_CACHED_CERT_PASSWORD="$F5XC_CERT_PASSWORD"
        _F5XC_AUTH_METHOD="certificate"
        
        _debug "Certificate credentials validated and cached successfully"
    elif [ -n "$F5XC_API_TOKEN" ]; then
        # Fall back to API token authentication
        _debug "Using API token authentication"
        _F5XC_AUTH_METHOD="api_token"
    fi
    
    # Now test the credentials by making an initial API call to cache available domains
    _debug "Testing credentials with initial API call to cache available domains"
    
    if ! _f5xc_cache_domains; then
        _err "Failed to validate credentials - API call failed"
        return 1
    fi
    
    _debug "Credentials validated successfully and domains cached"
    return 0
}



# Cache available domains from F5 XC
_f5xc_cache_domains() {
    _debug "Fetching and caching available domains from F5 XC using dns_domains endpoint"
    
    # Make API call to get all DNS domains (simpler endpoint)
    if ! _f5xc_rest "GET" "/api/config/namespaces/system/dns_domains"; then
        _err "Failed to fetch DNS domains for caching"
        return 1
    fi
    
    # Debug: Show the raw API response to understand the structure

    
    # Extract domain names from the response and cache them
    if command -v jq >/dev/null 2>&1; then
        _debug "Getting list of domains"
        

        
        # Try to extract domains from various possible paths
        domains_path1=$(printf "%s" "$_F5XC_LAST_RESPONSE" | jq -r '.items[]?.name // empty' 2>/dev/null | tr '\n' ' ')
        domains_path2=$(printf "%s" "$_F5XC_LAST_RESPONSE" | jq -r '.items[]?.spec.primary.default_dns_zone_name // empty' 2>/dev/null | tr '\n' ' ')
        domains_path3=$(printf "%s" "$_F5XC_LAST_RESPONSE" | jq -r '.items[]?.spec.primary.dns_zone_name // empty' 2>/dev/null | tr '\n' ' ')
        domains_path4=$(printf "%s" "$_F5XC_LAST_RESPONSE" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null | tr '\n' ' ')
        domains_path5=$(printf "%s" "$_F5XC_LAST_RESPONSE" | jq -r '.items[]?.spec.dns_zone_name // empty' 2>/dev/null | tr '\n' ' ')
        
        # Use the first non-empty result (prioritize the correct path)
        if [ -n "$domains_path1" ]; then
            _F5XC_CACHED_DOMAINS="$domains_path1"
        elif [ -n "$domains_path2" ]; then
            _F5XC_CACHED_DOMAINS="$domains_path2"
        elif [ -n "$domains_path3" ]; then
            _F5XC_CACHED_DOMAINS="$domains_path3"
        elif [ -n "$domains_path4" ]; then
            _F5XC_CACHED_DOMAINS="$domains_path4"
        elif [ -n "$domains_path5" ]; then
            _F5XC_CACHED_DOMAINS="$domains_path5"
        fi
        
        if [ $? -ne 0 ]; then
            _err "Failed to parse DNS domains response with jq"
            return 1
        fi
    else
        _debug "Using text processing (jq not available)"
        
        # Fallback to text processing if jq is not available
        _F5XC_CACHED_DOMAINS=$(printf "%s" "$_F5XC_LAST_RESPONSE" | grep -o '"default_dns_zone_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"default_dns_zone_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/g' | tr '\n' ' ')
    fi
    
    # Clean up the cached domains (remove extra spaces and empty entries)
    _F5XC_CACHED_DOMAINS=$(echo "$_F5XC_CACHED_DOMAINS" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    
    if [ -z "$_F5XC_CACHED_DOMAINS" ]; then
        _warn "No domains found in F5 XC - this might indicate a configuration issue"
        _debug "This could mean: 1) No DNS domains configured, 2) Different JSON structure, 3) Empty tenant"
        # Don't fail here as empty domains might be valid for new tenants
    else
        _debug "Successfully cached domains: $_F5XC_CACHED_DOMAINS"
    fi
    
    return 0
}

# F5 XC REST API helper function
_f5xc_rest() {
    method="$1"
    path="$2"
    data="$3"
    
    # Construct full URL directly from tenant
    full_url="https://${F5XC_TENANT}.console.ves.volterra.io${path}"
    

    
    _debug "API call: $method $path"
    
    # Check authentication method: Client certificates (preferred) or API token (fallback)
    if [ "$_F5XC_AUTH_METHOD" = "certificate" ]; then
        # Use cached client certificate authentication
        _debug "Using cached client certificate authentication"
        
        # Convert P12 to PEM for better compatibility with modern OpenSSL
        cert_file="$_F5XC_CACHED_CERT_FILE"
        if [ "$_F5XC_CACHED_CERT_FILE" != "${_F5XC_CACHED_CERT_FILE%.p12}" ] || [ "$_F5XC_CACHED_CERT_FILE" != "${_F5XC_CACHED_CERT_FILE%.pfx}" ]; then
            _debug "Converting P12 certificate to PEM format"
            cert_file=$(_convert_p12_to_pem "$_F5XC_CACHED_CERT_FILE" "$_F5XC_CACHED_CERT_PASSWORD")
            if [ $? -ne 0 ]; then
                _err "Failed to convert P12 certificate to PEM format"
                return 1
            fi
        fi
        
        # Build curl command with certificate
        curl_cmd="curl -sk -X $method"
        
        # Add certificate (PEM format)
        curl_cmd="$curl_cmd --cert '$cert_file'"
        _debug "Using PEM certificate"
        

        
        # Add headers and URL
        curl_cmd="$curl_cmd -H '$_H2' -H '$_H3' '$full_url'"
        
        # Add data for POST/PUT requests
        if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
            _debug "Request data included"
            curl_cmd="$curl_cmd -d '$data'"
        fi
        
        _debug "Executing curl command"
        response=$(eval "$curl_cmd")
        
        # Clean up temporary PEM file if we created one
        if [ "$cert_file" != "$F5XC_CLIENT_CERT" ]; then
            rm -f "$cert_file"
            _debug "Cleaned up temporary PEM file"
        fi
        
    elif [ "$_F5XC_AUTH_METHOD" = "api_token" ]; then
        # Use cached API token authentication with built-in functions
        _debug "Using cached API token authentication with built-in functions"
        
        # Set headers for built-in functions (export is required for built-in functions)
        export _H1="Authorization: APIToken $F5XC_API_TOKEN"
        export _H2="Content-Type: application/json"
        export _H3="Accept: application/json"
        
        if [ "$method" = "POST" ]; then
            _debug "POST request with data using built-in _post function"
            response=$(_post "$data" "$full_url" "" "POST" "application/json")
        elif [ "$method" = "PUT" ]; then
            _debug "PUT request with data using built-in _post function"
            response=$(_post "$data" "$full_url" "" "PUT" "application/json")
        elif [ "$method" = "DELETE" ]; then
            _debug "DELETE request using built-in _post function"
            response=$(_post "" "$full_url" "" "DELETE")
        else
            _debug "GET request using built-in _get function"
            response=$(_get "$full_url")
        fi
    else
        _err "No valid authentication method found - credentials not properly validated"
        return 1
    fi
    
    if [ "$?" != "0" ]; then
        _err "curl error for $method $full_url"
        return 1
    fi
    
    _debug "API response received"
    
    # Check for F5 XC API errors in the response
    if echo "$response" | grep -q '"code":[0-9]'; then
        # Extract error code and message
        error_code=$(echo "$response" | jq -r '.code' 2>/dev/null || echo "unknown")
        error_message=$(echo "$response" | jq -r '.message' 2>/dev/null || echo "unknown error")
        
        # Check if this is an error response (code != 0)
        if [ "$error_code" != "0" ] && [ "$error_code" != "null" ] && [ "$error_code" != "unknown" ]; then
            _err "F5 XC API error (code: $error_code): $error_message"
            
            # Check for specific error types
            if echo "$response" | grep -q "duplicate.*TXT"; then
                _err "Duplicate TXT record detected - this is not allowed in F5 XC"
                return 2  # Special exit code for duplicate records
            fi
            
            return 1  # General API error
        fi
    fi
    
    # Store response in a global variable so calling functions can access it
    export _F5XC_LAST_RESPONSE="$response"
    
    return 0
}



# Get machine identifier for RRSet naming
_get_machine_id() {
    # Priority order:
    # 1. Configurable F5XC_RRSET_IDENTIFIER from config
    # 2. Hostname (sanitized)
    # 3. Fallback combination
    
    # First priority: Check for configurable F5XC_RRSET_IDENTIFIER
    if [ -n "$F5XC_RRSET_IDENTIFIER" ]; then
        _sanitize_name "$F5XC_RRSET_IDENTIFIER"
        return 0
    fi
    
    # Second priority: Try to get hostname
    if command -v hostname >/dev/null 2>&1; then
        hostname=$(hostname 2>/dev/null)
        if [ -n "$hostname" ] && [ "$hostname" != "localhost" ]; then
            _sanitize_name "$hostname"
            return 0
        fi
    fi
    
    # Fallback to a combination of hostname and user
    username=${USER:-unknown}
    hostname=${hostname:-unknown}
    combined="${username}-${hostname}"
    _sanitize_name "$combined"
}

# Sanitize name to follow F5 XC naming rules
_sanitize_name() {
    name="$1"
    
    # Convert to lowercase and replace invalid chars with hyphens
    sanitized=$(printf "%s" "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    # Remove multiple consecutive hyphens
    sanitized=$(printf "%s" "$sanitized" | sed 's/--*/-/g')
    
    # Ensure it starts with a letter
    if [ -n "$sanitized" ] && ! printf "%s" "$sanitized" | grep -q '^[a-z]'; then
        sanitized="m-${sanitized}"
    fi
    
    # Ensure it ends with alphanumeric
    if [ -n "$sanitized" ] && ! printf "%s" "$sanitized" | grep -q '[a-z0-9]$'; then
        sanitized=$(printf "%s" "$sanitized" | sed 's/-*$//')
    fi
    
    # If empty after sanitization, use fallback
    if [ -z "$sanitized" ]; then
        sanitized="unknown-machine"
    fi
    
    printf "%s" "$sanitized"
}

# Utility functions
_contains() {
    _str="$1"
    _sub="$2"
    echo "$_str" | grep -- "$_sub" >/dev/null 2>&1
}

# Convert P12 certificate to PEM format for compatibility with modern OpenSSL
_convert_p12_to_pem() {
    p12_file="$1"
    password="$2"
    temp_pem="/tmp/f5xc_cert_$$.pem"
    
    _debug "Converting P12 to PEM format"
    
    # Use OpenSSL with legacy algorithms to extract P12
    if OPENSSL_CONF=/dev/null openssl pkcs12 -in "$p12_file" -out "$temp_pem" -nodes -passin "pass:$password" -legacy 2>/dev/null; then
        _debug "P12 to PEM conversion successful"
        printf "%s" "$temp_pem"
        return 0
    else
        _err "Failed to convert P12 certificate to PEM format"
        rm -f "$temp_pem" 2>/dev/null
        return 1
    fi
}
