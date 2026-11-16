#!/bin/bash
# Sourced by entrypoint.sh after the container template has been rendered.

subscription_log() { log "Subscription: $*" >&2; }

subscription_source_names() {
    local name value index priority
    while IFS= read -r name; do
        value="${!name}"
        [ -n "$value" ] || continue
        if [[ "$name" =~ ^SUB([0-9]+)$ ]]; then
            index="${BASH_REMATCH[1]}"
            priority=0
            case "${value,,}" in
                http://*|https://*) ;;
                *) subscription_log "$name must contain an HTTP(S) subscription URL"; return 1 ;;
            esac
        elif [[ "$name" =~ ^SRV([0-9]+)$ ]]; then
            index="${BASH_REMATCH[1]}"
            priority=1
            case "${value,,}" in http://*|https://*) ;; *) continue ;; esac
        else
            continue
        fi
        printf '%s\t%s\t%s\n' "$priority" "$index" "$name"
    done < <(compgen -e)
}

subscription_download() {
    local name="$1" destination="$2" diagnostic="$3"
    local headers pair key value has_hwid=0 has_ua=0 status
    local -a request_headers=() pairs=()
    headers="$(set_default_var "$name" PROVIDER_HEADER)"
    headers="${headers//#/|}"
    IFS='|' read -r -a pairs <<< "$headers"
    for pair in "${pairs[@]}"; do
        [[ "$pair" =~ ^([^:=]+)[:=](.*)$ ]] || continue
        key="$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        value="$(printf '%s' "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$key" ] && [ -n "$value" ] || continue
        case "$key$value" in
            *$'\r'*|*$'\n'*) subscription_log "$name has an invalid HTTP header"; return 1 ;;
        esac
        case "${key,,}" in x-hwid) has_hwid=1 ;; user-agent) has_ua=1 ;; esac
        request_headers+=(--header "$key: $value")
    done
    [ "$has_hwid" = 1 ] || request_headers+=(--header "x-hwid: $HWID")
    [ "$has_ua" = 1 ] || request_headers+=(--user-agent clash.meta)
    if status=$(curl --fail --location --silent --show-error \
        --proto '=http,https' --proto-redir '=http,https' \
        --connect-timeout "$SUBSCRIPTION_TIMEOUT" --max-time "$SUBSCRIPTION_TIMEOUT" \
        --max-filesize 33554432 \
        --retry 1 --retry-delay 1 "${request_headers[@]}" \
        --output "$destination" --write-out '%{http_code}' "${!name}" 2>"$diagnostic"); then
        return 0
    fi
    # curl diagnostics and URLs can include private subscription credentials.
    subscription_log "$name download failed (HTTP ${status:-000})"
    return 1
}

subscription_cached_source() {
    local name="$1" hash="$2" destination="$3"
    local cache="$SUBSCRIPTION_DIR/cache/$name.$hash.yaml"
    [ -s "$cache" ] || return 1
    cp -- "$cache" "$destination"
}

subscription_validate() {
    local candidate="$1" diagnostic="$2"
    if prizrak-core -t -d "$WORKDIR" -f "$candidate" >"$diagnostic" 2>&1; then
        return 0
    fi
    # Parser diagnostics can quote proxy credentials or private config values.
    subscription_log 'configuration validation failed; working configuration retained'
    return 1
}

subscription_update() (
    local refresh="$1" transaction name hash raw kind selected='' candidate
    local downloaded source_list previous changed=1 index lock_fd
    local -a checked_names=() checked_hashes=()
    umask 077
    exec {lock_fd}> "$SUBSCRIPTION_DIR/.lock" || return 1
    if ! flock -n "$lock_fd"; then
        subscription_log 'another configuration update is in progress'
        return 1
    fi
    transaction="$(mktemp -d "$SUBSCRIPTION_DIR/.update.XXXXXX")" || return 1
    trap 'rm -rf -- "$transaction"' EXIT
    source_list="$(subscription_source_names)" || return 1

    while IFS=$'\t' read -r _ _ name; do
        [ -n "$name" ] || continue
        hash="$(printf '%s' "${!name}" | sha256sum)"
        hash="${hash%% *}"
        raw="$transaction/$name.yaml"
        downloaded=0
        if subscription_download "$name" "$raw" "$transaction/$name.fetch-error"; then
            downloaded=1
        elif subscription_cached_source "$name" "$hash" "$raw"; then
            subscription_log "$name using cached subscription"
        else
            subscription_log "$name has no usable cache for this URL"
            return 1
        fi

        if ! kind=$("$SUBSCRIPTION_TOOL" classify --input "$raw" 2>"$transaction/$name.parse-error"); then
            if [ "$downloaded" = 1 ] && subscription_cached_source "$name" "$hash" "$raw" \
                && kind=$("$SUBSCRIPTION_TOOL" classify --input "$raw" 2>"$transaction/$name.parse-error"); then
                subscription_log "$name response is invalid; using cached subscription"
                downloaded=0
            else
                subscription_log "$name response is not a supported configuration or node subscription"
                return 1
            fi
        fi
        case "$kind" in full|nodes) ;; *) subscription_log "$name classification failed"; return 1 ;; esac
        checked_names+=("$name")
        checked_hashes+=("$hash")
        if [ "$kind" = full ]; then
            selected="$name"
            candidate="$transaction/config.yaml"
            if ! "$SUBSCRIPTION_TOOL" apply --source "$raw" --base "$SUBSCRIPTION_BASE" --output "$candidate" \
                2>"$transaction/apply-error" || ! subscription_validate "$candidate" "$transaction/validate-error"; then
                if [ "$downloaded" != 1 ] || ! subscription_cached_source "$name" "$hash" "$raw" \
                    || [ "$("$SUBSCRIPTION_TOOL" classify --input "$raw" 2>/dev/null)" != full ] \
                    || ! "$SUBSCRIPTION_TOOL" apply --source "$raw" --base "$SUBSCRIPTION_BASE" --output "$candidate" \
                        2>"$transaction/apply-error" \
                    || ! subscription_validate "$candidate" "$transaction/validate-error"; then
                    subscription_log "$name has no valid full configuration to apply"
                    return 1
                fi
                subscription_log "$name full configuration is invalid; using validated cache"
            fi
            break
        fi
    done < <(printf '%s\n' "$source_list" | sort -t $'\t' -k1,1n -k2,2n -k3,3)

    candidate="$transaction/config.yaml"
    if [ -z "$selected" ]; then
        cp -- "$SUBSCRIPTION_BASE" "$candidate" || return 1
        subscription_validate "$candidate" "$transaction/validate-error" || return 1
    fi

    previous="$transaction/previous.yaml"
    if [ -f "$SUBSCRIPTION_CONFIG" ]; then
        cp -- "$SUBSCRIPTION_CONFIG" "$previous" || return 1
        if cmp -s "$candidate" "$SUBSCRIPTION_CONFIG"; then changed=0; fi
    fi
    if [ "$changed" = 1 ]; then
        mv -- "$candidate" "$SUBSCRIPTION_CONFIG" || return 1
        if [ "$refresh" = 1 ] && ! "$SUBSCRIPTION_TOOL" reload \
            --controller "$EXTERNAL_CONTROLLER_ADDRESS:$UI_PORT" --path "$SUBSCRIPTION_CONFIG" \
            >"$transaction/reload-output" 2>"$transaction/reload-error"; then
            if [ -f "$previous" ]; then
                mv -- "$previous" "$SUBSCRIPTION_CONFIG" || return 1
                if "$SUBSCRIPTION_TOOL" reload \
                    --controller "$EXTERNAL_CONTROLLER_ADDRESS:$UI_PORT" --path "$SUBSCRIPTION_CONFIG" \
                    >"$transaction/rollback-output" 2>"$transaction/rollback-error"; then
                    subscription_log 'reload failed; previous configuration restored and reloaded'
                else
                    subscription_log 'reload and rollback failed; previous file restored, running state must be checked'
                fi
            else
                subscription_log 'reload failed and no previous configuration file is available'
            fi
            return 1
        fi
    fi

    # Cache only successfully classified and validated input; never cache the
    # container overlay instead of the original provider configuration.
    for index in "${!checked_names[@]}"; do
        name="${checked_names[$index]}"
        hash="${checked_hashes[$index]}"
        cp -- "$transaction/$name.yaml" "$SUBSCRIPTION_DIR/cache/$name.$hash.yaml.new" || return 1
        mv -- "$SUBSCRIPTION_DIR/cache/$name.$hash.yaml.new" "$SUBSCRIPTION_DIR/cache/$name.$hash.yaml" || return 1
    done
    printf '%s\n' "${selected:-template}" > "$transaction/active"
    previous="$(cat "$SUBSCRIPTION_DIR/active" 2>/dev/null || true)"
    mv -- "$transaction/active" "$SUBSCRIPTION_DIR/active" || return 1
    if [ "$selected" != '' ]; then
        if [ "$previous" != "$selected" ] || [ "$changed" = 1 ]; then
            subscription_log "$selected is the main configuration; container settings retained"
            subscription_log 'other subscription configurations and standalone nodes are not merged into it'
        fi
    elif [ "$previous" != template ] || [ "$changed" = 1 ]; then
        subscription_log 'node-only subscriptions use the container template and its rules'
    fi
)

subscription_prepare() {
    local base_temp
    SUBSCRIPTION_TOOL="${SUBSCRIPTION_TOOL:-prizrak-config}"
    SUBSCRIPTION_DIR="$WORKDIR/subscriptions"
    SUBSCRIPTION_BASE="$SUBSCRIPTION_DIR/base.yaml"
    SUBSCRIPTION_CONFIG="$2"
    SUBSCRIPTION_TIMEOUT="${SUBSCRIPTION_TIMEOUT:-30}"
    SUBSCRIPTION_INTERVAL="${SUBSCRIPTION_INTERVAL:-${PROVIDER_INTERVAL:-3600}}"
    [[ "$SUBSCRIPTION_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$SUBSCRIPTION_TIMEOUT" -gt 0 ] \
        || { subscription_log 'SUBSCRIPTION_TIMEOUT must be a positive number of seconds'; return 1; }
    [[ "$SUBSCRIPTION_INTERVAL" =~ ^[0-9]+$ ]] \
        || { subscription_log 'SUBSCRIPTION_INTERVAL must be a non-negative number of seconds'; return 1; }
    command -v "$SUBSCRIPTION_TOOL" >/dev/null \
        || { subscription_log 'configuration helper is missing; rebuild the image'; return 1; }
    mkdir -p "$SUBSCRIPTION_DIR/cache" || return 1
    chmod 0700 "$SUBSCRIPTION_DIR" "$SUBSCRIPTION_DIR/cache" || return 1
    base_temp="$(mktemp "$SUBSCRIPTION_DIR/.base.XXXXXX")" || return 1
    if ! cp -- "$1" "$base_temp" || ! chmod 0600 "$base_temp" \
        || ! mv -- "$base_temp" "$SUBSCRIPTION_BASE"; then
        rm -f -- "$base_temp"
        return 1
    fi
    subscription_update 0
}

subscription_start_updater() {
    local parent_pid="$1"
    [ "$SUBSCRIPTION_INTERVAL" -gt 0 ] || return 0
    (
        while sleep "$SUBSCRIPTION_INTERVAL"; do
            kill -0 "$parent_pid" 2>/dev/null || exit 0
            if ! subscription_update 1; then
                subscription_log 'update failed; the last configuration file was retained'
            fi
        done
    ) &
    subscription_log "configuration refresh interval: ${SUBSCRIPTION_INTERVAL}s"
}
