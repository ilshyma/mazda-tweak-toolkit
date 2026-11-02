#!/bin/sh
# Safe patching library for Tweaks Manager
# Usage: source this, then use patch_* functions
#
# Flow:
#   patch_begin "/path/to/file.js"
#   patch_sed 's/old/new/' "what this does"
#   patch_sed_range '/start/,/end/' 's/old/new/' "what this does"
#   patch_append 'code block' "what this does"
#   patch_insert_after '/pattern/' 'new line' "what this does"
#   patch_verify 'grep pattern' "expected result"
#   patch_verify_not 'grep pattern' "should be gone"
#   patch_commit

_PATCH_FILE=""
_PATCH_WORK=""
_PATCH_BAK=""
_PATCH_ERRORS=0
_PATCH_APPLIED=0
_PATCH_LOG=""
_PATCH_MARKER=""

# macOS sed -i needs '' arg, Linux/busybox does not
_SED_I="sed -i"
if [ "$(uname)" = "Darwin" ]; then
    _SED_I="sed -i ''"
fi

_sed_i() {
    if [ "$(uname)" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

patch_log() {
    _PATCH_LOG="${_PATCH_LOG}${1}\n"
}

patch_begin() {
    _PATCH_FILE="$1"
    _PATCH_MARKER="${2:-tweaks}"
    _PATCH_WORK="${_PATCH_FILE}.tweaks-work"
    _PATCH_BAK="${_PATCH_FILE}.tweaks-bak"
    _PATCH_ERRORS=0
    _PATCH_APPLIED=0
    _PATCH_LOG=""

    if [ ! -f "$_PATCH_FILE" ]; then
        patch_log "FAIL: file not found: $_PATCH_FILE"
        _PATCH_ERRORS=1
        return 1
    fi

    cp "$_PATCH_FILE" "$_PATCH_WORK"
    if [ $? -ne 0 ]; then
        patch_log "FAIL: cannot copy to work file"
        _PATCH_ERRORS=1
        return 1
    fi

    patch_log "BEGIN: $_PATCH_FILE"
    return 0
}

patch_sed() {
    _expr="$1"
    _desc="$2"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi
    if [ ! -f "$_PATCH_WORK" ]; then
        patch_log "FAIL: no work file for sed"
        _PATCH_ERRORS=1
        return 1
    fi

    # snapshot before
    _before=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)

    _sed_i "$_expr" "$_PATCH_WORK"
    if [ $? -ne 0 ]; then
        patch_log "FAIL sed: $_desc"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    fi

    # check something actually changed
    _after=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)
    if [ "$_before" = "$_after" ]; then
        patch_log "WARN sed (no change): $_desc"
        # not fatal — pattern might already be applied
    else
        _PATCH_APPLIED=$((_PATCH_APPLIED + 1))
        patch_log "OK sed: $_desc"
    fi
    return 0
}

patch_sed_range() {
    _range="$1"
    _expr="$2"
    _desc="$3"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    _before=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)

    _sed_i "${_range}${_expr}" "$_PATCH_WORK"
    if [ $? -ne 0 ]; then
        patch_log "FAIL sed_range: $_desc"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    fi

    _after=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)
    if [ "$_before" = "$_after" ]; then
        patch_log "WARN sed_range (no change): $_desc"
    else
        _PATCH_APPLIED=$((_PATCH_APPLIED + 1))
        patch_log "OK sed_range: $_desc"
    fi
    return 0
}

patch_insert_after() {
    _pattern="$1"
    _newline="$2"
    _desc="$3"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    _before=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)

    _sed_i "${_pattern}a\\
${_newline}" "$_PATCH_WORK"

    _after=$(md5sum "$_PATCH_WORK" 2>/dev/null || md5 "$_PATCH_WORK" 2>/dev/null)
    if [ "$_before" = "$_after" ]; then
        patch_log "WARN insert_after (no match): $_desc"
    else
        _PATCH_APPLIED=$((_PATCH_APPLIED + 1))
        patch_log "OK insert_after: $_desc"
    fi
    return 0
}

patch_append() {
    _code="$1"
    _desc="$2"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    printf '\n%s\n' "$_code" >> "$_PATCH_WORK"
    _PATCH_APPLIED=$((_PATCH_APPLIED + 1))
    patch_log "OK append: $_desc"
    return 0
}

patch_append_file() {
    _srcfile="$1"
    _desc="$2"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    if [ ! -f "$_srcfile" ]; then
        patch_log "FAIL append_file: source not found: $_srcfile"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    fi

    printf '\n' >> "$_PATCH_WORK"
    cat "$_srcfile" >> "$_PATCH_WORK"
    _PATCH_APPLIED=$((_PATCH_APPLIED + 1))
    patch_log "OK append_file: $_desc"
    return 0
}

patch_verify() {
    _pattern="$1"
    _desc="$2"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    if grep -q "$_pattern" "$_PATCH_WORK"; then
        patch_log "VERIFY OK: $_desc"
        return 0
    else
        patch_log "VERIFY FAIL: $_desc (pattern not found)"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    fi
}

patch_verify_not() {
    _pattern="$1"
    _desc="$2"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    if grep -q "$_pattern" "$_PATCH_WORK"; then
        patch_log "VERIFY FAIL: $_desc (pattern still present)"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    else
        patch_log "VERIFY OK (absent): $_desc"
        return 0
    fi
}

patch_verify_count() {
    _pattern="$1"
    _expected="$2"
    _desc="$3"

    if [ $_PATCH_ERRORS -ne 0 ]; then return 1; fi

    _count=$(grep -c "$_pattern" "$_PATCH_WORK")
    if [ "$_count" -eq "$_expected" ]; then
        patch_log "VERIFY OK: $_desc (count=$_count)"
        return 0
    else
        patch_log "VERIFY FAIL: $_desc (expected $_expected, got $_count)"
        _PATCH_ERRORS=$((_PATCH_ERRORS + 1))
        return 1
    fi
}

patch_commit() {
    if [ $_PATCH_ERRORS -ne 0 ]; then
        rm -f "$_PATCH_WORK"
        patch_log "ABORT: $_PATCH_ERRORS errors, file unchanged"
        printf '%b' "$_PATCH_LOG"
        return 1
    fi

    if [ $_PATCH_APPLIED -eq 0 ]; then
        rm -f "$_PATCH_WORK"
        patch_log "SKIP: no changes applied (already patched?)"
        printf '%b' "$_PATCH_LOG"
        echo "OK"
        return 0
    fi

    # save original as backup (only if no backup exists yet)
    if [ ! -f "$_PATCH_BAK" ]; then
        cp "$_PATCH_FILE" "$_PATCH_BAK"
        if [ $? -ne 0 ]; then
            rm -f "$_PATCH_WORK"
            patch_log "FAIL: cannot create backup"
            printf '%b' "$_PATCH_LOG"
            return 1
        fi
        patch_log "BACKUP: $_PATCH_BAK"
    fi

    # atomic swap: move work file over original
    mv "$_PATCH_WORK" "$_PATCH_FILE"
    if [ $? -ne 0 ]; then
        # fallback: try cp
        cp "$_PATCH_WORK" "$_PATCH_FILE"
        if [ $? -ne 0 ]; then
            patch_log "FAIL: cannot replace original"
            printf '%b' "$_PATCH_LOG"
            return 1
        fi
        rm -f "$_PATCH_WORK"
    fi

    patch_log "COMMIT: $_PATCH_APPLIED changes applied"
    printf '%b' "$_PATCH_LOG"
    echo "OK"
    return 0
}

patch_abort() {
    rm -f "$_PATCH_WORK"
    patch_log "ABORT: called explicitly"
    printf '%b' "$_PATCH_LOG"
    return 1
}

patch_rollback() {
    _file="$1"
    _bak="${_file}.tweaks-bak"

    if [ ! -f "$_bak" ]; then
        echo "FAIL: no backup found at $_bak"
        return 1
    fi

    mv "$_bak" "$_file"
    if [ $? -ne 0 ]; then
        cp "$_bak" "$_file" && rm -f "$_bak"
    fi
    echo "ROLLBACK: restored $_file"
    echo "OK"
    return 0
}
