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

ch05() {
    fresh ch05
    git init -q -b main .
    printf 'hello\n' > hello.txt
    oid=$("$zgit" hash-object -w hello.txt)
    eq "$(git cat-file -t "$oid")" blob "git reads type of zgit blob"
    eq "$(git cat-file -p "$oid")" hello "git reads content of zgit blob"

    printf 'from git\n' > g.txt
    oid=$(git hash-object -w g.txt)
    eq "$("$zgit" cat-file -t "$oid")" blob "zgit reads type of git blob"
    eq "$("$zgit" cat-file -s "$oid")" 9 "zgit reads size of git blob"
    eq "$("$zgit" cat-file -p "$oid")" "from git" "zgit reads content of git blob"
    fsck_clean
}

ch06() {
    fresh ch06
    git init -q -b main .
    mkdir -p src/deep
    printf 'hello\n' > hello.txt
    printf 'const x = 1;\n' > src/main.zig
    printf 'deep\n' > src/deep/d.txt
    printf '#!/bin/sh\n' > run.sh && chmod +x run.sh
    ln -s hello.txt link
    mkdir empty

    git add -A
    tree=$("$zgit" write-tree)
    eq "$tree" "$(git write-tree)" "write-tree agrees with git (nested, exec bit, symlink, empty dir)"
    eq "$("$zgit" ls-tree "$tree")" "$(git ls-tree "$tree")" "ls-tree agrees"
    eq "$("$zgit" ls-tree -r "$tree")" "$(git ls-tree -r "$tree")" "ls-tree -r agrees"
    eq "$("$zgit" cat-file -p "$tree")" "$(git cat-file -p "$tree")" "cat-file -p on a tree agrees"
    fsck_clean
}

chapters=(03 04 05 06)
if [ $# -gt 0 ]; then chapters=("$@"); fi
for c in "${chapters[@]}"; do
    echo "# chapter $c"
    "ch$c"
done
echo "all good"
