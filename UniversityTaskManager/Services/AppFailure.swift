import Foundation

/// 通信・DB・Keychainの生のエラーにはURLやトークンが含まれ得るため、画面には固定文だけを渡す。
enum AppFailure: LocalizedError, Equatable, Sendable {
    case invalidURL, keychain, storage, invalidCalendar, unsupportedCalendar
    case network, authentication, server, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: "有効なHTTPSのMoodleカレンダーURLを入力してください。"
        case .keychain: "Keychainへアクセスできませんでした。MacのKeychainの状態を確認してください。"
        case .storage: "課題データを読み書きできませんでした。保存済みデータは削除していません。"
        case .invalidCalendar: "カレンダーデータを解析できませんでした。Moodleで取得したURLか確認してください。"
        case .unsupportedCalendar: "未対応の繰り返し予定・日時形式が含まれています。保存済みの課題は維持しています。"
        case .network: "通信できませんでした。保存済みの課題を表示しています。"
        case .authentication: "カレンダーURLが無効か、認証が必要です。MoodleでURLを再取得してください。"
        case .server: "Moodleから正常な応答を取得できませんでした。時間を置いて再試行してください。"
        case .tooLarge: "カレンダーデータが大きすぎるため取得を中止しました。"
        }
    }

    static func message(for error: any Error) -> String {
        if let failure = error as? AppFailure { return failure.localizedDescription }
        if let failure = error as? ConnectorError { return failure.localizedDescription }
        return AppFailure.storage.localizedDescription
    }
}
