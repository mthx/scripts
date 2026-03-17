# wt.zsh - Git worktree manager with APFS CoW node_modules
#
# Source this from .zshrc:
#   source ~/scripts/wt.zsh
#
# Tab title convention: "{repo}[{branch}]" (e.g. ml-trainer[main])
# Also used by: ghw (GitHub Actions watcher) to focus tabs on build completion
#

function wt() {
  local main_worktree repo_arg

  # Parse -r <path> if present
  if [[ "$1" == -r ]]; then
    if [[ -z "$2" ]]; then
      echo "wt: -r requires a path" >&2
      return 1
    fi
    repo_arg="$2"
    shift 2
  fi

  if [[ -n "$repo_arg" ]]; then
    main_worktree=$(git -C "$repo_arg" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    if [[ -z "$main_worktree" ]]; then
      echo "wt: not a git repository: $repo_arg" >&2
      return 1
    fi
  else
    main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    if [[ -z "$main_worktree" ]]; then
      echo "wt: not in a git repository" >&2
      return 1
    fi
  fi

  case "$1" in
    "") _wt_list "$main_worktree" ;;
    -c|--close) shift; _wt_close "$main_worktree" "$@" ;;
    -d|--delete) shift; _wt_delete "$main_worktree" "$@" ;;
    -h|--help) _wt_help ;;
    .) _wt_ghostty_switch_or_create "$main_worktree" "${main_worktree:t}" "$(git -C "$main_worktree" branch --show-current 2>/dev/null || git -C "$main_worktree" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo detached)" ;;
    -) _wt_prev_switch "$main_worktree" ;;
    *) _wt_create_or_switch "$main_worktree" "$1" ;;
  esac
}

# Switch to previous worktree for this repo
function _wt_prev_switch() {
  local main_worktree="$1"
  local prev_file="$main_worktree/.git/wt-prev"
  if [[ ! -f "$prev_file" ]]; then
    echo "wt: no previous worktree" >&2
    return 1
  fi
  local prev
  prev=$(<"$prev_file")
  if [[ -z "$prev" || ! -d "$prev" ]]; then
    echo "wt: previous worktree no longer exists" >&2
    rm -f "$prev_file"
    return 1
  fi
  local branch
  branch=$(git -C "$prev" branch --show-current 2>/dev/null || echo detached)
  _wt_ghostty_switch_or_create "$prev" "${main_worktree:t}" "$branch"
}

# Sanitize branch name for use as directory suffix
# feature/cool-thing → feature-cool-thing
# Rejects names that would escape the sibling directory
function _wt_dir_suffix() {
  local name="${1//\//-}"
  if [[ "$name" == *..* || "$name" == -* || -z "$name" ]]; then
    echo "wt: invalid branch name: $1" >&2
    return 1
  fi
  printf '%s\n' "$name"
}

# List worktrees, cd via fzf if available
function _wt_list() {
  local main_worktree="$1"

  if command -v fzf &>/dev/null; then
    local selected_line
    selected_line=$(git worktree list | fzf \
      --prompt="worktrees> " \
      --header="ctrl-b: branches │ ctrl-w: worktrees" \
      --bind "ctrl-b:reload(git for-each-ref --format='%(refname:short)' refs/heads/ refs/remotes/origin/ | sed 's|^origin/||' | sort -u)+change-prompt(branches> )" \
      --bind "ctrl-w:reload(git worktree list)+change-prompt(worktrees> )")
    if [[ -n "$selected_line" ]]; then
      # Detect if this is a worktree line (has path + hash + [branch]) or a branch name
      if [[ "$selected_line" == /* ]]; then
        # Worktree line — extract path and branch
        local selected_path selected_branch
        selected_path=$(echo "$selected_line" | awk '{print $1}')
        selected_branch=$(echo "$selected_line" | awk '{gsub(/[\[\]]/, "", $3); print $3}')
        local repo_name="${main_worktree:t}"
        _wt_ghostty_switch_or_create "$selected_path" "$repo_name" "$selected_branch"
      else
        # Branch name — treat like wt <branch>
        _wt_create_or_switch "$main_worktree" "$selected_line"
      fi
    fi
  else
    git worktree list
  fi
}

# Create worktree or cd to existing one
function _wt_create_or_switch() {
  local main_worktree="$1"
  local branch="$2"
  local suffix
  suffix="$(_wt_dir_suffix "$branch")" || return 1
  local target="${main_worktree}--${suffix}"
  local repo_name="${main_worktree:t}"

  # Already exists — just go there
  if [[ -d "$target" ]]; then
    _wt_ghostty_switch_or_create "$target" "$repo_name" "$branch"
    return
  fi

  # Clean up any prunable worktrees (deleted directories) before checking
  git worktree prune 2>/dev/null

  # Branch already checked out in another worktree — cd there
  local existing
  existing=$(git worktree list --porcelain 2>/dev/null | awk -v b="$branch" '/^worktree /{path=$0} $0 == "branch refs/heads/" b {print path}' | sed 's/^worktree //')
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

# Resolve a worktree target from branch name or cwd
# Sets REPLY to the target path
function _wt_resolve_target() {
  local main_worktree="$1"
  local branch="$2"

  if [[ -z "$branch" ]]; then
    if [[ "$PWD" = "${main_worktree}--"* ]]; then
      local rest="${PWD#"${main_worktree}--"}"
      REPLY="${main_worktree}--${rest%%/*}"
    else
      echo "wt: specify a branch (or run from inside a worktree)" >&2
      return 1
    fi
  else
    local suffix
    suffix="$(_wt_dir_suffix "$branch")" || return 1
    REPLY="${main_worktree}--${suffix}"
  fi
}

# Remove a worktree (and close its Ghostty tab)
function _wt_delete() {
  local main_worktree="$1"
  shift
  local force=""
  if [[ "$1" == -f || "$1" == --force ]]; then
    force="-f"
    shift
  fi
  _wt_resolve_target "$main_worktree" "$1" || return 1
  local target="$REPLY"

  local wt_branch repo_name="${main_worktree:t}"
  wt_branch=$(git -C "$target" branch --show-current 2>/dev/null)

  # Test removal in a subshell so we don't cd away on failure
  (git worktree remove $force "$target") || return 1

  [[ "$PWD" = "$target"* ]] && cd "$main_worktree"
  [[ -n "$wt_branch" ]] && _wt_ghostty_close_tab "${repo_name}[${wt_branch}]"
}

# Close a worktree's Ghostty tab (without removing the worktree)
function _wt_close() {
  local main_worktree="$1"
  _wt_resolve_target "$main_worktree" "$2" || return 1
  local target="$REPLY"

  local wt_branch repo_name="${main_worktree:t}"
  wt_branch=$(git -C "$target" branch --show-current 2>/dev/null)

  if [[ -z "$wt_branch" ]]; then
    echo "wt: could not determine branch for $target" >&2
    return 1
  fi

  _wt_ghostty_close_tab "${repo_name}[${wt_branch}]"
}

# Ghostty tab integration: switch to existing tab or create new one
function _wt_ghostty_switch_or_create() {
  local target_dir="$1"
  local repo_name="$2"
  local branch="$3"
  local tab_title="${repo_name}[${branch}]"

  # Already here — nothing to do
  if [[ "$PWD" = "$target_dir" || "$PWD" = "$target_dir/"* ]]; then
    echo "wt: already in $tab_title"
    return
  fi

  # Remember current worktree root for `wt -`
  local main_worktree
  main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  if [[ -n "$main_worktree" ]]; then
    local current_root
    current_root=$(git rev-parse --show-toplevel 2>/dev/null)
    printf '%s\n' "${current_root:-$PWD}" > "$main_worktree/.git/wt-prev"
  fi

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

# Focus a worktree's Ghostty tab without cd'ing.
# Usage: wt-focus [-r <repo>] <branch>
# Used by external tools (e.g. ghw) to focus a tab by repo+branch.
function wt-focus() {
  local repo_arg=""
  if [[ "$1" == -r ]]; then
    repo_arg="$2"; shift 2
  fi
  local branch="$1"
  if [[ -z "$branch" ]]; then
    echo "wt-focus: requires a branch name" >&2
    return 1
  fi

  local main_worktree
  if [[ -n "$repo_arg" ]]; then
    main_worktree=$(git -C "$repo_arg" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  else
    main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  fi
  if [[ -z "$main_worktree" ]]; then
    echo "wt-focus: not a git repository" >&2
    return 1
  fi

  local tab_title="${main_worktree:t}[${branch}]"
  _wt_ghostty_select_tab "$tab_title"
}

function _wt_help() {
  cat <<'EOF'
wt - zsh Git worktree manager

Usage:
  wt              List worktrees (fzf picker if available)
  wt <branch>     Create or switch to worktree for <branch>
  wt .            Go to main worktree
  wt -            Switch to previous worktree (like cd -)
  wt -c [branch]  Close Ghostty tab for worktree (keeps worktree)
  wt -d [-f] [branch]  Remove worktree and close its tab (-f for dirty trees)
  wt -r <path>    Target a different repo (combine with any command above)
  wt -h           Show this help

Examples:
  wt -r ~/projects/app feat-x   Switch to feat-x in another repo
  wt -r ~/projects/app -d old   Delete worktree in another repo

Worktrees are created as sibling directories with a -- suffix:
  /path/to/repo          main worktree
  /path/to/repo--branch  linked worktree

If <branch> is already checked out in a worktree, cd's there.
If node_modules exists in main, it is cloned via APFS CoW.
EOF
}

# Zsh completion: complete branch names and flags
function _wt_complete() {
  local -a flags
  flags=(-c -d -h -r --close --delete --help)

  # Find -r <path> on the line to resolve the target repo
  local git_dir=""
  local i
  for (( i=2; i < CURRENT; i++ )); do
    if [[ "$words[$i]" == -r && -n "$words[$((i+1))]" ]]; then
      git_dir="${~words[$((i+1))]}"
      break
    fi
  done
  local -a git_cmd
  if [[ -n "$git_dir" ]]; then
    git_cmd=(git -C "$git_dir")
  else
    git_cmd=(git)
  fi

  # Completing the path after -r
  if [[ "$words[$((CURRENT-1))]" == -r ]]; then
    _files -/
    return
  fi

  # After -c or -d: complete worktree branches
  if (( ${words[(I)-c]} || ${words[(I)--close]} || ${words[(I)-d]} || ${words[(I)--delete]} )); then
    local -a wt_branches
    wt_branches=(${(f)"$($git_cmd worktree list --porcelain 2>/dev/null | grep '^branch ' | sed 's|^branch refs/heads/||')"})
    _describe 'worktree branch' wt_branches
    return
  fi

  # Default: flags + branches
  local -a branches remote_branches
  branches=(${(f)"$($git_cmd for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"})
  remote_branches=(${(f)"$($git_cmd for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null | sed 's|^origin/||')"})
  _alternative \
    'flags:flag:compadd -a flags' \
    'branches:local branch:compadd -a branches' \
    'remote-branches:remote branch:compadd -a remote_branches'
}
compdef _wt_complete wt
