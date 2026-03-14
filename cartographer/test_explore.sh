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
    # Try python first, fall back to jq
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

test_queue_pending_count_with_items() {
    local result
    result=$(queue_pending_count "$FIXTURES/queue_with_pending.json")
    assert_eq "queue with 1 pending item returns 1" "1" "$result"
}

test_queue_pending_count_empty() {
    local result
    result=$(queue_pending_count "$FIXTURES/queue_empty.json")
    assert_eq "empty queue returns 0" "0" "$result"
}

test_queue_pending_count_missing_file() {
    local result
    result=$(queue_pending_count "/nonexistent/file.json")
    assert_eq "missing file returns 0" "0" "$result"
}

test_queue_pending_count_with_items
test_queue_pending_count_empty
test_queue_pending_count_missing_file

# ============================================================
# is_budget_exhausted tests
# ============================================================

echo ""
echo "--- is_budget_exhausted ---"

test_budget_not_exhausted() {
    local rc=0
    is_budget_exhausted "$FIXTURES/stats_under_budget.json" "$FIXTURES/scope.json" || rc=$?
    assert_exit_code "under budget returns 1 (false)" 1 $rc
}

test_budget_exhausted_by_nodes() {
    # stats_over_budget has total_nodes_explored=5, scope max_nodes=5
    local rc=0
    is_budget_exhausted "$FIXTURES/stats_over_budget.json" "$FIXTURES/scope.json" || rc=$?
    assert_exit_code "at max_nodes returns 0 (true)" 0 $rc
}

test_budget_exhausted_by_iterations() {
    # stats_over_budget has last_iteration=10, scope max_iterations=10
    local rc=0
    is_budget_exhausted "$FIXTURES/stats_over_budget.json" "$FIXTURES/scope.json" || rc=$?
    assert_exit_code "at max_iterations returns 0 (true)" 0 $rc
}

test_budget_missing_files() {
    local rc=0
    is_budget_exhausted "/nonexistent" "/nonexistent2" || rc=$?
    assert_exit_code "missing files returns 1 (false / not exhausted)" 1 $rc
}

test_budget_not_exhausted
test_budget_exhausted_by_nodes
test_budget_exhausted_by_iterations
test_budget_missing_files

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
# detect_completion tests
# ============================================================

echo ""
echo "--- detect_completion ---"

test_detect_map_complete() {
    local result
    result=$(detect_completion "All nodes explored. <promise>MAP_COMPLETE</promise>")
    local rc=$?
    assert_exit_code "MAP_COMPLETE returns 0" 0 $rc
    assert_eq "MAP_COMPLETE signal detected" "MAP_COMPLETE" "$result"
}

test_detect_budget_reached() {
    local result
    result=$(detect_completion "Budget limit. <promise>BUDGET_REACHED</promise>")
    local rc=$?
    assert_exit_code "BUDGET_REACHED returns 0" 0 $rc
    assert_eq "BUDGET_REACHED signal detected" "BUDGET_REACHED" "$result"
}

test_detect_context_full() {
    local result
    result=$(detect_completion "Context heavy. <promise>CONTEXT_FULL</promise>")
    local rc=$?
    assert_exit_code "CONTEXT_FULL returns 0" 0 $rc
    assert_eq "CONTEXT_FULL signal detected" "CONTEXT_FULL" "$result"
}

test_detect_no_signal() {
    local rc=0
    detect_completion "Just normal output with no signals" >/dev/null 2>&1 || rc=$?
    assert_exit_code "no signal returns 1" 1 $rc
}

test_detect_from_file() {
    local tmpfile
    tmpfile=$(mktemp)
    echo "Explored 3 nodes. <promise>MAP_COMPLETE</promise>" > "$tmpfile"
    local result
    result=$(detect_completion "$tmpfile")
    local rc=$?
    rm -f "$tmpfile"
    assert_exit_code "file input returns 0" 0 $rc
    assert_eq "detects signal from file" "MAP_COMPLETE" "$result"
}

test_detect_map_complete
test_detect_budget_reached
test_detect_context_full
test_detect_no_signal
test_detect_from_file

# ============================================================
# init_exploration tests
# ============================================================

echo ""
echo "--- init_exploration ---"

test_init_creates_structure() {
    local tmpdir
    tmpdir=$(mktemp -d)

    init_exploration "$tmpdir" "src/main.go"

    assert_dir_exists "creates nodes dir" "$tmpdir/nodes"
    assert_dir_exists "creates edges dir" "$tmpdir/edges"
    assert_file_exists "creates queue.json" "$tmpdir/queue.json"
    assert_file_exists "creates index.json" "$tmpdir/index.json"
    assert_file_exists "creates stats.json" "$tmpdir/stats.json"
    assert_file_exists "creates findings.md" "$tmpdir/findings.md"

    rm -rf "$tmpdir"
}

test_init_seeds_valid_json() {
    local tmpdir
    tmpdir=$(mktemp -d)

    init_exploration "$tmpdir" "src/main.go"

    assert_json_valid "queue.json is valid JSON" "$tmpdir/queue.json"
    assert_json_valid "index.json is valid JSON" "$tmpdir/index.json"
    assert_json_valid "stats.json is valid JSON" "$tmpdir/stats.json"

    rm -rf "$tmpdir"
}

test_init_queue_has_seed() {
    local tmpdir
    tmpdir=$(mktemp -d)

    init_exploration "$tmpdir" "src/main.go"

    local has_seed
    has_seed=$(grep -c 'src/main.go' "$tmpdir/queue.json")
    assert_eq "queue.json contains seed" "1" "$has_seed"

    local pending_count
    pending_count=$(queue_pending_count "$tmpdir/queue.json")
    assert_eq "queue has 1 pending item" "1" "$pending_count"

    rm -rf "$tmpdir"
}

test_init_stats_zeroed() {
    local tmpdir
    tmpdir=$(mktemp -d)

    init_exploration "$tmpdir" "src/main.go"

    local explored
    explored=$(grep -o '"total_nodes_explored":[[:space:]]*[0-9]*' "$tmpdir/stats.json" | grep -o '[0-9]*$')
    assert_eq "stats starts with 0 explored" "0" "$explored"

    rm -rf "$tmpdir"
}

test_init_multiple_seeds() {
    local tmpdir
    tmpdir=$(mktemp -d)

    init_exploration "$tmpdir" "a.mjs" "b.mjs" "c.mjs"

    local pending_count
    pending_count=$(queue_pending_count "$tmpdir/queue.json")
    assert_eq "multiple seeds: queue has 3 pending items" "3" "$pending_count"

    assert_json_valid "multiple seeds: queue.json is valid JSON" "$tmpdir/queue.json"

    local discovered
    discovered=$(grep -o '"total_nodes_discovered":[[:space:]]*[0-9]*' "$tmpdir/stats.json" | grep -o '[0-9]*$')
    assert_eq "multiple seeds: stats counts all seeds" "3" "$discovered"

    rm -rf "$tmpdir"
}

test_init_creates_structure
test_init_seeds_valid_json
test_init_queue_has_seed
test_init_stats_zeroed
test_init_multiple_seeds

# ============================================================
# discover_boundaries tests
# ============================================================

echo ""
echo "--- discover_boundaries ---"

test_discover_finds_siblings() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/src/report" "$tmpdir/src/graph-utl" "$tmpdir/src/utl" "$tmpdir/src/validate"

    local result
    result=$(discover_boundaries "src/report/**" "$tmpdir")
    local count
    count=$(echo "$result" | grep -c '.' || true)
    assert_eq "finds sibling dirs" "3" "$count"

    rm -rf "$tmpdir"
}

test_discover_excludes_scope_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/src/report" "$tmpdir/src/graph-utl" "$tmpdir/src/utl"

    local result
    result=$(discover_boundaries "src/report/**" "$tmpdir")
    local has_report
    has_report=$(echo "$result" | grep -c 'src/report$' || true)
    assert_eq "excludes scope dir from output" "0" "$has_report"

    rm -rf "$tmpdir"
}

test_discover_no_siblings() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/src/report"

    local result
    result=$(discover_boundaries "src/report/**" "$tmpdir")
    assert_eq "no siblings returns empty" "" "$result"

    rm -rf "$tmpdir"
}

test_discover_missing_parent() {
    local result
    result=$(discover_boundaries "nonexistent/path/**" "/tmp/nowhere_$$")
    assert_eq "missing parent returns empty" "" "$result"
}

test_discover_finds_siblings
test_discover_excludes_scope_dir
test_discover_no_siblings
test_discover_missing_parent

# ============================================================
# detect_ignore_patterns tests
# ============================================================

echo ""
echo "--- detect_ignore_patterns ---"

test_ignore_js() {
    local result
    result=$(detect_ignore_patterns "foo.mjs")
    local has_node_modules
    has_node_modules=$(echo "$result" | grep -c 'node_modules' || true)
    assert_eq "JS extension includes node_modules" "1" "$has_node_modules"
}

test_ignore_go() {
    local result
    result=$(detect_ignore_patterns "foo.go")
    local has_test
    has_test=$(echo "$result" | grep -c '_test.go' || true)
    assert_eq "Go extension includes _test.go" "1" "$has_test"
}

test_ignore_unknown() {
    local result
    result=$(detect_ignore_patterns "foo.rs")
    local has_vendor
    has_vendor=$(echo "$result" | grep -c 'vendor' || true)
    assert_eq "unknown extension includes vendor" "1" "$has_vendor"
}

test_ignore_js
test_ignore_go
test_ignore_unknown

# ============================================================
# complete_scope tests
# ============================================================

echo ""
echo "--- complete_scope ---"

test_complete_scope_writes_valid_json() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report" "$tmpdir/project/src/graph-utl" "$tmpdir/project/src/utl"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": ["src/report/index.mjs", "src/report/dot/index.mjs"],
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    complete_scope "$tmpdir/scope.json" "$tmpdir/project"
    assert_json_valid "complete_scope writes valid JSON" "$tmpdir/scope.json"

    rm -rf "$tmpdir"
}

test_complete_scope_preserves_seed() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": ["src/report/index.mjs"],
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    complete_scope "$tmpdir/scope.json" "$tmpdir/project"
    local has_seed
    has_seed=$(grep -c 'src/report/index.mjs' "$tmpdir/scope.json")
    assert_eq "preserves seed in output" "1" "$has_seed"

    rm -rf "$tmpdir"
}

test_complete_scope_adds_boundaries() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report" "$tmpdir/project/src/graph-utl" "$tmpdir/project/src/utl"

    cat > "$tmpdir/scope.json" << 'EOF'
{
  "seed": ["src/report/index.mjs"],
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    complete_scope "$tmpdir/scope.json" "$tmpdir/project"
    local has_graphutl
    has_graphutl=$(grep -c 'graph-utl' "$tmpdir/scope.json")
    assert_eq "adds discovered boundary (graph-utl)" "1" "$has_graphutl"

    local has_utl
    has_utl=$(grep -c '"src/utl"' "$tmpdir/scope.json")
    assert_eq "adds discovered boundary (utl)" "1" "$has_utl"

    rm -rf "$tmpdir"
}

test_complete_scope_fills_budget() {
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

    complete_scope "$tmpdir/scope.json" "$tmpdir/project"
    local has_max_iter
    has_max_iter=$(grep -c '"max_iterations"' "$tmpdir/scope.json")
    assert_eq "fills max_iterations default" "1" "$has_max_iter"

    local has_max_nodes
    has_max_nodes=$(grep -c '"max_nodes"' "$tmpdir/scope.json")
    assert_eq "fills max_nodes default" "1" "$has_max_nodes"

    rm -rf "$tmpdir"
}

test_complete_scope_string_seed() {
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

    complete_scope "$tmpdir/scope.json" "$tmpdir/project"
    assert_json_valid "string seed produces valid JSON" "$tmpdir/scope.json"

    local has_seed
    has_seed=$(grep -c 'src/report/index.mjs' "$tmpdir/scope.json")
    assert_eq "string seed is preserved" "1" "$has_seed"

    rm -rf "$tmpdir"
}

test_complete_scope_writes_valid_json
test_complete_scope_preserves_seed
test_complete_scope_adds_boundaries
test_complete_scope_fills_budget
test_complete_scope_string_seed

# ============================================================
# --init integration test
# ============================================================

echo ""
echo "--- --init integration ---"

test_init_mode_integration() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project/src/report" "$tmpdir/project/src/utl" "$tmpdir/project/src/lib"

    # Create minimal scope.json
    local edir="$tmpdir/exploration"
    mkdir -p "$edir"

    cat > "$edir/scope.json" << 'EOF'
{
  "seed": ["src/report/index.mjs", "src/report/dot/index.mjs"],
  "boundaries": {
    "explore_within": ["src/report/**"]
  }
}
EOF

    # Run complete_scope + init_exploration (simulating --init logic)
    complete_scope "$edir/scope.json" "$tmpdir/project"

    # Extract seeds from the seed line
    local seeds=()
    while IFS= read -r s; do
        [ -n "$s" ] && seeds+=("$s")
    done < <(grep '"seed"' "$edir/scope.json" | grep -o '"[^"]*"' | grep -v '"seed"' | tr -d '"')

    init_exploration "$edir" "${seeds[@]}"

    assert_json_valid "--init: scope.json is valid" "$edir/scope.json"
    assert_json_valid "--init: queue.json is valid" "$edir/queue.json"
    assert_file_exists "--init: stats.json exists" "$edir/stats.json"

    local pending
    pending=$(queue_pending_count "$edir/queue.json")
    assert_eq "--init: queue has all seeds" "2" "$pending"

    local has_boundary
    has_boundary=$(grep -c 'boundary_packages' "$edir/scope.json")
    assert_eq "--init: scope has boundary_packages" "1" "$has_boundary"

    rm -rf "$tmpdir"
}

test_init_mode_integration

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
    "explore_within": ["src/report/**"],
    "ignore": ["**/*.md", "**/node_modules/**"]
  }
}
EOF

    local result count
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    count=$(echo "$result" | grep -c '.mjs$')
    assert_eq "finds all .mjs files" "3" "$count"

    rm -rf "$tmpdir"
}

test_discover_scope_files_excludes_ignored() {
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
    "explore_within": ["src/report/**"],
    "ignore": ["**/*.md", "**/*.d.ts", "**/*.ts"]
  }
}
EOF

    local result count
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    count=$(echo "$result" | wc -l)
    assert_eq "excludes .md, .d.ts, .ts files" "1" "$(echo "$count" | tr -d ' ')"

    local has_md
    has_md=$(echo "$result" | grep -c '\.md$' || true)
    assert_eq "no .md in output" "0" "$has_md"

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
    "explore_within": ["src/report/**"],
    "ignore": []
  }
}
EOF

    local result
    result=$(discover_scope_files "$tmpdir/scope.json" "$tmpdir/project")
    assert_eq "empty dir returns empty" "" "$result"

    rm -rf "$tmpdir"
}

test_discover_scope_files_finds_mjs
test_discover_scope_files_excludes_ignored
test_discover_scope_files_empty_dir

# ============================================================
# Summary
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[ $FAIL -eq 0 ] || exit 1
