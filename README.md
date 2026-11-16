# zgit

Zig で書いた、本物の Git と相互運用できる最小の Git 実装です。
技術書『Zigで学ぶ自作Git』(技術書典21) のサンプルコードとして、章ごとに機能を足していきます。

## 必要なもの

- Zig 0.17.1
- Git (互換性の確認に使います)

[mise](https://mise.jdx.dev/) を使っている場合は `mise install` で揃います。

## ビルド

```
zig build
./zig-out/bin/zgit version
```

テストは `zig build test` で実行できます。

## ライセンス

MIT
