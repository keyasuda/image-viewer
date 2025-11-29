# AGENTS.md - AI Agent Guidelines

このドキュメントはAIエージェントがこのプロジェクトを扱う際のガイドラインです。

## プロジェクト概要

Ruby + GTK4で実装された画像選別ビューワアプリケーションです。

## 技術スタック

- **言語**: Ruby 3.x
- **GUI**: GTK4 (gtk4 gem)
- **EXIF読み取り**: exif gem
- **テスト**: RSpec
- **依存管理**: Bundler

## ファイル構成

```
image-viewer/
├── image_viewer.rb           # メインアプリケーション (GUI)
├── lib/
│   └── image_viewer_core.rb  # コアロジック (テスト可能)
├── spec/
│   ├── spec_helper.rb        # RSpec設定
│   └── image_viewer_core_spec.rb  # コアロジックのテスト
├── Gemfile                   # 依存gem定義
├── Gemfile.lock              # 依存バージョンロック
├── vendor/                   # Bundlerによるgem格納先
├── README.md                 # ユーザー向けドキュメント
└── AGENTS.md                 # このファイル
```

## 開発時の注意点

### GTK4 Ruby Bindings

GTK4のRubyバインディング (gtk4 gem) は以下の点に注意：

1. **キー定数**: `Gdk::KEY_*` や `Gdk::Key::KEY_*` は使用不可。直接キーコード値を使用する
   ```ruby
   # 正しい例
   when 0xff53 # Right arrow
   when 0xff51 # Left arrow
   when 0x020  # Space
   ```

2. **スタイルプロバイダ優先度**: `Gtk::STYLE_PROVIDER_PRIORITY_APPLICATION` ではなく `Gtk::StyleProvider::PRIORITY_APPLICATION` を使用

3. **アプリケーションフラグ**: ディレクトリパスを引数で受け取る場合、`:handles_open` ではなく `:flags_none` を使用し、コンストラクタで直接パスを受け取る

### ビルド・実行

```bash
# 構文チェック
bundle exec ruby -c image_viewer.rb

# 実行
bundle exec ruby image_viewer.rb [directory_path]

# テスト実行
bundle exec rspec
```

### 依存ライブラリの追加

```bash
# Gemfileを編集後
bundle install
```

## コード構造

### ImageViewerCore (lib/image_viewer_core.rb)

GUIから分離されたテスト可能なコアロジック：

- `ImageViewerCore::Metadata` - メタデータ (pinned/skipped) の管理
- `ImageViewerCore::ImageList` - 画像リストの管理、ソート、ナビゲーション
- `ImageViewerCore::FileCopier` - ピン留め画像のコピー処理

### ImageViewer (image_viewer.rb)

`Gtk::Application` を継承したGUIアプリケーション：

- `initialize`: アプリケーション初期化、シグナル接続
- `build_ui`: GTK4ウィジェットの構築
- `load_images`: コアロジックを使用して画像をロード
- `show_current_image`: 現在の画像を表示
- `handle_key_press`: キーボードイベント処理

## テスト

RSpecによる自動テストを実装済み：

```bash
bundle exec rspec
```

テスト対象：
- メタデータの保存・読み込み
- ピン留め/スキップのトグル動作
- 自然順ソート (Natural Sort)
- スキップファイルを考慮したナビゲーション
- ラップアラウンド動作
- ファイルコピー処理

GUIに直接関連する機能（キー押下、画像表示等）は手動テストで確認：

1. ディレクトリ引数あり/なしでの起動
2. 左右キーでのナビゲーション
3. Space/Xキーでのピン留め/スキップ
4. ズーム操作 (+/-/0)
5. 外部アプリ起動 (E)
6. ピン留め画像のコピー機能

