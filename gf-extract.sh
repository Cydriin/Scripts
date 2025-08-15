#!/bin/bash

# Simple gf pattern runner with organized output
TARGET="$1"
OUTPUT_DIR="gf-output"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Usage check
if [[ -z "$TARGET" ]]; then
    echo -e "${RED}Usage: $0 <target_url_or_file>${NC}"
    echo -e "${YELLOW}Example: $0 https://example.com${NC}"
    echo -e "${YELLOW}Example: $0 /path/to/urls.txt${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Starting gf pattern analysis on: ${GREEN}${TARGET}${NC}"

# Create output directory
mkdir -p "$OUTPUT_DIR"
echo -e "${YELLOW}[*] Created output directory: ${GREEN}$OUTPUT_DIR${NC}"

# Get all available gf patterns
PATTERNS=$(gf -list 2>/dev/null | grep -v "^$")

if [[ -z "$PATTERNS" ]]; then
    echo -e "${RED}[!] No gf patterns found. Make sure gf is installed and patterns are available.${NC}"
    exit 1
fi

# Convert patterns to array
mapfile -t PATTERN_ARR <<< "$PATTERNS"
TOTAL_PATTERNS=${#PATTERN_ARR[@]}

echo -e "${YELLOW}[*] Found ${WHITE}${TOTAL_PATTERNS}${YELLOW} gf patterns${NC}"

# Progress bar function
progress_bar() {
    local current="$1" total="$2" width=40
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar=""
    for _ in $(seq 1 $filled); do bar+="#"; done
    for _ in $(seq 1 $empty); do bar+="-"; done
    echo -n "$bar"
}

# Run each pattern
counter=0
for pattern in "${PATTERN_ARR[@]}"; do
    counter=$((counter + 1))
    output_file="${OUTPUT_DIR}/${pattern}.txt"
    
    # Run gf with the pattern, sort and remove duplicates
    gf "$pattern" "$TARGET" 2>/dev/null | sort -u > "$output_file"
    
    # Check if file has content, remove if empty
    if [[ ! -s "$output_file" ]]; then
        rm -f "$output_file"
        status="${RED}empty${NC}"
    else
        line_count=$(wc -l < "$output_file")
        status="${GREEN}${line_count} matches${NC}"
    fi
    
    # Progress display
    pct=$(( counter * 100 / TOTAL_PATTERNS ))
    bar=$(progress_bar "$counter" "$TOTAL_PATTERNS")
    echo -ne "\r${WHITE}${counter}/${TOTAL_PATTERNS}${NC} (${WHITE}${pct}%${NC}) [${bar}] ${CYAN}${pattern}${NC} - ${status}"
done

echo -e "\n"

# Summary
echo -e "${WHITE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}[✓] Pattern analysis complete!${NC}"
echo -e "${WHITE}═══════════════════════════════════════════════════════${NC}"

# Show results summary
echo -e "\n${YELLOW}Results summary:${NC}"
results_found=0
total_matches=0

for pattern in "${PATTERN_ARR[@]}"; do
    output_file="${OUTPUT_DIR}/${pattern}.txt"
    if [[ -f "$output_file" && -s "$output_file" ]]; then
        line_count=$(wc -l < "$output_file")
        results_found=$((results_found + 1))
        total_matches=$((total_matches + line_count))
        echo -e "  ${WHITE}•${NC} ${CYAN}${pattern}${NC}: ${WHITE}${line_count}${NC} matches"
    fi
done

echo -e "\n${YELLOW}Total patterns with matches: ${WHITE}${results_found}${NC}"
echo -e "${YELLOW}Total unique matches found: ${WHITE}${total_matches}${NC}"
echo -e "${YELLOW}Output directory: ${GREEN}$(realpath "$OUTPUT_DIR")${NC}"

# Quick access commands
echo -e "\n${YELLOW}Quick commands:${NC}"
echo -e "${CYAN}# View all non-empty results:${NC}"
echo -e "find $OUTPUT_DIR -type f -size +0c -exec basename {} .txt \;"
echo -e "\n${CYAN}# View specific pattern results:${NC}"
echo -e "cat $OUTPUT_DIR/<pattern-name>.txt"
echo -e "\n${CYAN}# Find largest result files:${NC}"
echo -e "find $OUTPUT_DIR -type f -size +0c -exec wc -l {} + | sort -nr"
