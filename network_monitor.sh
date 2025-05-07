#!/usr/bin/env bash

# Network Device Health Checker
# A simple network monitoring tool that checks device health and sends Telegram alerts

#load .env
source "$(dirname "$0")/.env"

#for terminating easily with ctrl+c
cleanup() {

    echo "Caught Ctrl+C, Shutting Down..."
    exit 0
}

trap 'cleanup; exit 0' SIGINT SIGTERM

# ANSI color codes for logging
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
RESET='\e[0m'

# Logging functions
log_info() { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
log_ok() { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
log_err() { printf "${RED}[ERR ]${RESET} %s\n" "$*" >&2; }

# Configuration
DEVICES_FILE="devices.txt"
LOG_FILE="Logs/network_monitor_$(date '+%Y-%m-%d %H:%M:%S').log"

# function for creating logs directory if it doesn't exist
ensure_logdir_logfile() {
    if [ -d Logs ]; then
        return 0
    else
        mkdir Logs
    fi

touch "$LOG_FILE"
}

# Function for appending date+time of run into the logfile 
log_to_file() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
}

# Function to check if a device is reachable with ping
check_ping() {
    local ip=$1
    local count=3
    local timeout=5
    
    log_info "Pinging $ip"
    log_to_file "Pinging $ip"
    
    if ping -c $count -W $timeout "$ip" > /dev/null 2>&1; then
        # get average response time
        local avg_time=$(ping -c $count -W $timeout "$ip" | grep "avg" | awk -F '/' '{print $5}')
        log_ok "Ping successful for $ip (avg: ${avg_time}ms)"
        log_to_file "PING OK: $ip (avg: ${avg_time}ms)"
        return 0
    else
        log_err "Ping failed for $ip"
        log_to_file "PING FAILED: $ip"
        return 1
    fi
}

# Function to check if a port is open
check_port() {
    local ip=$1
    local port=$2
    local timeout=5
    
    log_info "Checking port $port on $ip"
    log_to_file "Checking port $port on $ip"
    #bash trick for opening a new shell to attempt a tcp connection to the device's IP and port 
    if timeout $timeout bash -c ">/dev/tcp/$ip/$port" 2>/dev/null; then
        log_ok "Port $port is open on $ip"
        log_to_file "PORT OK: $ip:$port"
        return 0
    else
        log_err "Port $port is closed on $ip"
        log_to_file "PORT CLOSED: $ip:$port"
        return 1
    fi
}

# Function to check HTTP status
check_http() {
    local url=$1
    local timeout=10
    
    log_info "Checking HTTP status for $url"
    log_to_file "Checking HTTP status for $url"
    if ! [[ $url =~ ^https?:// ]]; then
        url="http://$url"
    fi

    #sends a get request to pull the website, throw it into /dev/null and filter out the http status code
    local response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout $timeout "$url")

    if [ "$response" = "200" ]; then
        log_ok "HTTP check successful for $url (status: $response)"
        log_to_file "HTTP OK: $url (status: $response)"
        return 0
    else
        log_err "HTTP check failed for $url (status: $response)"
        log_to_file "HTTP FAILED: $url (status: $response)"
        return 1
    fi
}

# Function to send telegram alert
send_telegram_alert() {
    local message="<u><b>Network Monitoring Alert</b></u>%0A%0A$1"
    local response_text

    response_text=$(curl -s -X POST https://api.telegram.org/bot$TOKEN/sendMessage \
    	-d "chat_id=$CHAT_ID" \
        -d "text=$message" \
    	-d "parse_mode=HTML")

if grep -q '"ok":true' <<< "$response_text"; then
    log_to_file "Telegram Alert Sent Successfuly!" 
    log_ok "Telegram Alert Sent Successfuly!"
else
    log_to_file "Telegram Error Response: $response_text"
    log_err "Telegram Alert Failed to Send!"
    echo "Telegram Error Response:"
    echo
    echo "$response_text"
fi
}
# Function to check a device
check_device() {
    local line=$1
    local issues=()
    
    # Parse the line from devices.txt, format: name,ip,ports,http_urls
    IFS=',' read -r name ip ports http_urls <<< "$line"
    
    if [ -z "$ip" ]; then
        log_err "No IP address specified for device: $name"
        return 1
    fi
    
    log_info "Checking device: $name ($ip)"
    log_to_file "Checking device: $name ($ip)"
    
    # Check ping
    if ! check_ping "$ip"; then
        issues+=("Ping failed")
    fi
    
    # Check ports if specified, the for loop check if there are multiple ports specified that are seperated by ;
    if [ ! -z "$ports" ]; then
        for port in ${ports//;/ }; do
            if ! check_port "$ip" "$port"; then
                issues+=("Port $port closed")
            fi
        done
    fi
    
    # Check HTTP endpoints if specified, the for loop check if there are multiple endpoints specified that are seperated by ;
    if [ ! -z "$http_urls" ]; then
        for url in ${http_urls//;/ }; do
            if ! check_http "$url"; then
                issues+=("HTTP check failed for $url")
            fi
        done
    fi
    
    # Send alert if there are issues
    if [ ${#issues[@]} -gt 0 ]; then
        local alert_message="Device: $name ($ip)%0A%0A<u><b>Issues detected</b></u>:%0A"
        for issue in "${issues[@]}"; do
            alert_message+="-$issue%0A"
        done
        alert_message+="%0ATime: $(date '+%Y-%m-%d %H:%M:%S')"
        
        send_telegram_alert "$alert_message"
    fi
    
    return ${#issues[@]}
}

# Main function
main() {
    ensure_logdir_logfile
    log_info "Starting network monitoring"
    log_to_file "Starting network monitoring"
    
    # Check if devices file exists
    if [ ! -f "$DEVICES_FILE" ]; then
        log_err "Devices file not found: $DEVICES_FILE"
        exit 1
    fi
        
    # Check each device
    local total_devices=0
    local failed_devices=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^#.*$ ]] && continue
        
        ((total_devices++))
        if ! check_device "$line"; then
            ((failed_devices++))
        fi
    done < "$DEVICES_FILE"
    
    #Logging a successfull run 
    log_info "Monitoring completed. Checked $total_devices devices, $failed_devices had issues."
    log_to_file "Monitoring completed. Checked $total_devices devices, $failed_devices had issues."
}

# Run main function
main 
