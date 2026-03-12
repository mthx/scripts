# wt.zsh - Git worktree manager with APFS CoW node_modules
#
# Source this from .zshrc:
#   source ~/scripts/wt.zsh
#

function wt() {
  local main_worktree
  main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')

  if [[ -z "$main_worktree" ]]; then
    echo "wt: not in a git repository" >&2
    return 1
  fi

  case "$1" in
    "") _wt_list "$main_worktree" ;;
    -d|--delete) shift; _wt_delete "$main_worktree" "$@" ;;
    -h|--help) _wt_help ;;
    .) _wt_ghostty_switch_or_create "$main_worktree" "${main_worktree:t}" "$(git -C "$main_worktree" branch --show-current 2>/dev/null || echo main)" ;;
    *) _wt_create_or_switch "$main_worktree" "$1" ;;
  esac
}

# Sanitize branch name for use as directory suffix
# feature/cool-thing → feature-cool-thing
function _wt_dir_suffix() {
  printf '%s\n' "${1//\//-}"
}

# List worktrees, cd via fzf if available
function _wt_list() {
  local main_worktree="$1"
  local worktrees
  worktrees=$(git worktree list)

  if command -v fzf &>/dev/null; then
    local selected_line
    selected_line=$(echo "$worktrees" | fzf --prompt="worktree> ")
    if [[ -n "$selected_line" ]]; then
      local selected_path selected_branch
      selected_path=$(echo "$selected_line" | awk '{print $1}')
      selected_branch=$(echo "$selected_line" | awk '{gsub(/[\[\]]/, "", $3); print $3}')
      local repo_name="${main_worktree:t}"
      _wt_ghostty_switch_or_create "$selected_path" "$repo_name" "$selected_branch"
    fi
  else
    echo "$worktrees"
  fi
}

# Create worktree or cd to existing one
function _wt_create_or_switch() {
  local main_worktree="$1"
  local branch="$2"
  local suffix="$(_wt_dir_suffix "$branch")"
  local target="${main_worktree}--${suffix}"
  local repo_name="${main_worktree:t}"

  # Already exists — just go there
  if [[ -d "$target" ]]; then
    _wt_ghostty_switch_or_create "$target" "$repo_name" "$branch"
    return
  fi

  # Branch already checked out in another worktree — cd there
  local existing
  existing=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{path=$0} /^branch refs\/heads\/'"$branch"'$/{print path}' | sed 's/^worktree //')
  if [[ -n "$existing" ]]; then
    _wt_ghostty_switch_or_create "$existing" "$repo_name" "$branch"
    return
  fi

  # Determine if branch exists locally, on remote, or is new
  if git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git worktree add "$target" "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
    git worktree add "$target" "$branch"
  else
    git worktree add -b "$branch" "$target"
  fi

  if [[ $? -ne 0 ]]; then
    echo "wt: failed to create worktree" >&2
    return 1
  fi

  # Clone node_modules via APFS CoW if main has them
  _wt_clone_deps "$main_worktree" "$target"

  _wt_ghostty_switch_or_create "$target" "$repo_name" "$branch"
}

# Clone node_modules using APFS copy-on-write (cp -c)
function _wt_clone_deps() {
  local src="$1"
  local dst="$2"

  if [[ -d "$src/node_modules" && -f "$dst/package.json" && ! -d "$dst/node_modules" ]]; then
    echo "wt: cloning node_modules (APFS CoW)..."
    if cp -Rc "$src/node_modules" "$dst/node_modules" 2>/dev/null; then
      echo "wt: node_modules ready"
    else
      echo "wt: CoW clone failed — run npm install manually" >&2
    fi
  fi
}

# Remove a worktree
function _wt_delete() {
  local main_worktree="$1"
  local branch="$2"

  local target

  # No branch specified — infer from current worktree
  if [[ -z "$branch" ]]; then
    if [[ "$PWD" = "${main_worktree}--"* ]]; then
      # Extract worktree root even if we're in a subdirectory
      local rest="${PWD#"${main_worktree}--"}"
      target="${main_worktree}--${rest%%/*}"
    else
      echo "wt: specify a branch to delete (or run from inside a worktree)" >&2
      return 1
    fi
  else
    local suffix="$(_wt_dir_suffix "$branch")"
    target="${main_worktree}--${suffix}"
  fi

  # Derive branch name for tab title from the worktree
  local wt_branch
  wt_branch=$(git -C "$target" branch --show-current 2>/dev/null)
  local repo_name="${main_worktree:t}"

  if [[ "$PWD" = "$target"* ]]; then
    cd "$main_worktree" || { echo "wt: cannot cd to $main_worktree" >&2; return 1; }
  fi

  git worktree remove "$target" && \
    [[ -n "$wt_branch" ]] && _wt_ghostty_close_tab "${repo_name}[${wt_branch}]"
}

# Ghostty tab integration: switch to existing tab or create new one
function _wt_ghostty_switch_or_create() {
  local target_dir="$1"
  local repo_name="$2"
  local branch="$3"
  local tab_title="${repo_name}[${branch}]"

  # If not running in Ghostty, just cd
  if [[ "$TERM_PROGRAM" != "ghostty" ]]; then
    cd "$target_dir"
    return
  fi

  # Try to switch to existing tab with this title
  if _wt_ghostty_select_tab "$tab_title"; then
    return
  fi

  # Create new tab with CWD and WT_TAB_TITLE set via environment
  # so it's available when .zshrc sources wt.zsh
  local err
  err=$(osascript - "$target_dir" "$tab_title" <<'APPLESCRIPT' 2>&1
on run argv
  tell application "Ghostty"
    set cfg to new surface configuration from {initial working directory:item 1 of argv, environment variables:{"WT_TAB_TITLE=" & item 2 of argv}}
    set newTab to new tab in front window with configuration cfg
    -- Split right, then split the right pane down
    set term1 to focused terminal of newTab
    set rightPane to split term1 direction right with configuration cfg
    split rightPane direction down with configuration cfg
  end tell
end run
APPLESCRIPT
  )

  if [[ $? -ne 0 ]]; then
    echo "wt: ghostty tab creation failed: $err" >&2
    echo "wt: falling back to cd" >&2
    cd "$target_dir"
    return
  fi
}

# Select a Ghostty tab by title, returns 0 if found
function _wt_ghostty_select_tab() {
  local title="$1"
  local result
  result=$(osascript - "$title" <<'APPLESCRIPT' 2>&1
on run argv
  set targetTitle to item 1 of argv
  tell application "Ghostty"
    repeat with w in windows
      repeat with t in tabs of w
        if name of t is targetTitle then
          select tab t
          activate window w
          return true
        end if
      end repeat
    end repeat
    return false
  end tell
end run
APPLESCRIPT
  )

  if [[ $? -ne 0 ]]; then
    echo "wt: ghostty tab select failed: $result" >&2
    return 1
  fi
  [[ "$result" == *true* ]]
}

# When WT_TAB_TITLE is set, pin the tab title.
#
# Ideally we'd set Ghostty's titleOverride via AppleScript (the same sticky
# title you get from double-click renaming a tab), but the tab name property
# is read-only and there's no set_tab_title action — only the interactive
# prompt_tab_title. So instead we override _ghostty_precmd/_ghostty_preexec
# to emit our fixed title, winning the race against Ghostty's shell
# integration. We must defer because Ghostty uses _ghostty_deferred_init
# which rebuilds _ghostty_precmd on first prompt, destroying earlier overrides.
if [[ -n "$WT_TAB_TITLE" ]]; then
  DISABLE_AUTO_TITLE=true
  _wt_deferred_init() {
    _ghostty_precmd() { builtin printf '\e]2;%s\a' "$WT_TAB_TITLE"; }
    _ghostty_preexec() { builtin printf '\e]2;%s\a' "$WT_TAB_TITLE"; }
    builtin printf '\e]2;%s\a' "$WT_TAB_TITLE"
    precmd_functions=(${precmd_functions:#_wt_deferred_init})
  }
  precmd_functions+=(_wt_deferred_init)
fi

# Close a Ghostty tab by title
function _wt_ghostty_close_tab() {
  local title="$1"
  local err
  err=$(osascript - "$title" <<'APPLESCRIPT' 2>&1
on run argv
  set targetTitle to item 1 of argv
  tell application "Ghostty"
    repeat with w in windows
      repeat with t in tabs of w
        if name of t is targetTitle then
          close tab t
          return
        end if
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
  )

  if [[ $? -ne 0 ]]; then
    echo "wt: ghostty tab close failed: $err" >&2
  fi
}

function _wt_help() {
  cat <<'EOF'
wt - zsh Git worktree manager

Usage:
  wt              List worktrees (fzf picker if available)
  wt <branch>     Create or switch to worktree for <branch>
  wt .            Go to main worktree
  wt -d [branch]  Remove worktree (defaults to current if in one)
  wt -h           Show this help

Worktrees are created as sibling directories with a -- suffix:
  /path/to/repo          main worktree
  /path/to/repo--branch  linked worktree

If <branch> is already checked out in a worktree, cd's there.
If node_modules exists in main, it is cloned via APFS CoW.
EOF
}

# Zsh completion: complete branch names and flags
function _wt_complete() {
  local -a branches flags
  flags=(-d -h --delete --help)

  if [[ "$words[2]" == -d || "$words[2]" == --delete ]]; then
    # Complete with existing worktree branches
    local main_worktree
    main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    if [[ -n "$main_worktree" ]]; then
      local -a wt_branches
      wt_branches=(${(f)"$(git worktree list --porcelain 2>/dev/null | grep '^branch ' | sed 's|^branch refs/heads/||')"})
      _describe 'worktree branch' wt_branches
    fi
  else
    local -a remote_branches
    branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"})
    # Strip origin/ prefix so completing "foo" works for "origin/foo"
    remote_branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null | sed 's|^origin/||')"})
    _alternative \
      'flags:flag:compadd -a flags' \
      'branches:local branch:compadd -a branches' \
      'remote-branches:remote branch:compadd -a remote_branches'
  fi
}
compdef _wt_complete wt
