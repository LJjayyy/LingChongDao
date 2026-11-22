import CryptoKit
import Darwin
import Foundation
import Security

struct KeepAwakeHelperInstallation {
    let source: URL
    let digest: String
    private static let maximumSize = 4 * 1024 * 1024

    private static func sha256(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumSize,
              let data = try? handle.read(upToCount: maximumSize + 1),
              data.count == info.st_size else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bundled() -> Self? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingchongdao-keepawake")
        guard let digest = sha256(url) else { return nil }
        // Tie the candidate bytes to the Info.plist sealed by this running app,
        // including ad-hoc local builds. Signing the helper alone cannot do that.
        var code: SecCode?
        var requirement: SecRequirement?
        let condition = "info[LingChongDaoKeepAwakeHelperSHA256] = \"\(digest)\""
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(condition as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return .init(source: url, digest: digest)
    }

    func brokerCommand(directory: URL, appPID: Int32, uid: uid_t) -> String {
        let quote = ClamshellGuardCommand.quote
        return """
        set -eu
        umask 077
        export LC_ALL=C
        cd /
        temporary_root=/private/tmp
        no_acl() { /bin/ls -lde "$1" | /usr/bin/awk 'END { exit (NR != 1) }'; }
        [ -d /private ] && [ ! -L /private ] || exit 1
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' /private)" = '0:0:755' ]
        no_acl /private
        [ -d "$temporary_root" ] && [ ! -L "$temporary_root" ] && [ -k "$temporary_root" ] || exit 1
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$temporary_root")" = '0:0:777' ]
        no_acl "$temporary_root"
        stage="$(/usr/bin/mktemp -d "$temporary_root/LingChongDao-RootBroker.XXXXXXXX")"
        helper="$stage/keepawake"
        cleanup() {
            /bin/rm -f "$helper"
            /bin/rmdir "$stage"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        [ "$(/usr/bin/stat -f '%u:%Lp' "$stage")" = '0:700' ]
        no_acl "$stage"
        # Read the bundle with the caller's permissions. Validate the open
        # descriptor before copying so a replaced path cannot block on a FIFO.
        /usr/bin/sudo -n -u '#\(uid)' -- /usr/bin/env -i LC_ALL=C /usr/bin/perl -MFcntl=:DEFAULT -e '
            sysopen(my $file, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
            my @info = stat($file);
            -f $file && $info[7] > 0 && $info[7] <= \(Self.maximumSize) or exit 1;
            my $count = read($file, my $bytes, \(Self.maximumSize + 1));
            defined($count) && $count == $info[7] or exit 1;
            print STDOUT $bytes or exit 1;
        ' -- \(quote(source.path)) > "$helper"
        actual="$(/usr/bin/env -i LC_ALL=C /usr/bin/shasum -a 256 < "$helper" | /usr/bin/awk '{print $1}')"
        [ "$actual" = \(quote(digest)) ]
        /bin/chmod 500 "$helper"
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C "$helper" broker \(uid) \(appPID) \(quote(directory.path))
        """
    }
}
