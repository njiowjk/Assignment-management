# Architecture

## データフロー

```text
MoodleConnector ─┐
                 ├─ RemoteTask ─ SyncService（Phase 2以降）─ TaskRepository ─ ViewModel ─ SwiftUI
WebClassConnector┘
```

LMS固有の認証、HTML、CSV、ICSはConnector配下へ閉じ込めます。UIと永続化は正規化後のデータだけを扱います。

## Phase 1

- SwiftUIのmacOSアプリ骨格
- Taskのドメインモデル
- LMS共通Connectorインターフェース
- Repository境界とダミー実装
- 期限切れ/今日/明日/今週/それ以降の分類
- 未完了フィルタと締切順ソート
- 一覧と詳細画面
- 分類ロジックのユニットテスト

「今週」はユーザーの現在のCalendarにおける週末までと定義します。今日と明日は先に独立グループへ分類します。

## 後続フェーズ

### Phase 2

- 永続化方式の確定（SwiftDataにはmacOS 14が必要）
- Keychainに保存したMoodleカレンダーURL
- ICS取得・解析
- 差分同期の基礎

### Phase 3

- WKWebViewによる大学公式ログイン
- 実通信を観察した上でWebClassセッション連携
- 課題実施状況データの自動取得

### Phase 4以降

- 自動完了判定、差分同期、通知
- MenuBarExtra、SMAppService、定期同期
- 設定、初回セットアップ、エラー処理

## セキュリティ境界

- パスワードは収集・保存しない。
- URLトークンやセッション値はログへ出さない。
- MoodleカレンダーURLは実装時にKeychainへ保存する。
- WebClass認証は公式ページをWKWebViewで開き、仕様確認後にセッション連携方法を決める。
- 片方のConnector失敗で、もう片方の取得済みデータを削除しない。

