# リリース手順

SUKESAN のリリースの手順です（保守者向け）。リリースとは、main のコミットに `vX.Y.Z` のタグを打ち、GitHub Releases を作ることを指します。変更の内容は [CHANGELOG.md](../CHANGELOG.md) に記録します。

バージョンはタグだけで管理し、コードには持ちません。チェックアウトしている版は `git describe --tags` で確認できます。

## 変更履歴の書き方

- 連携先・運用者・画面の利用者に影響する変更は、その変更を入れるコミット（PR）で CHANGELOG.md の先頭の `## [未リリース]` 節に書き足します。節が無ければ作ります。
- 追加 / 変更 / 修正に分け、何がどう変わったかを 1 項目 1〜2 行で書きます。互換性のない変更と、更新時に運用者の作業が要る変更（Ruby の版の更新など）は「変更」の先頭に置きます。
- 挙動に影響しない内部の整理と、依存 gem の定期更新は書きません（セキュリティ修正を含む更新は書きます）。

## 手順

手順中の `vX.Y.Z` はリリースするバージョン、`vPREV` は直前のバージョンに読み替えます。

1. CHANGELOG.md の `## [未リリース]` を `## [X.Y.Z] - YYYY-MM-DD` に書き換えます。日付はマージ日ではなくリリース日です。前回のリリース以降にマージした変更が漏れなく載っているかを確認し、末尾に比較リンクを足します。

   ```sh
   git log --first-parent --oneline vPREV..main   # 前回のリリース以降に main へ入った変更
   ```

   ```markdown
   [X.Y.Z]: https://github.com/namikawa/sukesan/compare/vPREV...vX.Y.Z
   ```

2. main にコミットして push し、CI が通ったことを確認します。

   ```sh
   git push origin main
   gh run list --workflow ci.yml --branch main --limit 1   # conclusion が success になるまで待つ
   ```

3. そのコミットに注釈付きタグを打ち、push します。

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. GitHub Releases を作ります。タグを push しただけでは Release は作られません。

   ```sh
   gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <リリースノートのファイル>
   gh release list   # 新しい版が Latest になっていることを確認する
   ```

   リリースノートは CHANGELOG の貼り付けではなく要約にします。追加 / 変更 / 修正ごとに 1 項目 1 行で何が良くなったかだけを書き、20 行以内に収めて、末尾に CHANGELOG.md への案内を添えます。ノートのファイルはコミットしません。

## タグの扱い

- タグ名は `vX.Y.Z` とし、main のコミットにだけ打ちます。
- 公開したタグは付け直さず、削除もしません。リリースに誤りがあれば、次の版で直します。
