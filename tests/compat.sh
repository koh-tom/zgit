#!/usr/bin/env bash
# zgit と本物の git を交互に使って、同じ結果になるか確かめる。
#
#   zig build && tests/compat.sh        # 全章
#   tests/compat.sh 05                  # 第5章だけ
#   ZGIT=path/to/zgit tests/compat.sh   # 別の場所にある zgit を試す
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
zgit=${ZGIT:-$root/zig-out/bin/zgit}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 出力を固定するため、作者と日時は環境変数で与える
export GIT_AUTHOR_NAME="Z Giter" GIT_AUTHOR_EMAIL="z@example.com"
export GIT_COMMITTER_NAME="Z Giter" GIT_COMMITTER_EMAIL="z@example.com"
export GIT_AUTHOR_DATE="1700000000 +0900" GIT_COMMITTER_DATE="1700000000 +0900"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] && ok "$3" || { echo "  want: $2"; echo "  got:  $1"; fail "$3"; }; }
fsck_clean() { git fsck --strict >/dev/null 2>&1 || fail "git fsck --strict"; ok "fsck is clean"; }

fresh() {
    rm -rf "${work:?}/$1" && mkdir -p "$work/$1" && cd "$work/$1"
}

ch03() {
    fresh ch03
    "$zgit" init >/dev/null
    eq "$(git rev-parse --is-inside-work-tree)" true "git recognizes a zgit repository"
    eq "$(git symbolic-ref HEAD)" refs/heads/main "HEAD points to main"
}

ch04() {
    fresh ch04
    printf 'hello\n' > hello.txt
    eq "$("$zgit" hash-object hello.txt)" "$(git hash-object hello.txt)" "hash-object agrees"
    head -c 100000 /dev/urandom > big.bin
    eq "$("$zgit" hash-object big.bin)" "$(git hash-object big.bin)" "hash-object agrees on binary"
}

chapters=(03 04)
if [ $# -gt 0 ]; then chapters=("$@"); fi
for c in "${chapters[@]}"; do
    echo "# chapter $c"
    "ch$c"
done
echo "all good"
