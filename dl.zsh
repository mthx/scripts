# dl expansion widget - expands 'dl' or 'dl <pattern>' to actual file path
# Source this file in your .zshrc to enable TAB expansion of dl commands
#
# Usage:
#   Type 'cp dl' then press TAB → expands to 'cp /path/to/latest/file'
#   Type 'cp dl zip' then press TAB → expands to latest .zip file

expand-or-complete-dl() {
    # Get the current buffer and extract the last command/word
    local before_cursor="$LBUFFER"

    # Check if buffer ends with 'dl' possibly followed by arguments
    if [[ "$before_cursor" =~ '(^|[[:space:]])dl([[:space:]].*)?$' ]]; then
        # Extract everything after 'dl '
        local rest="${before_cursor##*dl}"
        local args="${rest## }"  # Trim leading spaces

        # Run dl command
        local file
        if [[ -n "$args" && "$args" != "$rest" ]]; then
            # Has arguments
            file=$(command dl $args 2>/dev/null)
        else
            # No arguments
            file=$(command dl 2>/dev/null)
        fi

        # Replace if we got a result
        if [[ -n "$file" ]]; then
            # Find where 'dl' starts and replace from there
            LBUFFER="${before_cursor%dl*}${(q)file}"
            zle redisplay
            return
        fi
    fi

    # Fall back to normal completion
    zle expand-or-complete
}
zle -N expand-or-complete-dl
bindkey '^I' expand-or-complete-dl
