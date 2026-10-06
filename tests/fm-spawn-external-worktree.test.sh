#!/usr/bin/env bash
# Regression tests for fm-spawn's --worktree adoption of an externally owned
# linked worktree, such as a Garden sprout.
#
# The tests drive the real spawn path with a fake terminal and a logging
# treehouse. They prove an adopted worktree is recorded as external, never
# acquired through treehouse and never reset, that every unsafe path or flag
# combination is refused before an endpoint exists, and that a spawn without
# the flag writes no worktree_owner= line.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-external-worktree)

# make_case <name> <id>: a Garden-shaped layout - a repository checkout with an
# origin that has moved ahead, and a sprout linked worktree elsewhere on its own
# branch holding a commit origin does not have.
make_case() {
  local name=$1 id=$2 case_dir home repo origin sprout publisher fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  repo="$case_dir/garden/repos/app"
  origin="$case_dir/origin.git"
  sprout="$case_dir/garden/plots/plot/worktrees/sprout/app"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$case_dir/treehouse.log'
exit 0
SH
  chmod +x "$fakebin/treehouse"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$(dirname "$repo")"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$repo"
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$repo" "$origin"
  git -C "$repo" remote add origin "file://$origin"
  git -C "$repo" fetch --quiet origin
  mkdir -p "$(dirname "$sprout")"
  git -C "$repo" worktree add --quiet -b sprout/work "$sprout" main
  printf 'sprout commit\n' > "$sprout/sprout.txt"
  git -C "$sprout" add sprout.txt
  git -C "$sprout" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sprout-work

  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/advanced.txt"
  git -C "$publisher" add advanced.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance
  git -C "$publisher" push --quiet origin main

  printf '%s\n' "$case_dir|$home|$repo|$sprout|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR REPO_DIR SPROUT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <pane-path> <id> <args...>: the pane reports <pane-path> as its cwd.
run_spawn() {
  local pane=$1
  shift
  FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" \
    fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" "$@"
}

test_external_worktree_is_adopted_without_treehouse_or_reset() {
  local rec id out status head sprout_real
  id='external-adopt-w1'
  rec=$(make_case adopt "$id")
  read_case_record "$rec"
  head=$(git -C "$SPROUT_DIR" rev-parse HEAD)
  sprout_real=$(cd "$SPROUT_DIR" && pwd -P)

  out=$(run_spawn "$SPROUT_DIR" "$id" "$REPO_DIR" --scout --worktree "$SPROUT_DIR")
  status=$?
  expect_code 0 "$status" "a clean external worktree should be adopted"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the adopting spawn did not report success"
  assert_grep "worktree=$sprout_real" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record the adopted worktree"
  assert_grep 'worktree_owner=external' "$HOME_DIR/state/$id.meta" \
    "the spawn did not mark the worktree as externally owned"
  assert_absent "$CASE_DIR/treehouse.log" "the adopting spawn ran treehouse"
  if grep -Fq 'treehouse get' "$CASE_DIR/pane.log" 2>/dev/null; then
    fail "the adopting spawn typed treehouse get into the pane"
  fi
  [ "$(git -C "$SPROUT_DIR" rev-parse HEAD)" = "$head" ] \
    || fail "the adopting spawn reset the external worktree's HEAD"
  [ "$(git -C "$SPROUT_DIR" rev-parse --abbrev-ref HEAD)" = sprout/work ] \
    || fail "the adopting spawn moved the external worktree off its branch"
  pass "--worktree adopts a clean external worktree without treehouse and without a reset"
}

test_external_worktree_ship_keeps_owner_commits() {
  local rec id out status head
  id='external-ship-w2'
  rec=$(make_case ship "$id")
  read_case_record "$rec"
  head=$(git -C "$SPROUT_DIR" rev-parse HEAD)

  out=$(run_spawn "$SPROUT_DIR" "$id" "$REPO_DIR" --mode direct-PR --yolo off --worktree="$SPROUT_DIR")
  status=$?
  expect_code 0 "$status" "a ship spawn should adopt a clean external worktree"$'\n'"$out"
  assert_grep 'worktree_owner=external' "$HOME_DIR/state/$id.meta" \
    "the ship spawn did not mark the worktree as externally owned"
  [ "$(git -C "$SPROUT_DIR" rev-parse HEAD)" = "$head" ] \
    || fail "the ship spawn reset the external worktree to origin"
  pass "--worktree= on a ship spawn keeps the owner's commits in place"
}

# expect_refusal <label> <pattern> <spawn args...>
expect_refusal() {
  local label=$1 pattern=$2 id out status
  shift 2
  id=$1
  out=$(run_spawn "$SPROUT_DIR" "$@")
  status=$?
  [ "$status" -ne 0 ] || fail "$label: the spawn was accepted"$'\n'"$out"
  assert_contains "$out" "$pattern" "$label: the refusal did not explain itself"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$label: a refused spawn published a task record"
  assert_absent "$CASE_DIR/treehouse.log" "$label: a refused spawn ran treehouse"
  pass "--worktree refuses $label"
}

test_unsafe_worktrees_are_refused() {
  local rec id other_repo other_wt linked_project
  id='external-refuse-w3'
  rec=$(make_case refuse "$id")
  read_case_record "$rec"

  mkdir -p "$CASE_DIR/plain"
  expect_refusal "a plain directory" "is not inside a git worktree" \
    "$id" "$REPO_DIR" --scout --worktree "$CASE_DIR/plain"

  mkdir -p "$SPROUT_DIR/sub"
  expect_refusal "a worktree subdirectory" "not a worktree root" \
    "$id" "$REPO_DIR" --scout --worktree "$SPROUT_DIR/sub"
  rmdir "$SPROUT_DIR/sub"

  expect_refusal "the project itself" "is the spawning project itself" \
    "$id" "$REPO_DIR" --scout --worktree "$REPO_DIR"

  linked_project="$CASE_DIR/linked-project"
  git -C "$REPO_DIR" worktree add --quiet --detach "$linked_project" main
  expect_refusal "the primary checkout" "primary checkout" \
    "$id" "$linked_project" --scout --worktree "$REPO_DIR"

  other_repo="$CASE_DIR/other-repo"
  other_wt="$CASE_DIR/other-wt"
  fm_git_init_commit "$other_repo"
  git -C "$other_repo" worktree add --quiet -b other "$other_wt"
  expect_refusal "a worktree of another repository" "not a worktree of the same repository" \
    "$id" "$REPO_DIR" --scout --worktree "$other_wt"

  printf 'dirty\n' > "$SPROUT_DIR/dirty.txt"
  expect_refusal "a dirty worktree" "has uncommitted work" \
    "$id" "$REPO_DIR" --scout --worktree "$SPROUT_DIR"
  rm -f "$SPROUT_DIR/dirty.txt"

  # An ignored owner file never shows as dirty, so it is checked by name.
  printf '.claude/\n' >> "$(git -C "$SPROUT_DIR" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$SPROUT_DIR/.claude"
  printf '{}\n' > "$SPROUT_DIR/.claude/settings.local.json"
  expect_refusal "an owner's own hook file" "already has .claude/settings.local.json" \
    "$id" "$REPO_DIR" --scout --worktree "$SPROUT_DIR"
  rm -rf "$SPROUT_DIR/.claude"

  fm_write_meta "$HOME_DIR/state/other-task.meta" "worktree=$SPROUT_DIR" "kind=scout"
  expect_refusal "a worktree another task records" "already task other-task's recorded worktree" \
    "$id" "$REPO_DIR" --scout --worktree "$SPROUT_DIR"
  rm -f "$HOME_DIR/state/other-task.meta"

  expect_refusal "an empty value" "--worktree requires a non-empty value" \
    "$id" "$REPO_DIR" --scout --worktree=
}

test_incompatible_flags_are_refused() {
  local rec id
  id='external-flags-w4'
  rec=$(make_case flags "$id")
  read_case_record "$rec"

  expect_refusal "--relaunch" "--relaunch reuses the task's recorded worktree" \
    "$id" --relaunch --worktree "$SPROUT_DIR"
  expect_refusal "--secondmate" "--worktree applies only to ship and scout spawns" \
    "$id" --secondmate --worktree "$SPROUT_DIR"
  expect_refusal "backend=orca" "--worktree cannot be used with backend=orca" \
    "$id" "$REPO_DIR" --scout --backend orca --worktree "$SPROUT_DIR"
  expect_refusal "batch pairs" "adopts one existing worktree for one task" \
    "$id=$REPO_DIR" --scout --worktree "$SPROUT_DIR"
}

test_spawn_without_worktree_records_no_owner() {
  local rec id out status pool
  id='external-none-w5'
  rec=$(make_case none "$id")
  read_case_record "$rec"
  pool="$CASE_DIR/pool"
  git -C "$REPO_DIR" worktree add --quiet --detach "$pool" main

  out=$(run_spawn "$pool" "$id" "$REPO_DIR" --scout)
  status=$?
  expect_code 0 "$status" "an ordinary spawn should still launch"$'\n'"$out"
  assert_grep "worktree=$pool" "$HOME_DIR/state/$id.meta" \
    "the ordinary spawn did not record its acquired worktree"
  assert_no_grep 'worktree_owner=' "$HOME_DIR/state/$id.meta" \
    "an ordinary spawn wrote a worktree_owner= line"
  assert_grep 'treehouse get' "$CASE_DIR/pane.log" \
    "the ordinary spawn did not acquire its worktree through treehouse get"
  pass "a spawn without --worktree records no worktree_owner= line"
}

test_external_worktree_is_adopted_without_treehouse_or_reset
test_external_worktree_ship_keeps_owner_commits
test_unsafe_worktrees_are_refused
test_incompatible_flags_are_refused
test_spawn_without_worktree_records_no_owner
