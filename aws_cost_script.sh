#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values and constants
DAYS=8
CACHE_DIR="$HOME/.aws_cost_analysis_cache"
CACHE_EXPIRY=3600  # 1 hour in seconds
TEMP_FILE=$(mktemp)
ACCOUNT_WIDTH=40
AMOUNT_WIDTH=13    # Total width for both dates and amounts
trap 'rm -f $TEMP_FILE' EXIT

# Function to show usage - must be first to handle -h/--help immediately
show_help() {
    cat << EOF
AWS Cost Analysis Script

Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --days DAYS    Number of days to analyze (default: 8)
  -h, --help        Show this help message
  --no-color        Disable color output
  --no-cache        Disable account name caching

Examples:
  $(basename "$0")              # Analyze last 8 days
  $(basename "$0") -d 30        # Analyze last 30 days
  $(basename "$0") --no-color   # Disable color output
  $(basename "$0") --no-cache   # Disable caching

Note: All amounts are in USD
EOF
    exit 0
}

# Handle help flags immediately
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

# Function to check requirements
check_requirements() {
    for cmd in aws jq bc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}Error: $cmd is required but not installed.${NC}" >&2
            exit 1
        fi
    done

    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo -e "${RED}Error: AWS CLI is not properly configured${NC}" >&2
        exit 1
    fi
}

# Initialize cache directory
init_cache() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || {
            echo -e "${RED}Warning: Could not create cache directory${NC}" >&2
            return 1
        }
    fi
    chmod 700 "$CACHE_DIR" 2>/dev/null
}

# Function to format numbers consistently with proper alignment and trend indicator
format_amount() {
    local amount=$1
    local prev_amount=$2

    if [[ $amount =~ ^[0-9]*\.?[0-9]*$ ]] && [ $(echo "$amount > 0" | bc -l) -eq 1 ]; then
        amount=$(echo "$amount" | tr -d '$,' | bc -l)
        local formatted_num=$(printf "%11.2f" "$amount")

        if [ -n "$prev_amount" ] && [ "$prev_amount" != "0" ]; then
            if (( $(echo "$amount > $prev_amount" | bc -l) )); then
                formatted_num="${formatted_num}↑"
            elif (( $(echo "$amount < $prev_amount" | bc -l) )); then
                formatted_num="${formatted_num}↓"
            else
                formatted_num="${formatted_num} "
            fi
        else
            formatted_num="${formatted_num} "
        fi
        printf "%${AMOUNT_WIDTH}s" "$formatted_num"
    else
        printf "%${AMOUNT_WIDTH}s" "-"
    fi
}

# Function to get color based on cost change
get_color_code() {
    local prev_amount=$1
    local curr_amount=$2

    if [ "$prev_amount" = "0" ] || [ -z "$prev_amount" ]; then
        echo -n "$NC"
        return
    fi

    prev_amount=$(echo "$prev_amount" | tr -d '$,')
    curr_amount=$(echo "$curr_amount" | tr -d '$,')

    local change=$(bc <<< "scale=2; $curr_amount - $prev_amount")
    local abs_change=$(bc <<< "scale=2; if($change < 0) -1 * $change else $change")

    if [ "$prev_amount" != "0" ]; then
        local pct_change=$(bc <<< "scale=2; ($change / $prev_amount) * 100")
        local abs_pct_change=$(bc <<< "scale=2; if($pct_change < 0) -1 * $pct_change else $pct_change")

        if (( $(bc <<< "$abs_change >= 200") )) ||
           (( $(bc <<< "$abs_pct_change >= 100") )); then
            echo -n "$RED"
        elif (( $(bc <<< "$abs_change >= 50") )) ||
             (( $(bc <<< "$abs_pct_change >= 25") )); then
            echo -n "$YELLOW"
        else
            echo -n "$GREEN"
        fi
    else
        echo -n "$NC"
    fi
}

# Get account name with caching
get_account_name() {
    local account=$1
    local cache_file="$CACHE_DIR/account_${account}"

    if [ "$USE_CACHE" = true ] && [ -f "$cache_file" ]; then
        local cache_time
        cache_time=$(stat -c %Y "$cache_file" 2>/dev/null)
        current_time=$(date +%s)

        if [ $((current_time - cache_time)) -lt $CACHE_EXPIRY ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    local account_name
    account_name=$(aws organizations list-accounts --query "Accounts[?Id=='${account}'].[Name]" --output text 2>/dev/null || echo "$account")

    if [ "$USE_CACHE" = true ]; then
        echo "$account_name" > "$cache_file"
    fi

    echo "$account_name"
}

# Main function to process and display costs
process_costs() {
    local end_date=$(date +%Y-%m-%d)
    local start_date=$(date -d "$end_date - $DAYS days" +%Y-%m-%d)

    echo -e "\nAWS Cost Analysis Report"
    echo -e "Period: $start_date to $end_date"
    echo -e "All amounts in USD\n"

    if ! aws ce get-cost-and-usage \
        --time-period Start=${start_date},End=${end_date} \
        --granularity DAILY \
        --metrics "UnblendedCost" \
        --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
        | jq '.' > "$TEMP_FILE"; then
        echo -e "${RED}Failed to fetch cost data from AWS${NC}" >&2
        exit 1
    fi

    local dates=$(jq -r '.ResultsByTime[].TimePeriod.Start' "$TEMP_FILE" | sort -u)
    local accounts=$(jq -r '.ResultsByTime[].Groups[].Keys[0]' "$TEMP_FILE" | sort -u | while read -r account; do
        get_account_name "$account" | sed "s/$/\t$account/"
    done | sort | cut -f2)

    printf "%-${ACCOUNT_WIDTH}s" "Account"
    for date in $dates; do
        printf "%-${AMOUNT_WIDTH}s" "$(date -d "$date" +%m-%d)"
    done
    echo

    printf '%*s\n' $((ACCOUNT_WIDTH + (AMOUNT_WIDTH * $(echo "$dates" | wc -l)))) '' | tr ' ' '-'

    declare -A daily_totals

    while read -r account; do
        local account_name=$(get_account_name "$account")
        printf "%-${ACCOUNT_WIDTH}s" "${account_name:0:$((ACCOUNT_WIDTH-1))}"

        local prev_amount=0
        for date in $dates; do
            local amount=$(jq -r --arg date "$date" --arg account "$account" \
                '.ResultsByTime[] | select(.TimePeriod.Start == $date) |
                .Groups[] | select(.Keys[0] == $account) |
                .Metrics.UnblendedCost.Amount' "$TEMP_FILE" | tr -d '"')

            amount=${amount:-0}
            daily_totals[$date]=$(bc <<< "scale=2; ${daily_totals[$date]:-0} + $amount")

            local color=$(get_color_code "$prev_amount" "$amount")
            printf "${color}%${AMOUNT_WIDTH}s${NC}" "$(format_amount "$amount" "$prev_amount")"

            prev_amount=$amount
        done
        echo
    done <<< "$accounts"

    printf '%*s\n' $((ACCOUNT_WIDTH + (AMOUNT_WIDTH * $(echo "$dates" | wc -l)))) '' | tr ' ' '-'

    printf "${CYAN}%-${ACCOUNT_WIDTH}s${NC}" "TOTAL"
    local prev_total=0
    for date in $dates; do
        local total=${daily_totals[$date]:-0}
        local color=$(get_color_code "$prev_total" "$total")
        printf "${color}%${AMOUNT_WIDTH}s${NC}" "$(format_amount "$total" "$prev_total")"
        prev_total=$total
    done
    echo
}

USE_CACHE=true
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--days)
            if [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] && [ "$2" -le 365 ]; then
                DAYS=$2
                shift 2
            else
                echo -e "${RED}Error: Days must be between 1 and 365${NC}" >&2
                exit 1
            fi
            ;;
        --no-color)
            RED=''
            GREEN=''
            YELLOW=''
            CYAN=''
            NC=''
            shift
            ;;
        --no-cache)
            USE_CACHE=false
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            show_help
            ;;
    esac
done

check_requirements
[ "$USE_CACHE" = true ] && init_cache
process_costs
