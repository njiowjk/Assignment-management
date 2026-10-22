# UniversityTaskManager

Moodle と WebClass に分散する大学課題を、締切順にまとめて確認するための macOS ネイティブアプリです。

現在は **Phase 3（WebClass連携）** です。画面はSwiftUI、バックエンドはMac内で動くTypeScript/Node.jsです。取得した課題を次の順で表示します。

1. 期限切れ
2. 今日
3. 明日
4. 今週
5. それ以降

各グループ内は締切の早い順です。通常の一覧は、未完了が確認できた課題だけを表示します。完了済みは自動的に除外し、判定できなかった課題は「確認できなかった課題」に分けて保存します。

## ターミナルから起動

Swift Command Line ToolsとNode.js 22以降（npmを含む）が必要です。このMacではインストール済みです。Xcodeアプリを開かなくても、次のコマンドでビルドして起動できます。

```sh
cd /Users/sakakihondaihase/Desktop/assin
./run.sh
```

初回はバックエンドの依存を `npm ci` で取得してからビルドします。`.build/UniversityTaskManager.app` にコンパイルしたバックエンドを同梱し、通常のMacアプリとして起動します。アプリを終了するときは `Command + Q` を押します。ターミナルの `Control + C` は起動待ちの終了用です。

課題ウィンドウを先に表示してから、保存済みの認証情報をバックグラウンドで確認します。Keychainの確認中も前回の課題を表示し、認証を拒否した場合は画面にエラーを出します。ウィンドウが背面や最小化状態になった場合はDockのアプリアイコン、またはアプリの「ファイル」→「課題一覧を開く」（Command + 1）で戻せます。

ビルドだけ行う場合は `./run.sh --build-only` を実行します。Nodeの実行ファイルはこのMacにインストールされたものを使います。別のMacへ配布するためのNode本体同梱はまだ行っていません。

サンプル画面だけを確認する場合は `./run.sh --demo` を実行します。デモでは実際のDBやKeychainにアクセスしません。

## Moodleの接続

1. Moodleの「カレンダー」→「カレンダーをエクスポート」を開きます。
2. 授業の予定と、十分な期間（例：最近と今後60日）を選び、「URLを取得」で生成したHTTPSのURLをコピーします。
3. アプリの「設定」でURL欄を選んで `Command + V`、または欄の横の「貼り付け」を押し、「保存して同期」を押します。
4. 同じ設定画面で「Moodleにログイン」を押し、表示された大学公式ページでログインします。
5. 「連携して同期」を押すと、提出情報を取得して完了済みの課題を一覧から除外します。

URLは認証トークンを含むため、チャットやGitHubには貼り付けず、アプリの設定に入力してください。Keychainだけに保存し、通常の設定・DB・ログには保存しません。

ログイン画面はWKWebView内の大学公式サイトです。アプリ独自のパスワードフォームはなく、パスワードは読み取り・保存しません。連携ボタンを押したときにMoodle向けCookieだけをKeychainに保存します。CIS Moodleは学外からの利用に大学VPNが必要な場合があります。

カレンダーURLだけを登録した状態では提出情報を取得できません。セッションが切れた場合は設定で再ログインしてください。認証エラーで課題を削除したり、完了扱いにしたりすることはありません。

## 自動完了判定

- 課題提出：Moodleの提出ステータスがsubmittedなら完了。draft/reopenedは未完了。点数や未採点表示からは判定しません。
- 小テスト：完了した受験があれば完了。進行中や期限超過の受験が残っていれば未完了です。表示文言はMoodleから翻訳を取得します。
- その他の教材：Moodleが設定している自動完了条件の状態を、コース一覧の読取APIから取得します。確認のために教材を開いて閲覧済みにする処理は行いません。
- 自動完了が未設定、未知の表示形式、権限不足、取得失敗などでは不明のまま保存します。未完了だと断定せず、別枠から確認できます。
- カレンダーフィードの期間外になった保存済み課題も、ログイン中は提出状態を再確認します。

大学の公開ログイン画面は確認済みですが、ログイン後の大学固有の提出画面は利用者のログイン後に実運用確認が必要です。判定はMoodle公式のAPIと標準レンダラーに基づいており、不明な構造は推測で完了にしません。

登録後はアプリ起動時と「今すぐ同期」で取得します。課題は `~/Library/Application Support/UniversityTaskManager/tasks.sqlite` に保存します。オフライン時も前回保存分を表示します。

## テスト

```sh
./test.sh
```

TypeScriptの型チェック・バックエンドのユニットテストと、Swiftから実際にNodeを呼ぶ結合テストを実行します。ICS解析、日時、差分更新、SQLite再読み込み、模擬HTTP通信、同期失敗時のデータ保持を検証します。実際の大学アカウントやKeychainは使いません。

## WebClassの接続

1. アプリの「設定」を開き、下へスクロールして「WebClassにログイン」を押します。
2. HOPPIIから法政大学の統合認証でログインします。パスワードや多要素認証は公式画面に入力します。
3. WebClassの課題一覧まで自動的に進みます。進まない場合はHOPPIIの「学習支援システム(WebClass)」、続いて「課題一覧へ」を選びます。
4. 「連携して同期」を押すと、WebClass用CookieをKeychainに保存し、課題・締切・実施状況を取得します。

調査用の内蔵ブラウザと、このアプリのWKWebViewは別セッションです。内蔵ブラウザからCookieをコピーする機能はなく、アプリでも初回ログインが必要です。受験中・回答中の別ログインは避けてください。ログインが切れたときは「HOPPIIで再ログイン」を押します。

大学の実際のログイン後画面・公開フロントエンド・本人の読取APIで接続経路とレスポンス形式を確認しました。2026年10月22日、利用者の環境でアプリ内ログインから初回同期まで成功したことを確認しました。すべての教材種類・状態を実データで網羅した検証ではありません。

- CSVダウンロードは不要です。画面と同じ `score_summary_table` の `dashboard` / `courses` / `contents` をGETします。
- 本人の実施記録だけを判定し、教員用のコース・他学生の成績取得APIは使用しません。成績・氏名・ユーザーIDはTaskに保存しません。
- 学期・年度で自動除外せず、受講中として取得できる授業を確認します。締切なし・非公開教材は除外します。
- 教材IDとコースIDを使うため、タイトルや締切が変わっても同じ課題を更新します。
- 合格点が公開されている教材は不合格なら未完了、合格なら完了です。合格点なし、または非公開成績の教材は、公式の学生向け絞込みと同じ実施記録を使います。
- 記名アンケートは回答記録で判定します。匿名アンケートや判定情報不足は不明として別枠に残します。点数0を未実施と誤認しません。
- 大学統合認証・HOPPIIのCookieやパスワードは保存しません。WebClass用Cookieだけを専用のKeychain項目で管理します。
- 通信は固定のHTTPS読取先に限定し、SSOリダイレクトを追跡しません。最大3並列・同期全体60秒・1応答8MiBです。
- 1授業でも取得に失敗すれば、その回のWebClass保存を行いません。Moodleとの同期は独立しており、一方の失敗でも他方は同期できます。
- 元ページへのリンクは授業ページです。教材を自動的に開いて受験開始や閲覧完了を発生させません。

登録後は起動時と「今すぐ同期」で両方のLMSを取得します。各LMSの最終成功時刻とエラーを個別に表示します。定期同期・通知はまだ未実装です。

バックエンドだけを開発・検証する場合：

```sh
cd backend
npm ci
npm test
npm run build
```

`package-lock.json` を共有し、依存のバージョンを固定しています。

## Xcodeから開く

推奨: `UniversityTaskManager.xcodeproj` を Xcode で開き、`UniversityTaskManager` scheme を実行します。

XcodeビルドにもTypeScriptバックエンドを生成・同梱するビルドフェーズを追加しています。SwiftUIの分類テストは `Product > Test`、バックエンドと結合テストは `./test.sh` で実行できます。この環境にはXcode本体がないため、Xcodeのビルドフェーズ実行は未確認です。

## 現在の境界

| 担当 | 言語・場所 |
| --- | --- |
| Moodle通信・ICS解析・提出状態の読取・正規化 | TypeScript：`backend/src/connectors/` |
| 重複防止・締切変更・完了状態・消失判定 | TypeScript：`backend/src/merge.ts` |
| メッセージ検証・実行入口 | TypeScript：`backend/src/validation.ts`、`worker.ts` |
| 画面・表示用の期限グループ分け | SwiftUI：`UniversityTaskManager/Views/`、`Utilities/` |
| Keychain・Core Data・子プロセス連携 | Swift：`Services/`、`Persistence/`、`Backend/` |

SwiftのMoodle/WebClass ConnectorはTypeScriptを呼ぶ薄いアダプターです。WebClassは法政大学の調査済み構成に対応し、他大学・別ホストには対応していません。

バックエンドはリクエストごとに起動し、JSONを標準入力・標準出力で受け渡します。HTTPサーバーやポートは使いません。トークン付きURLやセッションCookieは引数・環境変数・通常ファイルへ渡さず、Keychainから読み取った値を標準入力だけで渡します。NodeはCookieやディスクキャッシュを保存しません。

## 保存方式と制限

ターミナル起動を維持するため、Core Dataを採用しmacOS 13対応を継続しました。保存先とDB形式・Keychainの識別子は変更していないため、既存の課題・登録済みURLを引き継ぎます。Swiftは保存の読み書きを担当し、更新する内容はTypeScriptが決定します。

- UIDで同じ課題を更新します。締切変更でも課題IDと初回検出日時を保ちます。
- フィードから消えた課題は削除・完了扱いにせず、取得範囲に見つからないことを表示します。
- VEVENTのDTENDを優先し、なければDTSTARTを使います。終日のDTENDは排他的なため、その直前を期限とします。一般の予定も候補として表示する段階であり、課題のみの厳密な抽出は今後の実データ調査が必要です。
- UTC、IANA TZID、浮動日時、終日、折り返し行に対応します。繰り返し予定・未知のタイムゾーン・破損データは黙って捨てず、同期を失敗にして保存済みデータを維持します。
- 定期同期、通知、メニューバー常駐、自動起動は後続フェーズです。Version 1完成ではありません。

WebClass調査で確認した接続先：`hoppii2025.hosei.ac.jp/portal/` → `idp.hosei.ac.jp/openam/` → HOPPIIの`portal/sso/Parm.php` → `lms2025.hosei.ac.jp/webclass/`。判定ルールは、大学が配信するダッシュボードの学生向け完了/未完了フィルターを参照しています。実アカウントの生データや認証情報はテスト・Gitに含めません。

形式の参照：[Moodleカレンダー公式ドキュメント](https://docs.moodle.org/en/Calendar_export)、[iCalendar RFC 5545](https://www.rfc-editor.org/rfc/rfc5545)。

完了判定の参照：[Moodle標準の提出ステータス表示](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/mod/assign/classes/output/renderer.php)、[受験状態表示](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/mod/quiz/classes/output/renderer.php)、[自動完了条件テンプレート](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/course/templates/completion_automatic.mustache)。
