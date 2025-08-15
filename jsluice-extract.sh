#!/bin/bash

JS_DIR="."
OUTPUT_DIR="jsluice-output"
WORDLIST_DIR="$OUTPUT_DIR/wordlists"
RAW_DIR="$OUTPUT_DIR/raw"
FORCE_REEXTRACT=0
USE_COLOR=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-color|--no-colour) USE_COLOR=0; shift ;;
    --force-reextract) FORCE_REEXTRACT=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--no-color] [--force-reextract] [JS_DIR]"
      echo "  --no-color         Disable ANSI colors (CI-friendly)."
      echo "  --force-reextract  Recreate missing AND existing raw files."
      echo "  JS_DIR             Root directory to scan (default: current dir)."
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      JS_DIR="$1"; shift ;;
  esac
done

# -------------------------
# Colors
# -------------------------
if [[ "$USE_COLOR" -eq 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  WHITE='\033[1;37m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; NC=''
fi

FULL_OUTPUT_PATH="$(realpath "$OUTPUT_DIR" 2>/dev/null || echo "$OUTPUT_DIR")"

echo -e "${YELLOW}[*] Starting jsluice analysis on: ${GREEN}${JS_DIR}/${NC}"

# -------------------------
# Dirs
# -------------------------
mkdir -p "$OUTPUT_DIR" "$WORDLIST_DIR" "$RAW_DIR"

# -------------------------
# Discover sources
# -------------------------
JS_FILES="$(find "$JS_DIR" -type f \( -name "*.js" -o -name "*.mjs" -o -name "*.cjs" -o -name "*.ts" -o -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null)"
mapfile -t JS_ARR < <(echo "$JS_FILES" | sed '/^$/d')
JS_COUNT=${#JS_ARR[@]}
echo -e "${YELLOW}[*] Found ${WHITE}${JS_COUNT}${YELLOW} files to analyze${NC}"

# -------------------------
# Helpers
# -------------------------
progress_bar() {
  local current="$1" total="$2" width="${3:-32}"
  [[ "$total" -le 0 ]] && total=1
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""
  for _ in $(seq 1 $filled); do bar+="#"; done
  for _ in $(seq 1 $empty); do bar+="-"; done
  echo -n "$bar"
}

# Emit only lines that look like JSON objects (keeps jq happy)
json_only() {
  awk '/^[[:space:]]*\{/'
}

# -------------------------
# Raw paths
# -------------------------
RAW_URLS="$RAW_DIR/raw-urls.json"
RAW_SECRETS="$RAW_DIR/raw-secrets.json"
RAW_STRINGS="$RAW_DIR/raw-strings.json"
RAW_COMMENTS="$RAW_DIR/raw-comments.json"
RAW_OBJECTS="$RAW_DIR/raw-objects.json"

declare -A RAW_FILES=(
  ["urls"]="$RAW_URLS"
  ["secrets"]="$RAW_SECRETS"
  ["strings"]="$RAW_STRINGS"
  ["comments"]="$RAW_COMMENTS"
  ["objects"]="$RAW_OBJECTS"
)

# -------------------------
# Extraction (per-file cache)
# -------------------------
extract_raw_component() {
  local label="$1" out_file="$2" jsluice_cmd="$3"

  echo -e "${YELLOW}[*] Extracting raw ${label}...${NC}"
  : > "$out_file"

  local n="${#JS_ARR[@]}"
  if [[ "$n" -eq 0 ]]; then
    echo -e "${RED}[!] No files found to analyze for ${label}.${NC}"
    return 0
  fi

  local i=0
  for src in "${JS_ARR[@]}"; do
    i=$((i+1))

    # Run the specific jsluice subcommand for this component
    eval ${jsluice_cmd//\$\{SRC\}/"\"$src\""} >> "$out_file" 2>/dev/null || true

    local pct=$(( i * 100 / n ))
    local bar
    bar="$(progress_bar "$i" "$n" 32)"
    echo -ne "\r${WHITE}${i}/${n}${NC} (${WHITE}${pct}%${NC}) [${bar}]  ${CYAN}$(basename "$src")${NC}"
  done
  echo
}

echo -e "${YELLOW}[*] Checking raw cache...${NC}"
for key in urls secrets strings comments objects; do
  file="${RAW_FILES[$key]}"
  if [[ "$FORCE_REEXTRACT" -eq 1 || ! -f "$file" ]]; then
    case "$key" in
      urls)     extract_raw_component "URLs"     "$file" 'jsluice urls ${SRC}' ;;
      secrets)  extract_raw_component "secrets"  "$file" 'jsluice secrets ${SRC}' ;;
      strings)  extract_raw_component "strings"  "$file" 'jsluice query -q '"'"'(string) @str'"'"' -f ${SRC}' ;;
      comments) extract_raw_component "comments" "$file" 'jsluice query -q '"'"'(comment) @match'"'"' -f ${SRC}' ;;
      objects)  extract_raw_component "objects"  "$file" 'jsluice query -q '"'"'(object) @match'"'"' ${SRC}' ;;
    esac
  else
    echo -e "${CYAN}[i] Using cached ${key}${NC}"
  fi
done

# -------------------------
# PROCESSING
# -------------------------
echo -e "${YELLOW}[*] Processing URLs...${NC}"
json_only < "$RAW_URLS" \
  | jq -s -r 'map(.url) | unique | sort | .[]' > "$WORDLIST_DIR/urls.txt" || true
json_only < "$RAW_URLS" \
  | jq -s -r 'map(.queryParams // [], .bodyParams // []) | flatten | unique | sort | .[]' > "$WORDLIST_DIR/params.txt" || true
json_only < "$RAW_URLS" \
  | jq -s -r 'group_by(.filename) | map({filename: .[0].filename, urls: (map(.url) | unique | sort)})' > "$OUTPUT_DIR/urls-by-file.json" || true
json_only < "$RAW_URLS" \
  | jq -s -r 'group_by(.type) | map({type: .[0].type, count: length, files: (map(.filename) | unique | sort), urls: (map(.url) | unique | sort)}) | sort_by(.count) | reverse' > "$OUTPUT_DIR/urls-by-type.json" || true


### Strings ###
echo -e "${YELLOW}[*] Processing strings...${NC}"

# 1) Flat wordlist of all unique strings
json_only < "$RAW_STRINGS" \
  | jq -r '.str? // empty' | sed '/^$/d' | sort -u > "$WORDLIST_DIR/strings-all.txt" || true

# 2) Per-file breakdown (ascending by unique_strings_count)
json_only < "$RAW_STRINGS" \
  | jq -s '
    group_by(.filename) 
    | map(
        (map(.str) | unique | sort) as $u
        |
        {
          file: .[0].filename,
          unique_strings_count: ($u | length),
          total_strings: length,
          strings: $u
        }
      )
    | sort_by(.unique_strings_count)
  ' > "$OUTPUT_DIR/strings-unique-to-file.json" || true

# 3) Strings found in multiple files — per-file format (ascending by shared_count)
json_only < "$RAW_STRINGS" \
  | jq -s '
    # Build the set of strings that appear in >1 file (globally shared)
    ( group_by(.str)
      | map(select((map(.filename) | unique | length) > 1))
      | map(.[0].str)
      | unique
    ) as $shared_set

    # Per-file view in requested order
    |
    group_by(.filename)
    | map(
        (map(.str) | unique | sort) as $u
        |
        {
          file: .[0].filename,
          shared_strings_count: (
            $u
            | map(select( . as $s | ($shared_set | index($s)) != null))
            | length
          ),
          total_strings: length,
          shared_strings: (
            $u
            | map(select( . as $s | ($shared_set | index($s)) != null))
            | sort
          )
        }
      )
    | sort_by(.shared_strings_count)
  ' > "$OUTPUT_DIR/strings-shared-in-files.json" || true

# 4) Consolidated “interesting” view
json_only < "$RAW_STRINGS" \
  | jq -s '
    group_by(.filename)
    | map({
        file: (.[0].filename | split("/")[-1]),
        total: length,
        unique: (map(.str) | unique | length),
        interesting: (
          map(.str)
          | unique
          | map(select(test("api|token|key|secret|password|auth|admin|internal|private"; "i")))
          | .[0:20]
        )
      })
    | map(select((.interesting | length) > 0))
    | sort_by(.unique)
  ' > "$OUTPUT_DIR/strings-interesting.json" || true


### Wordlists ###
json_only < "$RAW_STRINGS" | jq -r '.str? // empty' \
  | grep -E '^https?://|^/api/|^/v[0-9]' | sort -u > "$WORDLIST_DIR/endpoints.txt" || true
json_only < "$RAW_STRINGS" | jq -r '.str? // empty' \
  | grep -E '^[a-zA-Z0-9_-]{32,}$' | sort -u > "$WORDLIST_DIR/high-entropy.txt" || true
json_only < "$RAW_STRINGS" | jq -r '.str? // empty' \
  | grep '@' | grep -E '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u > "$WORDLIST_DIR/emails.txt" || true
json_only < "$RAW_STRINGS" | jq -r '.str? // empty' \
  | grep -E '^/' | grep -v '^//' | sort -u > "$WORDLIST_DIR/paths.txt" || true

echo -e "${YELLOW}[*] Processing secrets...${NC}"
json_only < "$RAW_SECRETS" \
  | jq -s 'group_by(.kind) | map({type: .[0].kind, count: length, samples: [.[0:3][]]})' > "$OUTPUT_DIR/secrets-by-type.json" || true
json_only < "$RAW_SECRETS" \
  | jq -s 'map(select(.confidence == "high"))' > "$OUTPUT_DIR/secrets-high-confidence.json" || true
json_only < "$RAW_SECRETS" \
  | jq -r '.value? // empty' | sed '/^$/d' | sort -u > "$WORDLIST_DIR/secret-values.txt" || true

echo -e "${YELLOW}[*] Processing comments...${NC}"
json_only < "$RAW_COMMENTS" \
  | jq -s 'group_by(.filename) | map({filename: .[0].filename, comments: (map(.match) | unique)})' > "$OUTPUT_DIR/comments-by-file.json" || true
json_only < "$RAW_COMMENTS" \
  | jq -r '.match? // empty' | sed '/^$/d' | sort -u > "$WORDLIST_DIR/comments.txt" || true
json_only < "$RAW_COMMENTS" \
  | jq -r '.match? // empty' | grep -iE 'todo|fixme|hack|bug|vulnerable|security|password|token' | sort -u > "$WORDLIST_DIR/comments-interesting.txt" || true

# -------------------------
# Cleanup (silent)
# -------------------------
echo -e "${YELLOW}[*] Cleaning up...${NC}"
for dir in "$OUTPUT_DIR" "$WORDLIST_DIR" "$RAW_DIR"; do
  find "$dir" -type f 2>/dev/null | while read -r f; do
    content="$(tr -d ' \t\r\n' < "$f" 2>/dev/null)"
    if [[ ! -s "$f" || "$content" == "[]" ]]; then
      rm -f "$f"
    fi
  done
done

# -------------------------
# Summary
# -------------------------

echo -e "\n${WHITE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}[✓] Finished!${NC}"
echo -e "${WHITE}═══════════════════════════════════════════════════════${NC}"

# Files analyzed (sorted by size)
echo -e "\n${YELLOW}Files analyzed (sorted by size):${NC}"
echo "$JS_FILES" | while read file; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        lines=$(wc -l < "$file")
        size=$(stat -c%s "$file")
        printf "%012d %s %d\n" "$size" "$filename" "$lines"
    fi
done | sort -rn | while read size filename lines; do
    echo -e "  ${CYAN}$filename${NC} ${WHITE}($(printf "%'d" $lines) lines)${NC}"
done

# Statistics (only show non-zero values)
echo -e "\n${YELLOW}Results:${NC}"

[ -f "$WORDLIST_DIR/urls.txt" ] && URL_COUNT=$(wc -l < "$WORDLIST_DIR/urls.txt") || URL_COUNT=0
[ -f "$WORDLIST_DIR/params.txt" ] && PARAM_COUNT=$(wc -l < "$WORDLIST_DIR/params.txt") || PARAM_COUNT=0
[ -f "$WORDLIST_DIR/endpoints.txt" ] && ENDPOINT_COUNT=$(wc -l < "$WORDLIST_DIR/endpoints.txt") || ENDPOINT_COUNT=0
[ -f "$WORDLIST_DIR/paths.txt" ] && PATH_COUNT=$(wc -l < "$WORDLIST_DIR/paths.txt") || PATH_COUNT=0
[ -f "$WORDLIST_DIR/high-entropy.txt" ] && ENTROPY_COUNT=$(wc -l < "$WORDLIST_DIR/high-entropy.txt") || ENTROPY_COUNT=0
[ -f "$WORDLIST_DIR/comments-interesting.txt" ] && COMMENT_COUNT=$(wc -l < "$WORDLIST_DIR/comments-interesting.txt") || COMMENT_COUNT=0

[ "$URL_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} URLs: ${WHITE}$URL_COUNT${NC}"
[ "$PARAM_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} Parameters: ${WHITE}$PARAM_COUNT${NC}"
[ "$ENDPOINT_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} Endpoints: ${WHITE}$ENDPOINT_COUNT${NC}"
[ "$PATH_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} Paths: ${WHITE}$PATH_COUNT${NC}"
[ "$ENTROPY_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} High-entropy strings: ${WHITE}$ENTROPY_COUNT${NC}"
[ "$COMMENT_COUNT" -gt 0 ] && echo -e "  ${WHITE}•${NC} Interesting comments: ${WHITE}$COMMENT_COUNT${NC}"

# Output directories
echo -e "\n${YELLOW}Output location:${NC}"
echo -e "${GREEN}$FULL_OUTPUT_PATH${NC}"
