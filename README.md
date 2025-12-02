# 📸 Image Viewer - 画像選別・閲覧ビューワ

Linuxデスクトップ環境 (GNOME) での利用を想定した、写真の選別（Culling）に特化したシンプルな画像ビューワです。

## 特徴

- **連写画像の一括スキップ** - 不要な画像をXキーでスキップし、以降のナビゲーションで自動的にスキップ
- **選別結果の永続化** - ピン留め/スキップ状態を `imgview_meta.yml` に保存
- **自然なソート順** - EXIF撮影日時 → ファイル名の自然順でソート
- **高速なナビゲーション** - 次画像のプリロードによるスムーズな表示

## 必要環境

- Ruby 3.x
- GTK4 (`libgtk-4-dev`)
- Bundler

## インストール

```bash
# GTK4開発ライブラリのインストール (Ubuntu/Debian)
sudo apt install libgtk-4-dev

# 依存gemのインストール
bundle install
```

## 使い方

```bash
# ディレクトリを指定して起動
bundle exec ruby image_viewer.rb /path/to/image/directory

# 画像ファイルを指定して起動（そのファイルから表示開始）
bundle exec ruby image_viewer.rb /path/to/image/photo.jpg

# 引数なしで起動（ディレクトリ選択ダイアログが表示される）
bundle exec ruby image_viewer.rb
```

### Nautilusからの起動

画像ファイルをダブルクリックで開けるようにするには：

```bash
# デスクトップエントリをインストール
cp image-viewer.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/

# 画像ファイルのデフォルトアプリとして設定（オプション）
xdg-mime default image-viewer.desktop image/jpeg
xdg-mime default image-viewer.desktop image/png
```

## キーボードショートカット

| 操作 | キー |
|------|------|
| 次の画像 | `→` (Right Arrow) |
| 前の画像 | `←` (Left Arrow) |
| 次のピン留め画像 | `Ctrl+→` |
| 前のピン留め画像 | `Ctrl+←` |
| ピン留め/解除 | `Space` |
| 全ピン留めクリア | `Ctrl+Space` |
| スキップ | `X` |
| ゴミ箱に移動 | `DEL` |
| ズームイン | `+` / `=` |
| ズームアウト | `-` |
| 画面フィット | `0` |
| 外部アプリで開く | `E` |
| 終了 | `Esc` |
| 10枚スキップ | `Shift+←` / `Shift+→` |

## 機能詳細

### Pin/Skip機能

- **ピン留め (Pinned)**: 選別済みファイルとしてマーク。ヘッダーに📌アイコンで表示
- **スキップ (Skipped)**: 以降のナビゲーションでスキップされる。ヘッダーに⏭️アイコンで表示

### ステータス表示

画面下部のinfo_barに以下の情報を表示：
- ファイル名
- 現在位置/総数
- 画像サイズ
- ズーム状態
- ピン留め数・スキップ数 (📌2 ⏭️3)

### ピン留め画像のコピー

ヘッダーバーの「Copy Pinned」ボタンをクリックし、コピー先ディレクトリを選択すると、ピン留めされた全画像がコピーされます。

### メタデータファイル

選別状態は画像ディレクトリ内の `imgview_meta.yml` に自動保存されます：

```yaml
pinned:
- DSC0001.JPG
- DSC0003.JPG
skipped:
- DSC0002.JPG
- DSC0004.JPG
```

テキストエディタで直接編集することも可能です。

## 対応画像形式

- JPEG (`.jpg`, `.jpeg`)
- PNG (`.png`)
- WebP (`.webp`)
- TIFF (`.tiff`, `.tif`)
- BMP (`.bmp`)

## ソート順序

1. **プライマリソート**: EXIF撮影日時 (DateTimeOriginal) 昇順
2. **セカンダリソート**: ファイル名の自然順 (Natural Sort)

## ライセンス

MIT License
