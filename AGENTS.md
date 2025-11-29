# AGENTS.md - AI Agent Guidelines

このドキュメントはAIエージェントがこのプロジェクトを扱う際のガイドラインです。

## プロジェクト概要

Ruby + GTK4で実装された画像選別ビューワアプリケーションです。

## 技術スタック

- **言語**: Ruby 3.x
- **GUI**: GTK4 (gtk4 gem)
- **EXIF読み取り**: exif gem
- **依存管理**: Bundler

## ファイル構成

```
image-viewer/
├── image_viewer.rb    # メインアプリケーション
├── Gemfile            # 依存gem定義
├── Gemfile.lock       # 依存バージョンロック
├── vendor/            # Bundlerによるgem格納先
├── README.md          # ユーザー向けドキュメント
└── AGENTS.md          # このファイル
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
```

### 依存ライブラリの追加

```bash
# Gemfileを編集後
bundle install
```

## コード構造

`ImageViewer` クラスが `Gtk::Application` を継承し、以下の主要メソッドを持つ：

- `initialize`: アプリケーション初期化、シグナル接続
- `build_ui`: GTK4ウィジェットの構築
- `load_images`: ディレクトリから画像ファイルを取得・ソート
- `show_current_image`: 現在の画像を表示
- `handle_key_press`: キーボードイベント処理
- `save_metadata`: メタデータをYAMLファイルに保存

## テスト

現時点では自動テストは未実装。手動テストで以下を確認：

1. ディレクトリ引数あり/なしでの起動
2. 左右キーでのナビゲーション
3. Space/Xキーでのピン留め/スキップ
4. ズーム操作 (+/-/0)
5. 外部アプリ起動 (E)
6. ピン留め画像のコピー機能
7. メタデータの永続化
