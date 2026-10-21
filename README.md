# UniversityTaskManager

Moodle と WebClass に分散する大学課題を、締切順にまとめて確認するための macOS ネイティブアプリです。

現在は **Phase 1** です。ダミーデータを使い、未完了課題を次の順で表示します。

1. 期限切れ
2. 今日
3. 明日
4. 今週
5. それ以降

各グループ内は締切の早い順です。完了済み課題はホーム画面から除外されます。

## ターミナルから起動

Xcodeアプリを開かなくても、次のコマンドでビルドして起動できます。

```sh
cd /Users/sakakihondaihase/Desktop/assin
./run.sh
```

初回だけビルドに少し時間がかかります。アプリを終了するときは `Command + Q`、または実行中のターミナルで `Control + C` を押します。

## Xcodeから開く

推奨: `UniversityTaskManager.xcodeproj` を Xcode で開き、`UniversityTaskManager` scheme を実行します。

Xcodeプロジェクトと同じソースを Swift Package としても定義しています。ユニットテストはXcodeの `Product > Test` から実行できます。

## 現在の境界

- `TaskSourceConnector` は LMS ごとの通信を共通化する境界です。
- `RemoteTask` は LMS 固有レスポンスを正規化したデータです。
- UI は `TaskRepository` だけに依存し、Moodle/WebClassの実装詳細を知りません。
- Phase 1では `SampleTaskRepository` を注入しています。
- `MoodleConnector` と `WebClassConnector` は、通信仕様を推測しないため明示的な未設定エラーを返します。

## 次フェーズ前の設計判断

要件の最低対応バージョンは macOS 13候補ですが、SwiftDataはmacOS 14以降です。Phase 2で永続化を実装する前に、次のどちらかを決めます。

- 最低対応をmacOS 14へ変更し、SwiftDataを採用する。
- macOS 13を維持し、Core Dataを採用する。

WebClass/HOPPIIは、実際の認証・リダイレクト・Cookie・課題一覧/CSV取得フローを確認するまでネットワーク実装を追加しません。
