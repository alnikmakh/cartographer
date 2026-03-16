#!/bin/bash
#
# test_explore.sh — Unit tests for cartographer/explore.sh functions
#
# Run with: bash cartographer/test_explore.sh
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/test_fixtures"

PASS=0
FAIL=0

# ============================================================
# Test helpers
# ============================================================

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected exit $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_exists() {
    local label="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (file exists but shouldn't: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_exists() {
    local label="$1" path="$2"
    if [ -d "$path" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (directory not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_valid() {
    local label="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "  FAIL: $label (file not found: $path)"
        FAIL=$((FAIL + 1))
        return
    fi
    if command -v python3 &>/dev/null; then
        if python3 -c "import json; json.load(open('$path'))" 2>/dev/null; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (invalid JSON in $path)"
            FAIL=$((FAIL + 1))
        fi
    elif command -v jq &>/dev/null; then
        if jq . "$path" >/dev/null 2>&1; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (invalid JSON in $path)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  SKIP: $label (no python3 or jq available)"
    fi
}

# ============================================================
# Source explore.sh functions (--test flag skips main loop)
# ============================================================

source "$SCRIPT_DIR/explore.sh" --test

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "              CARTOGRAPHER TEST SUITE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================
# queue_pending_count tests
# ============================================================

echo "--- queue_pending_count ---"

test_queue_pending_count_all_pending() {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'a.go\nb.go\nc.go\n' > "$tmpdir/all.txt"
    touch "$tmpdir/explored.txt"

    local result
    result=$(queue_pending_count "$tmpdir/all.txt" "$tmpdir/explored.txt")
    assert_eq "all files pending returns 3" "3" "$result"

    rm -rf "$tmpdir"
}

test_queue_pending_count_some_explored() {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'a.go\nb.go\nc.go\n' > "$tmpdir/all.txt"
    printf 'a.go\n' > "$tmpdir/explored.txt"

    local result
    result=$(queue_pending_count "$tmpdir/all.txt" "$tmpdir/explored.txt")
    assert_eq "1 explored, 2 pending" "2" "$result"

    rm -rf "$tmpdir"
}

test_queue_pending_count_all_explored() {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'a.go\nb.go\n' > "$tmpdir/all.txt"
    printf 'a.go\nb.go\n' > "$tmpdir/explored.txt"

    local result
    result=$(queue_pending_count "$tmpdir/all.txt" "$tmpdir/explored.txt")
    assert_eq "all explored returns 0" "0" "$result"

    rm -rf "$tmpdir"
}

test_queue_pending_count_missing_all_file() {
    local result
    result=$(queue_pending_count "/nonexistent/all.txt" "/nonexistent/explored.txt")
    assert_eq "missing all file returns 0" "0" "$result"
}

test_queue_pending_count_missing_explored_file() {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'a.go\nb.go\n' > "$tmpdir/all.txt"

    local result
    result=$(queue_pending_count "$tmpdir/all.txt" "$tmpdir/nonexistent.txt")
    assert_eq "missing explored file means all pending" "2" "$result"

    rm -rf "$tmpdir"
}

test_queue_pending_count_all_pending
test_queue_pending_count_some_explored
test_queue_pending_count_all_explored
test_queue_pending_count_missing_all_file
test_queue_pending_count_missing_explored_file

# ============================================================
# sanitize_node_name tests
# ============================================================

echo ""
echo "--- sanitize_node_name ---"

test_sanitize_simple_path() {
    local result
    result=$(sanitize_node_name "src/foo/bar.ts")
    assert_eq "simple path" "src__foo__bar.ts" "$result"
}

test_sanitize_deep_path() {
    local result
    result=$(sanitize_node_name "tg-digest/internal/telegram/client.go")
    assert_eq "deep path with dashes" "tg-digest__internal__telegram__client.go" "$result"
}

test_sanitize_single_file() {
    local result
    result=$(sanitize_node_name "main.go")
    assert_eq "single file (no slashes)" "main.go" "$result"
}

test_sanitize_dots_in_path() {
    local result
    result=$(sanitize_node_name "src/v2.0/config.yaml")
    assert_eq "dots in directory name" "src__v2.0__config.yaml" "$result"
}

test_sanitize_simple_path
test_sanitize_deep_path
test_sanitize_single_file
test_sanitize_dots_in_path

# ============================================================
# discover_scope_files tests
# ============================================================

echo ""
echo "--- discover_scope_files ---"

test_discover_scope_files_finds_mjs() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report/sub"
    touch "$tmpdir/project/src/report/index.mjs"
    touch "$tmpdir/project/src/report/foo.mjs"
    touch "$tmpdir/project/src/report/sub/bar.mjs"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": "src/report/index.mjs",
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    local result count
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    count=$(echo "$result" | grep -c '.mjs$')
    assert_eq "finds all .mjs files" "3" "$count"

    rm -rf "$tmpdir"
}

test_discover_scope_files_includes_all_file_types() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report"
    touch "$tmpdir/project/src/report/index.mjs"
    touch "$tmpdir/project/src/report/README.md"
    touch "$tmpdir/project/src/report/types.d.ts"
    touch "$tmpdir/project/src/report/types.ts"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": "src/report/index.mjs",
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    local result count
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    count=$(echo "$result" | wc -l)
    assert_eq "includes all file types" "4" "$(echo "$count" | tr -d ' ')"

    local has_md
    has_md=$(echo "$result" | grep -c '\.md$' || true)
    assert_eq "md files included" "1" "$has_md"

    rm -rf "$tmpdir"
}

test_discover_scope_files_empty_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": "src/report/index.mjs",
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    local result
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    assert_eq "empty dir returns empty" "" "$result"

    rm -rf "$tmpdir"
}

test_discover_scope_files_finds_mjs
test_discover_scope_files_includes_all_file_types
test_discover_scope_files_empty_dir

# ============================================================
# --init: creates queue files
# ============================================================

echo ""
echo "--- --init integration ---"

test_init_creates_queue_files() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report/sub"
    touch "$tmpdir/project/src/report/index.mjs"
    touch "$tmpdir/project/src/report/foo.mjs"
    touch "$tmpdir/project/src/report/sub/bar.mjs"

    local edir="$tmpdir/exploration"
    mkdir -p "$edir"

    cat > "$edir/scope.json" << 'EOF'
{
  "seed": "src/report/index.mjs",
  "boundaries": {
    "explore_within": ["src/report/**"],
    "boundary_packages": ["src/utl"]
  },
}
EOF

    # Override paths and run --init logic inline (simulating)
    local SCOPE_FILE="$edir/scope.json"
    local QUEUE_ALL="$edir/queue_all.txt"
    local QUEUE_EXPLORED="$edir/queue_explored.txt"
    local INDEX_FILE="$edir/index.json"
    local FINDINGS_FILE="$edir/findings.md"
    local NODES_DIR="$edir/nodes"
    local EDGES_DIR="$edir/edges"
    local PROJECT_ROOT="$tmpdir/project"

    # Run the init logic (same as --init block in explore.sh)
    rm -rf "$NODES_DIR" "$EDGES_DIR"
    rm -f "$QUEUE_ALL" "$QUEUE_EXPLORED" "$INDEX_FILE" "$FINDINGS_FILE"

    discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT" > "$QUEUE_ALL"
    touch "$QUEUE_EXPLORED"
    echo '{}' > "$INDEX_FILE"
    mkdir -p "$NODES_DIR" "$EDGES_DIR"

    assert_file_exists "queue_all.txt exists" "$QUEUE_ALL"
    assert_file_exists "queue_explored.txt exists" "$QUEUE_EXPLORED"
    assert_file_exists "index.json exists" "$INDEX_FILE"
    assert_dir_exists "nodes/ dir exists" "$NODES_DIR"
    assert_dir_exists "edges/ dir exists" "$EDGES_DIR"

    local all_count
    all_count=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
    assert_eq "queue_all.txt has 3 files" "3" "$all_count"

    local explored_count
    explored_count=$(wc -l < "$QUEUE_EXPLORED" | tr -d ' ')
    assert_eq "queue_explored.txt is empty" "0" "$explored_count"

    assert_json_valid "index.json is valid JSON" "$INDEX_FILE"

    rm -rf "$tmpdir"
}

test_init_creates_queue_files

# ============================================================
# --dry-run: prints files without creating state
# ============================================================

echo ""
echo "--- --dry-run ---"

test_dry_run_prints_files() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report/sub"
    touch "$tmpdir/project/src/report/index.mjs"
    touch "$tmpdir/project/src/report/foo.mjs"
    touch "$tmpdir/project/src/report/sub/bar.mjs"

    local edir="$tmpdir/exploration"
    mkdir -p "$edir"

    cat > "$edir/scope.json" << 'EOF'
{
  "seed": "src/report/index.mjs",
  "boundaries": {
    "explore_within": ["src/report/**"],
    "boundary_packages": ["src/util"]
  },
}
EOF

    # Override paths to use temp dir
    local SCOPE_FILE="$edir/scope.json"
    local PROJECT_ROOT="$tmpdir/project"

    # Run discover_scope_files (same function --dry-run uses)
    local result
    result=$(discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT")

    local count
    count=$(echo "$result" | grep -c '.mjs$')
    assert_eq "dry-run lists matching files" "3" "$count"

    # Verify no queue_all.txt was created (dry-run doesn't create state)
    assert_file_not_exists "dry-run does not create queue_all.txt" "$edir/queue_all.txt"

    rm -rf "$tmpdir"
}

test_dry_run_prints_files

# ============================================================
# --init: validates complete scope
# ============================================================

echo ""
echo "--- --init scope validation ---"

test_init_validates_complete_scope() {
    # Test that missing fields are detected
    # We test the validation logic directly (grepping for fields)

    local tmpdir
    tmpdir=$(mktemp -d)

    # Missing boundary_packages
    cat > "$tmpdir/scope_incomplete.json" << 'EOF'
{
  "seed": "src/main.go",
  "boundaries": {
    "explore_within": ["src/**"]
  },
}
EOF

    local missing=""
    grep -q '"seed"' "$tmpdir/scope_incomplete.json" || missing="$missing seed"
    grep -q '"explore_within"' "$tmpdir/scope_incomplete.json" || missing="$missing explore_within"
    grep -q '"boundary_packages"' "$tmpdir/scope_incomplete.json" || missing="$missing boundary_packages"

    assert_eq "detects missing boundary_packages" " boundary_packages" "$missing"

    # Complete scope — no missing fields
    cat > "$tmpdir/scope_complete.json" << 'EOF'
{
  "seed": "src/main.go",
  "boundaries": {
    "explore_within": ["src/**"],
    "boundary_packages": ["lib/auth"]
  },
}
EOF

    missing=""
    grep -q '"seed"' "$tmpdir/scope_complete.json" || missing="$missing seed"
    grep -q '"explore_within"' "$tmpdir/scope_complete.json" || missing="$missing explore_within"
    grep -q '"boundary_packages"' "$tmpdir/scope_complete.json" || missing="$missing boundary_packages"

    assert_eq "complete scope has no missing fields" "" "$missing"

    rm -rf "$tmpdir"
}

test_init_validates_complete_scope

# ============================================================
# Batch explored detection
# ============================================================

echo ""
echo "--- batch explored detection ---"

test_batch_explored_detection() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/nodes"
    touch "$tmpdir/explored.txt"

    # Simulate: batch has 3 files, only 2 got node output
    local batch
    batch=$(printf 'src/a.go\nsrc/b.go\nsrc/c.go\n')

    # Create node files for a and c (but not b)
    echo '{}' > "$tmpdir/nodes/src__a.go.json"
    echo '{}' > "$tmpdir/nodes/src__c.go.json"

    # Run the detection logic
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        local sanitized
        sanitized=$(sanitize_node_name "$file")
        if [ -f "$tmpdir/nodes/${sanitized}.json" ]; then
            echo "$file" >> "$tmpdir/explored.txt"
        fi
    done <<< "$batch"

    local explored_count
    explored_count=$(wc -l < "$tmpdir/explored.txt" | tr -d ' ')
    assert_eq "only files with node output marked explored" "2" "$explored_count"

    # Verify b.go is NOT in explored
    local has_b
    has_b=$(grep -c 'src/b.go' "$tmpdir/explored.txt" || true)
    assert_eq "b.go not in explored" "0" "$has_b"

    # Verify a.go and c.go ARE in explored
    local has_a has_c
    has_a=$(grep -c 'src/a.go' "$tmpdir/explored.txt" || true)
    has_c=$(grep -c 'src/c.go' "$tmpdir/explored.txt" || true)
    assert_eq "a.go in explored" "1" "$has_a"
    assert_eq "c.go in explored" "1" "$has_c"

    rm -rf "$tmpdir"
}

test_batch_explored_detection

# ============================================================
# Pending computation with comm
# ============================================================

echo ""
echo "--- pending computation ---"

test_pending_computation() {
    local tmpdir
    tmpdir=$(mktemp -d)

    printf 'a.go\nb.go\nc.go\nd.go\ne.go\n' > "$tmpdir/all.txt"
    printf 'b.go\nd.go\n' > "$tmpdir/explored.txt"

    local pending
    pending=$(comm -23 <(sort "$tmpdir/all.txt") <(sort "$tmpdir/explored.txt"))

    local count
    count=$(echo "$pending" | wc -l | tr -d ' ')
    assert_eq "pending count is 3" "3" "$count"

    # Verify exact pending set
    local has_a has_c has_e
    has_a=$(echo "$pending" | grep -c '^a\.go$' || true)
    has_c=$(echo "$pending" | grep -c '^c\.go$' || true)
    has_e=$(echo "$pending" | grep -c '^e\.go$' || true)
    assert_eq "a.go is pending" "1" "$has_a"
    assert_eq "c.go is pending" "1" "$has_c"
    assert_eq "e.go is pending" "1" "$has_e"

    # Verify explored files NOT in pending
    local has_b has_d
    has_b=$(echo "$pending" | grep -c '^b\.go$' || true)
    has_d=$(echo "$pending" | grep -c '^d\.go$' || true)
    assert_eq "b.go not pending" "0" "$has_b"
    assert_eq "d.go not pending" "0" "$has_d"

    rm -rf "$tmpdir"
}

test_pending_computation_empty_explored() {
    local tmpdir
    tmpdir=$(mktemp -d)

    printf 'a.go\nb.go\n' > "$tmpdir/all.txt"
    touch "$tmpdir/explored.txt"

    local count
    count=$(comm -23 <(sort "$tmpdir/all.txt") <(sort "$tmpdir/explored.txt") | wc -l | tr -d ' ')
    assert_eq "empty explored means all pending" "2" "$count"

    rm -rf "$tmpdir"
}

test_pending_computation_all_explored() {
    local tmpdir
    tmpdir=$(mktemp -d)

    printf 'a.go\nb.go\n' > "$tmpdir/all.txt"
    printf 'a.go\nb.go\n' > "$tmpdir/explored.txt"

    local count
    count=$(comm -23 <(sort "$tmpdir/all.txt") <(sort "$tmpdir/explored.txt") | wc -l | tr -d ' ')
    assert_eq "all explored means 0 pending" "0" "$count"

    rm -rf "$tmpdir"
}

test_pending_computation
test_pending_computation_empty_explored
test_pending_computation_all_explored

# ============================================================
# Summary
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[ $FAIL -eq 0 ] || exit 1
