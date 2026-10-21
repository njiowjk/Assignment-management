# UniversityTaskManager

Moodle と WebClass に分散する大学課題を、締切順にまとめて確認するための macOS ネイティブアプリです。

現在は **Phase 2（Moodle ICS連携・ローカル保存）** です。取得した予定を次の順で表示します。

1. 期限切れ
2. 今日
3. 明日
4. 今週
5. それ以降

各グループ内は締切の早い順です。完了が確認された課題はホーム画面から除外します。ただしMoodleのICSからは提出状況を取得できないため、現時点では提出済みの課題や一般のカレンダー予定が残る場合があります。

## ターミナルから起動

Xcodeアプリを開かなくても、次のコマンドでビルドして起動できます。

```sh
cd /Users/sakakihondaihase/Desktop/assin
./run.sh
```

初回だけビルドに少し時間がかかります。`.build/UniversityTaskManager.app` を生成し、通常のMacアプリとして起動します。アプリを終了するときは `Command + Q` を押します。ターミナルの `Control + C` は起動待ちの終了用です。

サンプル画面だけを確認する場合は `./run.sh --demo` を実行します。デモでは実際のDBやKeychainにアクセスしません。

## Moodleの接続

1. Moodleの「カレンダー」→「カレンダーをエクスポート」を開きます。
2. 授業の予定と、十分な期間（例：最近と今後60日）を選び、「URLを取得」で生成したHTTPSのURLをコピーします。
3. アプリの「設定」でURL欄を選んで `Command + V`、または欄の横の「貼り付け」を押し、「保存して同期」を押します。

URLは認証トークンを含むため、チャットやGitHubには貼り付けず、アプリの設定に入力してください。Keychainだけに保存し、通常の設定・DB・ログには保存しません。

登録後はアプリ起動時と「今すぐ同期」で取得します。課題は `~/Library/Application Support/UniversityTaskManager/tasks.sqlite` に保存します。オフライン時も前回保存分を表示します。

## テスト

```sh
./test.sh
```

Command Line Toolsだけでも、ICS解析、日時、差分更新、SQLite再読み込み、模擬HTTP通信、同期失敗時のデータ保持を検証できます。実際の大学アカウントやKeychainは使いません。ユーザーのMoodleへの実接続は、アプリでのURL登録後に確認します。

## Xcodeから開く

推奨: `UniversityTaskManager.xcodeproj` を Xcode で開き、`UniversityTaskManager` scheme を実行します。

Xcodeプロジェクトと同じソースを Swift Package としても定義しています。ユニットテストはXcodeの `Product > Test` から実行できます。

## 現在の境界

- `TaskSourceConnector` は LMS ごとの通信を共通化する境界です。
- `RemoteTask` は LMS 固有レスポンスを正規化したデータです。
- UI は `TaskRepository` だけに依存し、Moodle/WebClassの実装詳細を知りません。
- 通常起動では `CoreDataTaskRepository`、`--demo` では `SampleTaskRepository` を注入します。
- `MoodleConnector` はHTTPSでICSを取得・解析します。URLSessionのディスクキャッシュ・Cookie保存は無効です。
- `WebClassConnector` は未設定エラーを返すスタブです。

## 保存方式と制限

ターミナル起動を維持するため、Core Dataを採用しmacOS 13対応を継続しました。この環境のCommand Line ToolsにはSwiftDataのモデル用マクロが含まれていません。UIとDBの間はRepositoryで分離しています。

- UIDで同じ課題を更新します。締切変更でも課題IDと初回検出日時を保ちます。
- フィードから消えた課題は削除・完了扱いにせず、取得範囲に見つからないことを表示します。
- VEVENTのDTENDを優先し、なければDTSTARTを使います。終日のDTENDは排他的なため、その直前を期限とします。一般の予定も候補として表示する段階であり、課題のみの厳密な抽出は今後の実データ調査が必要です。
- UTC、IANA TZID、浮動日時、終日、折り返し行に対応します。繰り返し予定・未知のタイムゾーン・破損データは黙って捨てず、同期を失敗にして保存済みデータを維持します。
- 提出状態の自動判定、定期同期、通知、メニューバー常駐は後続フェーズです。Version 1完成ではありません。

WebClass/HOPPIIは、実際の認証・リダイレクト・Cookie・課題一覧/CSV取得フローを確認するまでネットワーク実装を追加しません。

形式の参照：[Moodleカレンダー公式ドキュメント](https://docs.moodle.org/en/Calendar_export)、[iCalendar RFC 5545](https://www.rfc-editor.org/rfc/rfc5545)。
