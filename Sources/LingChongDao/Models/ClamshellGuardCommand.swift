import Darwin
import Foundation

enum ClamshellGuardSecurityPolicy {
    case production
    /// Only injectable tests may select a non-root fixture tree.
    case fixture(owner: uid_t, group: gid_t)
    var owner: uid_t { switch self { case .production: return 0; case .fixture(let owner, _): return owner } }
    var group: gid_t { switch self { case .production: return 0; case .fixture(_, let group): return group } }
}

struct ClamshellGuardCommand {
    static let productionRoot = URL(fileURLWithPath: "/private/var/db/lingchongdao-keepawake", isDirectory: true)
    let appProcessID: Int32
    let userID: uid_t
    let token: String
    let directoryURL: URL // Client-owned input only; root must never write here.
    var persistentRootURL: URL = productionRoot
    var securityPolicy: ClamshellGuardSecurityPolicy = .production
    var pmsetExecutable = "/usr/bin/pmset"
    var processIsAliveExecutable = "/bin/kill"
    var sleepExecutable = "/bin/sleep"
    var bootSessionExecutable = "/usr/sbin/sysctl"
    var processStartExecutable = "/bin/ps"
    var recoveryNames: [String]? = nil
    var sessionName: String { "u\(userID)-\(token)" }
    var recordURL: URL { persistentRootURL.appendingPathComponent(sessionName, isDirectory: true) }
    var readyFileURL: URL { recordURL.appendingPathComponent("ready") }
    var stopFileURL: URL { directoryURL.appendingPathComponent("stop") }
    var doneFileURL: URL { recordURL.appendingPathComponent("done") }
    var failedFileURL: URL { recordURL.appendingPathComponent("restore-failed") }
    var originalZeroURL: URL { recordURL.appendingPathComponent("original-0") }
    var originalOneURL: URL { recordURL.appendingPathComponent("original-1") }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func validSessionName(_ value: String, userID: uid_t) -> Bool {
        let prefix = "u\(userID)-"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix) != nil
    }

    /// All writes target a fixed root-controlled tree. The only user-owned path
    /// passed to the privileged watcher is a stop input that is never written.
    var watcherCommand: String {
        guard Self.validSessionName(sessionName, userID: userID) else { return "exit 1" }
        let q = Self.quote
        let ancestors: String
        switch securityPolicy {
        case .production:
            ancestors = "[ \(q(persistentRootURL.path)) = '/private/var/db/lingchongdao-keepawake' ] || exit 1\nfor parent in /private /private/var /private/var/db; do safe_directory \"$parent\" || exit 1; done"
        case .fixture: ancestors = ": # Injected test tree; never used by the live backend."
        }
        let common = """
        umask 077
        set -C
        root=\(q(persistentRootURL.path))
        expected_owner=\(securityPolicy.owner)
        expected_group=\(securityPolicy.group)
        app_uid=\(userID)
        pmset=\(q(pmsetExecutable))
        safe_directory() {
            [ -d "$1" ] && [ ! -L "$1" ] || return 1
            attrs="$(/usr/bin/stat -f '%u:%g:%Lp' "$1")" || return 1
            owner="${attrs%%:*}"; rest="${attrs#*:}"; group="${rest%%:*}"; mode="${rest##*:}"
            [ "$owner" = "$expected_owner" ] && [ "$group" = "$expected_group" ] || return 1
            case "$mode" in ''|*[!0-7]*) return 1 ;; esac
            [ $((0$mode & 0022)) = 0 ]
        }
        safe_file() {
            [ -f "$1" ] && [ ! -L "$1" ] || return 1
            attrs="$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$1")" || return 1
            owner="${attrs%%:*}"; rest="${attrs#*:}"; group="${rest%%:*}"; rest="${rest#*:}"; mode="${rest%%:*}"; links="${rest##*:}"
            [ "$owner" = "$expected_owner" ] && [ "$group" = "$expected_group" ] && [ "$links" = 1 ] || return 1
            case "$mode" in ''|*[!0-7]*) return 1 ;; esac
            [ $((0$mode & 0022)) = 0 ]
        }
        read_state() {
            output="$("$pmset" -g 2>/dev/null)" || return 1
            printf '%s\\n' "$output" | /usr/bin/awk '$1 == "SleepDisabled" { if (NF < 2 || ($2 != "0" && $2 != "1")) bad=1; else { value=$2; count++ } } END { if (!bad && count == 1) print value; else exit 1 }'
        }
        mark() {
            if [ -e "$record/$1" ] || [ -L "$record/$1" ]; then safe_file "$record/$1"; else : > "$record/$1"; fi
        }
        write_value() {
            (umask 022; printf '%s\\n' "$2" > "$record/$1")
        }
        cleanup_record() {
            # Only fixed names under a validated, non-user-writable directory.
            safe_directory "$record" || return 1
            for name in uid token owner-pid watcher-pid boot-id owner-start original-0 original-1 changed-intent ready restore-failed done; do
                if [ -e "$record/$name" ] || [ -L "$record/$name" ]; then
                    safe_file "$record/$name" || return 1
                    /bin/rm -f "$record/$name" || return 1
                fi
            done
            /bin/rmdir "$record"
        }
        \(ancestors)
        """
        if let recoveryNames {
            let recover = recoveryNames.filter { Self.validSessionName($0, userID: userID) }
            guard recover.count == recoveryNames.count else { return "exit 1" }
            return common + "\n" + """
            safe_directory "$root" || exit 1
            [ "$(/usr/bin/stat -f '%Lp' "$root")" = 755 ] || exit 1
            result=0
            for session_name in \(recover.map(q).joined(separator: " ")); do
                record="$root/$session_name"
                safe_directory "$record" || { result=1; continue; }
                [ "$(/usr/bin/stat -f '%Lp' "$record")" = 755 ] || { result=1; continue; }
                # Preparations without write intent cannot own a power change.
                # Leave them untouched; inspection never treats them as recovery work.
                if [ ! -e "$record/changed-intent" ] && [ ! -L "$record/changed-intent" ]; then continue; fi
                for name in uid token owner-pid boot-id owner-start; do safe_file "$record/$name" || exit 1; done
                [ "$(/bin/cat "$record/uid")" = "$app_uid" ] || exit 1
                [ "$session_name" = "u$app_uid-$(/bin/cat "$record/token")" ] || exit 1
                owner_pid="$(/bin/cat "$record/owner-pid")"
                case "$owner_pid" in ''|*[!0-9]*) exit 1 ;; esac
                # A numeric PID may be reused after reboot or process exit.
                # Only the same boot and start identity denotes another active app.
                if [ "$owner_pid" != \(appProcessID) ] && \(q(processIsAliveExecutable)) -0 "$owner_pid" 2>/dev/null; then
                    current_boot="$(\(q(bootSessionExecutable)) -n kern.bootsessionuuid)" || exit 1
                    recorded_boot="$(/bin/cat "$record/boot-id")"
                    if [ "$recorded_boot" = "$current_boot" ]; then
                        current_start="$(\(q(processStartExecutable)) -p "$owner_pid" -o lstart=)" || current_start=''
                        if [ -n "$current_start" ] && [ "$current_start" = "$(/bin/cat "$record/owner-start")" ]; then result=1; continue; fi
                    fi
                fi
                if [ -e "$record/done" ]; then safe_file "$record/done" || exit 1; continue; fi
                if [ -e "$record/changed-intent" ]; then
                    safe_file "$record/changed-intent" && safe_file "$record/original-0" || { result=1; continue; }
                    [ ! -e "$record/original-1" ] || { result=1; continue; }
                    current="$(read_state)" || current=unknown
                    if [ "$current" != 0 ]; then "$pmset" -a disablesleep 0 >/dev/null 2>&1 || { result=1; continue; }; fi
                    [ "$(read_state)" = 0 ] || { result=1; continue; }
                else
                    # No write intent means this session never owned a global change.
                    # Original one must be preserved even when global state changed.
                    if [ -e "$record/original-1" ]; then safe_file "$record/original-1" || { result=1; continue; }; fi
                fi
                mark done || { result=1; continue; }
                # Leave trusted evidence for a live watcher to finish its own trap.
                watcher_pid="$(/bin/cat "$record/watcher-pid" 2>/dev/null)"
                case "$watcher_pid" in ''|*[!0-9]*) cleanup_record || result=1 ;;
                    *) if ! \(q(processIsAliveExecutable)) -0 "$watcher_pid" 2>/dev/null; then cleanup_record || result=1; fi ;;
                esac
            done
            exit "$result"
            """
        }
        return common + "\n" + """
        if [ -e "$root" ] || [ -L "$root" ]; then safe_directory "$root" || exit 1; else /bin/mkdir -m 755 "$root" || exit 1; fi
        [ "$(/usr/bin/stat -f '%Lp' "$root")" = 755 ] || exit 1
        record="$root/\(sessionName)"
        /bin/mkdir -m 755 "$record" || exit 1
        safe_directory "$record" || exit 1
        stop=\(q(stopFileURL.path))
        original=''
        changed=0
        restore() {
            if [ "$original" = 0 ] && [ "$changed" = 1 ]; then
                current="$(read_state)" || current=unknown
                if [ "$current" != 0 ]; then "$pmset" -a disablesleep 0 >/dev/null 2>&1 || return 1; fi
                [ "$(read_state)" = 0 ] || return 1
            fi
            mark done
        }
        finish() {
            trap '' HUP INT TERM
            while ! restore; do mark restore-failed 2>/dev/null; \(q(sleepExecutable)) 1; done
            # A short grace period lets the client observe done; it cannot delete evidence.
            \(q(sleepExecutable)) 2
            cleanup_record
        }
        trap finish EXIT
        trap 'exit 1' HUP INT TERM
        write_value uid "$app_uid" || exit 1
        write_value token \(q(token)) || exit 1
        write_value owner-pid \(q(String(appProcessID))) || exit 1
        write_value watcher-pid "$$" || exit 1
        boot_id="$(\(q(bootSessionExecutable)) -n kern.bootsessionuuid)" || exit 1
        owner_start="$(\(q(processStartExecutable)) -p \(appProcessID) -o lstart=)" || exit 0
        [ -n "$boot_id" ] && [ -n "$owner_start" ] || exit 0
        write_value boot-id "$boot_id" || exit 1
        write_value owner-start "$owner_start" || exit 1
        [ -e "$stop" ] && exit 0
        \(q(processIsAliveExecutable)) -0 \(appProcessID) 2>/dev/null || exit 0
        original="$(read_state)" || exit 1
        case "$original" in 0|1) mark "original-$original" || exit 1 ;; *) exit 1 ;; esac
        [ -e "$stop" ] && exit 0
        \(q(processIsAliveExecutable)) -0 \(appProcessID) 2>/dev/null || exit 0
        if [ "$original" = 0 ]; then
            mark changed-intent || exit 1
            changed=1
            "$pmset" -a disablesleep 1 >/dev/null 2>&1 || exit 1
        fi
        [ "$(read_state)" = 1 ] || exit 1
        [ -e "$stop" ] && exit 0
        \(q(processIsAliveExecutable)) -0 \(appProcessID) 2>/dev/null || exit 0
        mark ready || exit 1
        while \(q(processIsAliveExecutable)) -0 \(appProcessID) 2>/dev/null; do
            [ -e "$stop" ] && break
            [ "$(read_state)" = 1 ] || break
            \(q(sleepExecutable)) 1
        done
        exit 0
        """
    }
    var appleScript: String {
        let escaped = watcherCommand.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "with timeout of 2147483647 seconds\n do shell script \"\(escaped)\" with administrator privileges\nend timeout"
    }
}
