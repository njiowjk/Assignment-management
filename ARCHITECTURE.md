# Architecture

## 言語の責務

バックエンドの処理はTypeScript、ネイティブUIとmacOS APIのアダプターはSwiftで実装する。

| TypeScript | Swift |
| --- | --- |
| Moodle HTTPS取得・ICS解析 | SwiftUIの画面・入力・表示上の分類 |
| LMS共通モデルと正規化 | Keychainの保存・読取 |
| UIDによる差分更新・締切変更検出 | Core Dataの読み書きとトランザクション |
| 完了状態・取得不能/消失の取扱い | Node子プロセスの起動・キャンセル |
| WebClassの通信・正規化・完了判定 | WKWebView・将来の通知・ログイン項目 |

## データフロー

```text
SwiftUI → ViewModel → Swiftの薄いConnector → BackendClient
                                              ↓ stdin / stdout JSON
                                      TypeScript worker
                                      ├─ MoodleConnector → ICSParser
                                      ├─ WebClassConnector → 学生用課題一覧API
                                      └─ mergeTasks（更新ルール）
                                              ↓
                              CoreDataTaskRepository（保存のみ）
```

UIはLMS固有のHTTPやカレンダー形式を知らない。既存のSwift ICSParserと差分更新ルールは削除し、二重実装しない。Swiftの期限分類は画面表示用であり、バックエンドの保存状態を変更しない。

## TypeScriptバックエンド

- Node.js 22以降。strict TypeScriptで型チェックする。
- `src/connectors/` にLMS固有処理を分離する。
- ICSはUTF-8デコード前にアンフォールドし、UID・タイトル・日時を検証する。
- UTC・IANA TZID・浮動日時・終日を扱う。日時はTemporalで検証する。未対応の繰り返し・未知のタイムゾーンは同期失敗にする。
- DTEND優先、なければDTSTART。終日のDTENDは排他的。提出状態はICSから推測せず、ログイン済みセッションで別途取得する。
- `mergeTasks` は副作用のない関数。対象Sourceの課題のみを返す。UUID・初回検出日時を保持し、消失はフラグだけで記録する。
- `isCompleted == null` は不明。確認済みの完了を上書きしない。
- WebClassは法政大学で確認した固定の読取APIのみ使用する。他ホストへ一般化しない。
- HTTPは60秒・8MiB上限、HTTPS同一オリジンのリダイレクトのみ許可する。

## Moodleの自動完了判定

- macOSのWKWebViewで、カレンダーURLのオリジンにある公式ログイン画面を開く。初回ログインは利用者が行う。
- WKWebViewはnonPersistent。パスワード入力欄へアクセスせず、M.cfgのログイン状態だけを検証する。
- 連携操作で対象Moodleに一致するCookieをKeychainへ保存する。CookieとCSRFキーをログへ渡さない。
- TypeScriptのSessionClientはmy/でログイン状態を確認し、M.cfgのJSONを解析する。JavaScriptコードは実行しない。
- core_calendar_get_calendar_event_by_idでUIDから教材のcourse module IDを解決し、提出ページの正規リンクを付ける。
- core_get_stringsで提出・受験状態の翻訳を取得する。生の例外やHTMLはログに出さない。
- 課題はsubmissionstatustableのsubmitted/draft/reopenedと、Moodle自身の未提出文言から判定する。成績を提出状態の代わりにしない。
- 小テストはquizattemptsummaryの受験状態を読む。進行中/期限超過があれば完了済み受験より優先して残す。
- その他の教材はcore_course_get_moduleのコース一覧フラグメントから自動完了条件を読む。教材を開いて閲覧完了を発生させない。
- セッションを送る通信は同一オリジン・対象サイトパス・Cookieパス・有効期限を検証する。リダイレクト先へ無条件にCookieを送らない。
- 保存済みで今回のICSにない課題もチェック対象にし、isRemovedFromSourceを保持する。期間外になったことから提出完了を推測しない。
- 未確認の課題を通常の未完了一覧へ混ぜず、折りたたみの別枠へ残す。確認済み完了の情報は保存し、ホームから除外する。
- 大学の公開ログインページは実通信で確認済み。ログイン後の大学固有の表示は、利用者が連携してから検証する。非対応時は不明として保持する。

## プロセス間通信

- リクエストごとにNodeを起動し、1つのJSONをstdinへ書き、EOFを送る。
- stdoutは `{ version: 1, ok: true, result }` または `{ version: 1, ok: false, error: { code } }` だけを返す。
- Wireの日付はUnix epochからのミリ秒。DBでは既存のJSONEncoder形式を維持する。
- 入口でJSONの型・日付・UUID・Sourceを検証する。メッセージは32MiBまで。
- URLはstdinだけで渡す。引数、環境変数、通常設定、DB、ログにカレンダーURLを保存しない。
- エラーは固定コードのみ返し、元の例外・レスポンス本文・URLを出力しない。Swiftは固定の日本語表示へ変換する。
- Swiftは子をメインスレッド外で待ち、キャンセルまたは90秒タイムアウトで終了させる。
- 外部向けの待受ポートやクラウドサーバーは使わない。

## WebClass連携

- 実際のHOPPII → OpenAM/Shibboleth → WebClass接続、ログイン後の課題一覧、読取APIレスポンスを調査済み。2026-10-22に利用者がアプリ内ログイン・初回同期の成功を確認。すべての教材種類・状態の実データ網羅検証ではない。
- WKWebViewはnonPersistent。ナビゲーションは調査済み3ホスト（hoppii2025/idp/lms2025.hosei.ac.jp）のHTTPSに限定する。別窓リンクは同じWebViewへ渡す。
- 公式のdashboardメタデータでログイン状態を確認し、連携操作時にWebClassホスト用Cookieのみ保存する。IdP・HOPPII・大学全体に作用するCookieは保存しない。
- Keychainは既存Moodleとは別のservice `jp.universitytaskmanager.webclass` / account `webclass-session`。パスワード・HTML・生レスポンスを保存しない。
- バックエンドはdashboardの本人識別情報と、学生用courses/contentsをGETする。API_URL/TOP_URLは固定値と照合し、HTMLで指定された任意のURLを信用しない。
- 教員権限のあるコースは対象外。本人に一致するscoresの一件だけを使い、Taskには点数・氏名・個人識別情報を含めない。
- 締切はAPIの秒を保持してAsia/Tokyoとして解釈する。非公開・締切なしは対象外。年度・学期では除外しない。
- 外部IDはgroup_id:contents_id。締切やタイトルをIDに含めない。元リンクは教材実行ページでなく授業へのリンク。
- 合格点・公開状態・回答日時・アンケート匿名性を、調査したフロントエンドの学生フィルターと同じ条件で判定する。矛盾や不明はnull。匿名アンケートの実施状況を推測しない。
- 最大3並列、全体60秒、1応答8MiB。リダイレクトを追わず、ログイン切れは固定エラー。Cookieを他ホストへ転送しない。
- 失敗・型不一致を空配列に変換しない。全授業の取得成功後だけ既存のmerge/DBトランザクションへ渡す。
- UIはLMS別の成功時刻・エラーを持つ。一方のLMSに失敗しても他方を同期し、失敗側のキャッシュは維持する。

## ネイティブ保存と互換性

- App/StateObjectの初期化ではKeychainへアクセスしない。SwiftUIのウィンドウ生成後に一度だけ認証情報をバックグラウンドで読み、複数ウィンドウの同時開始でも同じ読込Taskを共有する。
- Keychain確認中も保存済み課題を表示する。認証拒否をエラーとして表示し、ウィンドウ登録時・認証確認後・Dock再オープン時に一覧を前面へ戻す。認証権限やKeychainのアクセス制御は変更しない。

- Core Dataのエンティティ名・属性名・SQLite保存先・JSON保存形式は変更しない。
- Keychainのservice/accountも変更しない。利用者の再登録は不要。
- Swift Repositoryは既存課題をTypeScriptに渡し、返った対象Sourceのスナップショットを保存する。
- 同期時刻と課題を同時にsaveし、保存失敗時はrollbackする。
- バックエンドが失敗した場合は書込みに進まない。
- 取得・更新中でも前回保存した一覧を閲覧できる。DBが開けないときに空DBへ自動置換しない。

## ビルドとテスト

- `backend/build.sh` は依存がなければnpm ciし、型チェックと単一workerへのバンドルを実施する。
- `run.sh` はSwiftをビルドし、workerとNodeの実行パスをapp Resourcesへ配置する。
- このMacにインストールされたNodeを使う。独立配布用のNode本体同梱は後続作業。
- Xcodeにも同じビルドスクリプトを呼ぶフェーズを設定する。
- `./test.sh` でTypeScriptの単体テストと、Swift→Node→Core Dataの結合テストを行う。
- 実際の大学アカウント、Keychain、本番DBにはテストからアクセスしない。

## 後続フェーズ

通知・MenuBarExtra・SMAppService・定期同期をネイティブアダプターから接続する。WebClassの未知の状態は不明として保持し、実運用で確認を続ける。Version 1の受入条件は引き続き未完了。

