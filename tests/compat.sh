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

ch07() {
    fresh ch07
    git init -q -b main .
    printf 'hello\n' > hello.txt
    git add hello.txt
    tree=$("$zgit" write-tree)

    # 同じ tree・作者・日時なら、commit ID まで一致する
    c1=$("$zgit" commit-tree "$tree" -m "first commit")
    eq "$c1" "$(git commit-tree "$tree" -m "first commit")" "commit-tree produces the same id as git"
    eq "$(git cat-file -t "$c1")" commit "git reads zgit commit"
    eq "$(git log --oneline "$c1")" "${c1:0:7} first commit" "git log shows zgit commit"

    c2=$(git commit-tree "$tree" -p "$c1" -m "second")
    eq "$("$zgit" cat-file -p "$c2")" "$(git cat-file -p "$c2")" "zgit reads git commit"
    eq "$("$zgit" ls-tree "$c2")" "$(git ls-tree "$c2")" "ls-tree peels a commit to its tree"
    c3=$("$zgit" commit-tree "$tree" -p "$c1" -p "$c2" -m "merge")
    eq "$(git cat-file -p "$c3" | grep -c '^parent ')" 2 "two parents"
    fsck_clean
}

ch08() {
    fresh ch08
    "$zgit" init >/dev/null
    printf 'a\n' > a.txt
    git add a.txt
    tree=$("$zgit" write-tree)
    c1=$("$zgit" commit-tree "$tree" -m "first")
    "$zgit" update-ref HEAD "$c1"
    eq "$(cat .git/refs/heads/main)" "$c1" "update-ref HEAD writes the branch file"
    eq "$(git rev-parse HEAD)" "$c1" "git resolves HEAD written by zgit"

    printf 'b\n' > b.txt
    git add b.txt
    tree=$("$zgit" write-tree)
    c2=$(GIT_AUTHOR_DATE="1700000100 +0900" GIT_COMMITTER_DATE="1700000100 +0900" \
        "$zgit" commit-tree "$tree" -p HEAD -m "$(printf 'second\n\nwith body')")
    "$zgit" update-ref HEAD "$c2"
    eq "$("$zgit" rev-parse HEAD main refs/heads/main "${c2:0:7}")" "$(git rev-parse HEAD main refs/heads/main "${c2:0:7}")" "rev-parse agrees"
    eq "$("$zgit" log)" "$(git log)" "log agrees"
    eq "$("$zgit" log --oneline)" "$(git log --oneline)" "log --oneline agrees"
    eq "$("$zgit" cat-file -p HEAD)" "$(git cat-file -p HEAD)" "cat-file accepts HEAD"

    "$zgit" branch dev
    eq "$("$zgit" branch)" "$(git branch)" "branch listing agrees"
    eq "$(git rev-parse dev)" "$c2" "git sees the branch zgit created"
    git pack-refs --all
    eq "$("$zgit" rev-parse dev)" "$c2" "zgit reads packed-refs"
    eq "$("$zgit" branch)" "$(git branch)" "branch listing agrees after pack-refs"
    eq "$(git reflog | wc -l)" 2 "reflog has both updates"
    eq "$(sed -n 2p .git/logs/HEAD | cut -d' ' -f1,2)" "$c1 $c2" "reflog records old and new ids"
    fsck_clean
}

ch09() {
    fresh ch09
    git init -q -b main .
    mkdir -p src/deep
    printf 'hello\n' > hello.txt
    printf 'const x = 1;\n' > src/main.zig
    printf 'deep\n' > src/deep/d.txt
    printf '#!/bin/sh\n' > run.sh && chmod +x run.sh
    ln -s hello.txt link

    "$zgit" add hello.txt src run.sh link
    eq "$("$zgit" ls-files -s)" "$(git ls-files -s)" "ls-files -s agrees (git reads zgit index)"
    eq "$("$zgit" ls-files --debug)" "$(git ls-files --debug)" "stat data in the index agrees"
    eq "$(git status --porcelain | sort)" "$(printf 'A  hello.txt\nA  link\nA  run.sh\nA  src/deep/d.txt\nA  src/main.zig')" "git status sees staged files"
    eq "$("$zgit" write-tree)" "$(git write-tree)" "write-tree from zgit index matches"

    printf 'changed\n' > hello.txt
    (cd src && "$zgit" add ../hello.txt main.zig)
    eq "$(git diff --cached --stat | tail -1)" " 5 files changed, 5 insertions(+)" "add from a subdirectory"
    rm src/deep/d.txt
    "$zgit" add src
    eq "$(git ls-files src)" "$(printf 'src/main.zig')" "add a directory drops deleted files"

    git commit -q -m "from git"
    eq "$("$zgit" ls-files)" "$(git ls-files)" "zgit reads an index with the TREE extension"
    printf 'more\n' > more.txt && git add more.txt
    eq "$("$zgit" ls-files --debug)" "$(git ls-files --debug)" "zgit reads what git add wrote"
    "$zgit" add .
    eq "$(git status --porcelain)" "A  more.txt" "add . keeps git status consistent"
    rm more.txt && mkdir more.txt && printf 'x\n' > more.txt/inner
    "$zgit" add .
    eq "$("$zgit" ls-files | grep more)" "more.txt/inner" "a file replaced by a directory leaves one entry"
    fsck_clean
}

ch10() {
    fresh ch10
    "$zgit" init >/dev/null
    printf 'hello\n' > hello.txt
    mkdir src && printf 'const x = 1;\n' > src/main.zig
    "$zgit" add .
    "$zgit" commit -m "first commit" >/dev/null
    eq "$(git log --oneline)" "$(git rev-parse --short HEAD) first commit" "git log reads the zgit commit"
    eq "$(git status --porcelain)" "" "git status is clean after zgit commit"

    # 同じ内容・同じ日時なら git が作る commit と ID まで一致する
    git_id=$(cd "$work" && rm -rf ch10-git && mkdir ch10-git && cd ch10-git && git init -q -b main . &&
        printf 'hello\n' > hello.txt && mkdir src && printf 'const x = 1;\n' > src/main.zig &&
        git add . && git commit -q -m "first commit" && git rev-parse HEAD)
    eq "$(git rev-parse HEAD)" "$git_id" "commit id is identical to git's"

    printf 'changed\n' > hello.txt
    "$zgit" add hello.txt
    GIT_AUTHOR_DATE="1700000100 +0900" GIT_COMMITTER_DATE="1700000100 +0900" "$zgit" commit -m "second" >/dev/null
    eq "$("$zgit" log)" "$(git log)" "log agrees after two commits"
    eq "$(git reflog | sed 's/^[0-9a-f]* //')" "$(printf 'HEAD@{0}: commit: second\nHEAD@{1}: commit (initial): first commit')" "reflog matches git's wording"

    git commit -q --allow-empty -m "from git"
    printf 'third\n' > third.txt
    "$zgit" add third.txt
    "$zgit" commit -m "third" >/dev/null
    eq "$(git log --format=%s)" "$(printf 'third\nfrom git\nsecond\nfirst commit')" "git and zgit commits interleave"
    eq "$(git cat-file -p HEAD | grep -c '^parent')" 1 "parent is the git commit"
    "$zgit" commit -m "nothing" 2>/dev/null && fail "commit with no changes should fail"
    ok "nothing to commit is refused"
    fsck_clean
}

ch11() {
    fresh ch11
    git init -q -b main .
    printf 'hello\n' > hello.txt
    mkdir src && printf 'const x = 1;\n' > src/main.zig
    git add . && git commit -q -m "first commit"
    printf 'changed\n' > hello.txt && git add . && git commit -q -m "second"

    tree=$("$zgit" inspect HEAD)
    eq "$(echo "$tree" | head -1)" "HEAD -> refs/heads/main" "inspect starts from HEAD"
    eq "$(echo "$tree" | grep -c 'blob ')" 2 "inspect reaches every blob"
    eq "$(echo "$tree" | grep -c 'parent ')" 1 "inspect shows the parent"
    size=$(git cat-file -s HEAD)
    header=$(( 7 + ${#size} + 1 ))   # "commit <size>\0"
    eq "$("$zgit" inspect --raw HEAD | sed -n 4p)" "inflated $(( size + header )) bytes = header $header + commit $size" "inspect --raw explains the header"
    eq "$("$zgit" inspect --raw HEAD | sed -n 6p | cut -c1-8)" "00000000" "inspect --raw dumps bytes"
    eq "$("$zgit" inspect index | head -1 | cut -d, -f2-)" " version 2, 2 entries, checksum ok" "inspect index reads the header"
    eq "$("$zgit" inspect index | tail -1 | cut -d'(' -f1)" "extensions:  TREE " "inspect index lists extensions"

    # pack しか無いリポジトリは読めないが、unpack-objects で loose に戻せば読める
    git repack -a -d -q
    "$zgit" log >/dev/null 2>&1 && fail "zgit should not read packfiles yet"
    ok "packed objects are out of reach (as expected)"
    pack=$(ls .git/objects/pack/*.pack)
    mv "$pack" "$work/ch11.pack"
    git unpack-objects -q < "$work/ch11.pack"
    eq "$("$zgit" log --oneline)" "$(git log --oneline)" "zgit log works again after unpack-objects"
    fsck_clean
}

chapters=(03 04 05 06 07 08 09 10 11)
if [ $# -gt 0 ]; then chapters=("$@"); fi
for c in "${chapters[@]}"; do
    echo "# chapter $c"
    "ch$c"
done
echo "all good"
