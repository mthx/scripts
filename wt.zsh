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
    .) cd "$main_worktree" ;;
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
    local selected
    selected=$(echo "$worktrees" | fzf --prompt="worktree> " | awk '{print $1}')
    [[ -n "$selected" ]] && cd "$selected"
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

  # Already exists — just go there
  if [[ -d "$target" ]]; then
    cd "$target"
    return
  fi

  # Branch already checked out in another worktree — cd there
  local existing
  existing=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{path=$0} /^branch refs\/heads\/'"$branch"'$/{print path}' | sed 's/^worktree //')
  if [[ -n "$existing" ]]; then
    cd "$existing"
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

  cd "$target"
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

  if [[ "$PWD" = "$target"* ]]; then
    cd "$main_worktree" || { echo "wt: cannot cd to $main_worktree" >&2; return 1; }
  fi

  git worktree remove "$target"
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
