#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi

set -u
setopt pipefail
setopt null_glob

readonly current_app_id="com.flat.x.decode"
readonly current_finder_id="com.flat.x.decode.FinderSync"
readonly legacy_app_id="com.lingxiang.XDecode"
readonly legacy_finder_id="com.lingxiang.XDecode.FinderSync"
readonly lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly script_name="${0:t}"

dry_run=0
typeset -a requested_apps
typeset -a app_candidates
typeset -a extension_candidates
typeset -A seen_apps
typeset -A seen_extensions

usage() {
    print -r -- "用法: $script_name [--dry-run] [--app /path/to/XDecode.app]"
    print -r -- ""
    print -r -- "  --dry-run    只显示将执行的操作"
    print -r -- "  --app PATH   增加一个需要卸载的 XDecode.app 路径，可重复使用"
    print -r -- "  --help       显示帮助"
}

log() {
    print -r -- "[XDecode] $*"
}

warn() {
    print -ru2 -- "[XDecode] 警告: $*"
}

print_command() {
    printf "+"
    local argument
    for argument in "$@"; do
        printf " %q" "$argument"
    done
    printf "\n"
}

run() {
    if (( dry_run )); then
        print_command "$@"
        return 0
    fi
    "$@"
}

run_silently() {
    if (( dry_run )); then
        print_command "$@"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

bundle_identifier() {
    local bundle_path="$1"
    local plist_path="$bundle_path/Contents/Info.plist"
    [[ -f "$plist_path" ]] || return 1
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2>/dev/null
}

is_main_app_identifier() {
    [[ "$1" == "$current_app_id" || "$1" == "$legacy_app_id" ]]
}

is_finder_identifier() {
    [[ "$1" == "$current_finder_id" || "$1" == "$legacy_finder_id" ]]
}

add_app_candidate() {
    local candidate="$1"
    [[ -d "$candidate" && "$candidate" == *.app ]] || return 0

    candidate="${candidate:A}"
    local identifier
    identifier="$(bundle_identifier "$candidate")" || return 0
    is_main_app_identifier "$identifier" || return 0
    [[ -z "${seen_apps[$candidate]-}" ]] || return 0

    seen_apps[$candidate]=1
    app_candidates+=("$candidate")
}

add_extension_candidate() {
    local candidate="$1"
    [[ -d "$candidate" && "$candidate" == *.appex ]] || return 0

    candidate="${candidate:A}"
    local identifier
    identifier="$(bundle_identifier "$candidate")" || return 0
    is_finder_identifier "$identifier" || return 0
    [[ -z "${seen_extensions[$candidate]-}" ]] || return 0

    seen_extensions[$candidate]=1
    extension_candidates+=("$candidate")
}

safe_remove_user_library_path() {
    local target="$1"
    local user_library_path="$2"
    [[ "$target" == "$user_library_path/"* ]] || {
        warn "拒绝删除用户 Library 之外的路径: $target"
        return 1
    }
    [[ "$target" != "$user_library_path" ]] || {
        warn "拒绝删除整个用户 Library"
        return 1
    }
    [[ -e "$target" || -L "$target" ]] || return 0
    run /bin/rm -rf -- "$target"
}

safe_remove_tmp_path() {
    local target="$1"
    case "$target" in
        /private/tmp/XDecode*|/private/tmp/xdecode*) ;;
        *)
            warn "拒绝删除非 XDecode 临时路径: $target"
            return 1
            ;;
    esac
    [[ -e "$target" || -L "$target" ]] || return 0
    run /bin/rm -rf -- "$target"
}

remove_verified_app() {
    local app_path="$1"
    local identifier
    identifier="$(bundle_identifier "$app_path")" || {
        warn "无法再次校验 App，跳过删除: $app_path"
        return 1
    }
    is_main_app_identifier "$identifier" || {
        warn "Bundle ID 不属于 XDecode，跳过删除: $app_path"
        return 1
    }

    if (( dry_run )); then
        print_command /bin/rm -rf -- "$app_path"
    elif [[ -w "${app_path:h}" ]]; then
        /bin/rm -rf -- "$app_path"
    else
        log "删除 $app_path 需要管理员权限"
        /usr/bin/sudo /bin/rm -rf -- "$app_path"
    fi
}

unregister_login_item_with_app() {
    local app_path="$1"
    local executable_name
    executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
        "$app_path/Contents/Info.plist" 2>/dev/null)" || return 1
    local executable="$app_path/Contents/MacOS/$executable_name"
    [[ -x "$executable" ]] || return 1

    if (( dry_run )); then
        print_command "$executable" \
            -launchAtLoginEnabled NO \
            -automaticEnabled NO \
            -notificationsEnabled NO \
            -defaultDownloadsMonitoringEnabled NO \
            /dev/null
        return 0
    fi

    log "通过 App 自身注销开机自启动: $app_path"
    "$executable" \
        -launchAtLoginEnabled NO \
        -automaticEnabled NO \
        -notificationsEnabled NO \
        -defaultDownloadsMonitoringEnabled NO \
        /dev/null >/dev/null 2>&1 &
    local process_id=$!
    /bin/sleep 2
    /bin/kill -TERM "$process_id" >/dev/null 2>&1 || true
    wait "$process_id" >/dev/null 2>&1 || true
}

remove_system_events_login_item() {
    local item_name="$1"
    local apple_script="tell application \"System Events\" to if exists login item \"$item_name\" then delete login item \"$item_name\""
    if (( dry_run )); then
        print_command /usr/bin/osascript -e "$apple_script"
        return 0
    fi
    /usr/bin/osascript -e "$apple_script" >/dev/null 2>&1
}

while (( $# > 0 )); do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --yes)
            shift
            ;;
        --app)
            (( $# >= 2 )) || {
                warn "--app 缺少路径"
                usage
                exit 2
            }
            requested_apps+=("$2")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            warn "未知参数: $1"
            usage
            exit 2
            ;;
    esac
done

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
    warn "此脚本仅支持 macOS"
    exit 1
}

(( EUID != 0 )) || {
    warn "请使用当前登录用户运行脚本，不要对整个脚本使用 sudo"
    exit 1
}

readonly user_home="${HOME:?无法确定用户主目录}"
readonly user_library="$user_home/Library"
readonly derived_data_root="$user_library/Developer/Xcode/DerivedData"

add_app_candidate "/Applications/XDecode.app"
add_app_candidate "/Applications/X-Decode.app"
add_app_candidate "$user_home/Applications/XDecode.app"
add_app_candidate "$user_home/Applications/X-Decode.app"

candidate=""
for candidate in "${requested_apps[@]}"; do
    [[ -d "$candidate" ]] || {
        warn "--app 路径不存在: $candidate"
        exit 2
    }
    count_before=${#app_candidates[@]}
    add_app_candidate "$candidate"
    (( ${#app_candidates[@]} > count_before )) || {
        warn "--app 不是受支持的 XDecode App: $candidate"
        exit 2
    }
done

if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r candidate; do
        add_app_candidate "$candidate"
    done < <(/usr/bin/find "$derived_data_root" -maxdepth 7 -type d \
        \( -name "XDecode.app" -o -name "X-Decode.app" \) -prune -print 2>/dev/null)
fi

while IFS= read -r candidate; do
    add_app_candidate "$candidate"
done < <(/usr/bin/find /private/tmp -maxdepth 8 -type d \
    \( -name "XDecode.app" -o -name "X-Decode.app" \) -prune -print 2>/dev/null)

app_path=""
for app_path in "${app_candidates[@]}"; do
    add_extension_candidate "$app_path/Contents/PlugIns/XDecodeFinder.appex"
done

if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r candidate; do
        add_extension_candidate "$candidate"
    done < <(/usr/bin/find "$derived_data_root" -maxdepth 7 -type d \
        -name "XDecodeFinder.appex" -prune -print 2>/dev/null)
fi

while IFS= read -r candidate; do
    add_extension_candidate "$candidate"
done < <(/usr/bin/find /private/tmp -maxdepth 8 -type d \
    -name "XDecodeFinder.appex" -prune -print 2>/dev/null)

log "发现 ${#app_candidates[@]} 个 App 副本、${#extension_candidates[@]} 个 Finder 扩展副本"

run_silently /usr/bin/pkill -x XDecode || true
run_silently /usr/bin/pkill -x XDecodeFinder || true

typeset -A unregistered_app_ids
for app_path in "${app_candidates[@]}"; do
    identifier="$(bundle_identifier "$app_path")" || continue
    [[ -z "${unregistered_app_ids[$identifier]-}" ]] || continue
    if unregister_login_item_with_app "$app_path"; then
        unregistered_app_ids[$identifier]=1
    fi
done

if (( ${#app_candidates[@]} == 0 )); then
    remove_system_events_login_item "XDecode" || \
        warn "无法自动检查名为 XDecode 的系统登录项，请在“系统设置 > 通用 > 登录项与扩展”中确认"
    remove_system_events_login_item "X-Decode" || true
fi

run_silently /usr/bin/pkill -x XDecode || true
run_silently /usr/bin/pkill -x XDecodeFinder || true

typeset -A reset_tcc_ids
for app_path in "${app_candidates[@]}"; do
    identifier="$(bundle_identifier "$app_path")" || continue
    if [[ -z "${reset_tcc_ids[$identifier]-}" ]]; then
        run_silently /usr/bin/tccutil reset All "$identifier" || true
        reset_tcc_ids[$identifier]=1
    fi
    run_silently "$lsregister" -u "$app_path" || true
done

extension_path=""
for extension_path in "${extension_candidates[@]}"; do
    run_silently /usr/bin/pluginkit -r "$extension_path" || true
done

for app_path in "${app_candidates[@]}"; do
    remove_verified_app "$app_path" || warn "未能删除 App: $app_path"
done

if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r candidate; do
        [[ "${candidate:t}" == XDecode-* ]] || continue
        safe_remove_user_library_path "$candidate" "$user_library" || \
            warn "未能删除 DerivedData: $candidate"
    done < <(/usr/bin/find "$derived_data_root" -maxdepth 1 -type d \
        -name "XDecode-*" -print 2>/dev/null)
fi

typeset -a tmp_roots
tmp_roots=(
    /private/tmp/XDecode*DerivedData
    /private/tmp/XDecodeReleaseBuild-*
    /private/tmp/XDecodeDMGStage-*
    /private/tmp/XDecodeAdHocStage-*
    /private/tmp/xdecode-build
    /private/tmp/xdecode-swift-module-cache
    /private/tmp/xdecode-test-clang-cache
    /private/tmp/XDecodeSwiftModuleCache
    /private/tmp/xdecode-clang-cache
    /private/tmp/xdecode-clang-test-module-cache
    /private/tmp/xdecode-clang-module-cache
    /private/tmp/xdecode-icon-clang-cache
    /private/tmp/xdecode-swiftpm-cache
    /private/tmp/XDecodeSwiftPMModuleCache
    /private/tmp/xdecode-ncprefs.plist
)
tmp_path=""
for tmp_path in "${tmp_roots[@]}"; do
    safe_remove_tmp_path "$tmp_path" || warn "未能删除临时路径: $tmp_path"
done

typeset -a all_bundle_ids
all_bundle_ids=(
    "$current_app_id"
    "$current_finder_id"
    "$legacy_app_id"
    "$legacy_finder_id"
)

identifier=""
for identifier in "${all_bundle_ids[@]}"; do
    run_silently /usr/bin/defaults delete "$identifier" || true

    container_path="$user_library/Containers/$identifier"
    safe_remove_user_library_path "$container_path/Data" "$user_library" || true
    if (( dry_run )); then
        [[ -e "$container_path" ]] && print_command /bin/rm -rf -- "$container_path"
    else
        /bin/rm -rf -- "$container_path" >/dev/null 2>&1 || true
    fi

    typeset -a identifier_paths
    identifier_paths=(
        "$user_library/Application Scripts/$identifier"
        "$user_library/Application Support/$identifier"
        "$user_library/Caches/$identifier"
        "$user_library/HTTPStorages/$identifier"
        "$user_library/Logs/$identifier"
        "$user_library/Preferences/$identifier.plist"
        "$user_library/Saved Application State/$identifier.savedState"
        "$user_library/WebKit/$identifier"
        "$user_library/Cookies/$identifier.binarycookies"
        "$user_library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$identifier.sfl3"
    )
    data_path=""
    for data_path in "${identifier_paths[@]}"; do
        safe_remove_user_library_path "$data_path" "$user_library" || \
            warn "未能删除数据路径: $data_path"
    done
done

typeset -a app_group_ids
app_group_ids=(
    "group.com.flat.x.decode"
    "group.com.lingxiang.XDecode"
    "32MTP8HP59.com.flat.x.decode"
)
group_id=""
for group_id in "${app_group_ids[@]}"; do
    safe_remove_user_library_path "$user_library/Group Containers/$group_id" "$user_library" || true
    safe_remove_user_library_path "$user_library/Application Scripts/$group_id" "$user_library" || true
done

typeset -a keychain_services
keychain_services=(
    "com.flat.x.decode.xlog"
    "com.flat.x.decode.logan"
    "com.lingxiang.XDecode.xlog"
    "com.lingxiang.XDecode.logan"
)
service=""
for service in "${keychain_services[@]}"; do
    if (( dry_run )); then
        print_command /usr/bin/security delete-generic-password -s "$service"
        continue
    fi
    while /usr/bin/security delete-generic-password -s "$service" >/dev/null 2>&1; do
        :
    done
done

readonly diagnostic_reports="$user_library/Logs/DiagnosticReports"
if [[ -d "$diagnostic_reports" ]]; then
    while IFS= read -r report_path; do
        safe_remove_user_library_path "$report_path" "$user_library" || true
    done < <(/usr/bin/find "$diagnostic_reports" -maxdepth 1 -type f \
        \( -name "XDecode_*.crash" -o -name "XDecode_*.ips" \
        -o -name "XDecodeFinder_*.crash" -o -name "XDecodeFinder_*.ips" \) \
        -print 2>/dev/null)
fi

run_silently "$lsregister" -gc || true
run_silently /usr/bin/killall backgroundtaskmanagementagent || true
run_silently /usr/bin/killall sharedfilelistd || true
run_silently /usr/bin/killall Finder || true

if (( dry_run )); then
    log "演练完成，未修改任何文件或系统注册"
else
    log "卸载完成"
    print -r -- "macOS 可能保留仅含 .com.apple.containermanagerd.metadata.plist 的空容器目录；"
    print -r -- "其中不含设置、历史或密钥，不会影响下次首次初始化。"
fi
