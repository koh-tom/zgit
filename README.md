# zgit

Zig で書いた、本物の Git と相互運用できる最小の Git です。
技術書典21 で頒布する『Zigで学ぶ自作Git』のサンプルコードで、章ごとに機能を足していきます。

```
$ zgit init
$ echo hello > hello.txt
$ zgit add hello.txt
$ zgit commit -m "first commit"
[main (root-commit) 3996b91] first commit
$ git log --oneline        # 本物の git からも同じ履歴が見える
3996b91 first commit
```

zgit が書いたリポジトリは git がそのまま読めますし、git が書いたものも loose object であれば zgit で読めます。
作者と日時を揃えれば、commit の ID まで git と一致します (上の `3996b91` は、本の第7章にある環境変数で固定したときの値です)。

## 必要なもの

- Zig 0.17.1 (標準ライブラリの API がバージョンごとに変わるので、これ以外では動きません)
- Git 2.32 以降 (互換性の確認に使います)
- Linux (x86_64)。macOS と Windows は対象外です

[mise](https://mise.jdx.dev/) を使っている場合は `mise install` で Zig が入ります。

## ビルドと実行

```
zig build
./zig-out/bin/zgit version
```

`zig-out/bin` に PATH を通すか、`alias zgit=$PWD/zig-out/bin/zgit` しておくと本文の通りに打てます。

## テスト

```
zig build test          # 各モジュールの単体テスト
tests/compat.sh         # 本物の git と交互に使って結果を突き合わせる
tests/compat.sh 09      # 第9章の分だけ
```

## 章とブランチ

各章の終了時点のコードを、章番号のブランチ (`ch02`〜`ch11`) に置いてあります。
`git switch ch05` で第5章が終わった時点の zgit になり、`git diff origin/ch05 origin/ch06` で第6章の差分が読めます。

| 章 | ブランチ | 増えるもの |
|---|---|---|
| 2 | `ch02` | CLI の骨格、`zgit version` |
| 3 | `ch03` | `zgit init`、リポジトリの探索 |
| 4 | `ch04` | `Oid`、`zgit hash-object` |
| 5 | `ch05` | object database、zlib、`zgit cat-file`、`hash-object -w` |
| 6 | `ch06` | tree、`zgit ls-tree`、`zgit write-tree` |
| 7 | `ch07` | commit、`zgit commit-tree`、作者と日時 |
| 8 | `ch08` | ref と HEAD、`zgit update-ref` `rev-parse` `branch` `log` |
| 9 | `ch09` | index、`zgit add`、`zgit ls-files` |
| 10 | `ch10` | `zgit commit` (index から tree を作る) |
| 11 | `ch11` | `zgit inspect` |

`main` は第11章の状態に README と CI を足したものです。

### 本を読みながら進めるとき

自分のディレクトリで写経する場合は、このリポジトリを答え合わせ用に横に置いておくと便利です。

```
git clone https://github.com/koh-tom/zgit zgit-ref   # 答え合わせ用
mkdir zgit && cd zgit                                 # 自分で書く場所
mkdir tests && cp ../zgit-ref/tests/compat.sh tests/  # 互換性チェックだけ借りる
```

章を終えるごとに、次の 3 つを確かめます (第5章なら)。

```
zig build && zig build test
tests/compat.sh 05
git -C ../zgit-ref switch -q ch05 && diff -ru ../zgit-ref/src src
```

本文ではテストコードを一部しか載せていないので、`diff` にはテストの差が出ます。
写経せずに動かすだけなら、`git switch ch05 && zig build` でその章の zgit ができます。

## コードの地図

```
src/
  main.zig        コマンド名から実装を引いて呼ぶ
  cli.zig         コマンドに渡す Context と fatal()
  Repository.zig  .git と作業ツリーの場所
  Oid.zig         20 バイトの object ID
  object.zig      オブジェクトの種類、ヘッダ、ハッシュ、Object union
  zlib.zig        loose object の圧縮と展開
  odb.zig         object database (loose object の読み書き)
  Tree.zig        tree の解析と書き出し、並び順
  Commit.zig      commit の解析と書き出し
  date.zig        日時とタイムゾーン
  config.zig      user.name / user.email の取得
  ident.zig       commit に書く作者 (環境変数 → 設定ファイル)
  stat.zig        index 用の lstat (dev / uid / gid まで取る)
  refs.zig        ref、HEAD、packed-refs、reflog
  revision.zig    "HEAD" や短い ID から object ID へ
  Index.zig       .git/index の読み書き、index から tree を作る
  worktree.zig    作業ツリーのパスとファイルの列挙
  cmd/            サブコマンド (1 ファイルに 1 コマンド。version だけは main.zig)
tests/compat.sh   git との相互運用テスト
```

## 本物の git との違い

- loose object しか扱いません。`git clone` した直後のように pack しか無いリポジトリでは `fatal: ObjectNotFound` になります (このリポジトリを clone したものも同じです)。pack を `.git` の外へ出してから `git unpack-objects` に通すと loose に戻せます。中に置いたままだと何も展開されません

      mkdir ../packs && mv .git/objects/pack/pack-* ../packs/
      for p in ../packs/*.pack; do git unpack-objects < "$p"; done

- `status` `diff` `checkout` `merge` `clone` はありません (続刊の予定)
- `.gitignore` を見ません。index は version 2 のみ書き、読むのは 2 と 3 です
- `log` は最初の親だけを辿ります (`git log --first-parent` 相当)
- `HEAD~1` や `HEAD^` のような指定は使えません (ref の名前、40 桁の ID、4 桁以上の短縮 ID だけ)
- annotated tag は辿りません。`zgit log v1.0` のようにタグ オブジェクトを渡すと失敗します
- 設定ファイルの `[include]` と `/etc/gitconfig` は読みません。現在時刻のタイムゾーンは `/etc/localtime` から取り、`TZ` は見ません
- commit メッセージは整形しません (`git commit` は行末の空白などを落とします)。空のメッセージも通ります

## 正誤表・更新履歴

本の誤りの訂正や、Zig の新しいバージョンへの対応は、ここに書いていきます。
本の通りに動かないときは、まずここを確認してください。
見つけた誤りは Issue で教えてもらえると助かります。

まだありません。

## ライセンス

MIT License です。
