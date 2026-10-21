# Architecture

## データフロー

```text
MoodleConnector ─┐
                 ├─ RemoteTask ─ SyncService ─ TaskRepository ─ ViewModel ─ SwiftUI
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

## Phase 2（実装済み・実URLでの確認待ち）

- 永続化はCore Data。プログラムでモデルを定義し、ターミナルからビルド可能なmacOS 13対応を維持する。
- RepositoryはMainActorで読み書きする。課題スナップショットとSourceごとの最終正常同期日時を、同じトランザクションで保存する。
- 保存失敗時にはrollbackし、DB破損時に空のDBへ自動置換しない。
- URLはKeychainのgeneric passwordに保存。画面へ再表示せず、生の通信エラーをユーザーへ渡さない。
- Connectorはephemeral URLSessionを使い、HTTP・別オリジンへのリダイレクトを拒否する。
- ICSはUTF-8のデコード前にアンフォールド。UID・SUMMARY・日時を検証し、未対応の繰り返し形式は全体の同期失敗にする。
- DTEND優先、なければDTSTART。終日のDTENDは排他的。CATEGORIESから授業名を取得し、なければ未取得を明示する。
- UIDの一致で更新し、ローカルUUIDと初回検出日時を維持する。消失は `isRemovedFromSource` に記録し課題を残す。
- `RemoteTask.isCompleted == nil` は提出情報不明。確認済みの完了を上書きしない。
- UIは起動時・手動同期、設定、最終正常同期、同期エラーを表示する。ローカルでの期限分類は毎分再計算する。
- テストは `./test.sh` で実コードをコンパイルし、模擬HTTPと一時DBを使う。ユーザーのKeychainや本番DBにはアクセスしない。

## 後続フェーズ

Moodleの実フィード確認、取得期間・予定種別の確認、自動提出判定の調査は未完了。Phase 2の実運用確認が済んでから次へ進む。

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
- MoodleカレンダーURLはKeychainにだけ保存する。
- WebClass認証は公式ページをWKWebViewで開き、仕様確認後にセッション連携方法を決める。
- 片方のConnector失敗で、もう片方の取得済みデータを削除しない。

