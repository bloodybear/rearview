import Foundation

enum AppDisplayLanguage: String, CaseIterable, Sendable {
    case korean = "ko"
    case japanese = "ja"
    case english = "en"

    static let defaultsKey = "app.displayLanguage"
    static let defaultValue = AppDefaults.displayLanguage

    static func load(
        from defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Self {
        if let storedValue = defaults.string(forKey: defaultsKey),
           let storedLanguage = Self(rawValue: storedValue) {
            return storedLanguage
        }
        return preferredLanguage(from: preferredLanguages) ?? defaultValue
    }

    static func preferredLanguage(from identifiers: [String]) -> Self? {
        for identifier in identifiers {
            let normalized = identifier
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased()
            switch normalized {
            case Self.korean.rawValue: return .korean
            case Self.japanese.rawValue: return .japanese
            case Self.english.rawValue: return .english
            default: continue
            }
        }
        return nil
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var nativeTitle: String {
        switch self {
        case .korean: "한국어"
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}

enum L10n {
    static func text(
        _ korean: String,
        language: AppDisplayLanguage? = nil
    ) -> String {
        let resolvedLanguage = language ?? currentLanguage
        guard resolvedLanguage != .korean,
              let row = translations[korean]
        else { return korean }
        return resolvedLanguage == .japanese ? row.japanese : row.english
    }

    static func format(
        _ koreanFormat: String, _ arguments: CVarArg...,
        language: AppDisplayLanguage? = nil
    ) -> String {
        String(format: text(koreanFormat, language: language), arguments: arguments)
    }

    static func hasTranslation(
        for korean: String, language: AppDisplayLanguage
    ) -> Bool {
        language == .korean || translations[korean] != nil
    }

    private struct Translation {
        let english: String
        let japanese: String
    }

    private static var currentLanguage: AppDisplayLanguage {
        CommandLine.arguments.contains("--self-test") ? .korean : .load()
    }

    private static let translations: [String: Translation] = {
        var result: [String: Translation] = [:]
        for line in catalog.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            result[String(columns[0])] = Translation(
                english: String(columns[1]).replacingOccurrences(of: "\\n", with: "\n"),
                japanese: String(columns[2]).replacingOccurrences(of: "\\n", with: "\n")
            )
        }
        return result
    }()

    // Korean source strings remain the stable lookup keys. Tabs separate
    // Korean, English, and Japanese so all three catalogs stay in lockstep.
    private static let catalog = """
화면 번역	Screen Translation	画面翻訳
미러 도킹	Mirror Docking	ミラードッキング
미러 도킹: %@	Mirror docking: %@	ミラードッキング：%@
미도킹	Undocked	ドッキング解除
위쪽에 도킹	Dock Above	上にドッキング
아래쪽에 도킹	Dock Below	下にドッキング
왼쪽에 도킹	Dock Left	左にドッキング
오른쪽에 도킹	Dock Right	右にドッキング
도킹할 공간이 부족합니다	Not enough space to dock	ドッキングするスペースが足りません
미러 창을 선택 영역의 위쪽 변에 도킹하거나 같은 방향에서 해제합니다.	Dock the mirror above the selection, or press again to undock it.	ミラーを選択範囲の上辺にドッキングし、同じ方向でもう一度押すと解除します。
미러 창을 선택 영역의 아래쪽 변에 도킹하거나 같은 방향에서 해제합니다.	Dock the mirror below the selection, or press again to undock it.	ミラーを選択範囲の下辺にドッキングし、同じ方向でもう一度押すと解除します。
미러 창을 선택 영역의 왼쪽 변에 도킹하거나 같은 방향에서 해제합니다.	Dock the mirror to the left of the selection, or press again to undock it.	ミラーを選択範囲の左辺にドッキングし、同じ方向でもう一度押すと解除します。
미러 창을 선택 영역의 오른쪽 변에 도킹하거나 같은 방향에서 해제합니다.	Dock the mirror to the right of the selection, or press again to undock it.	ミラーを選択範囲の右辺にドッキングし、同じ方向でもう一度押すと解除します。
세그먼트 캐시 적중률: %@%%, 진행 중 요청 합류: %d	Segment cache hit rate: %@%%, in-flight joins: %d	セグメントキャッシュヒット率: %@%%、処理中リクエストへの合流: %d
영역 선택…	Select Area…	範囲を選択…
선택…	Choose…	選択…
설정…	Settings…	設定…
업데이트 확인…	Check for Updates…	アップデートを確認…
종료	Quit	終了
프로파일링 시작	Start Profiling	プロファイリングを開始
프로파일링 종료 및 결과 보기	Stop Profiling and View Results	プロファイリングを終了して結果を表示
최근 프로파일 결과 보기	View Latest Profile	最新のプロファイル結果を表示
내장 벤치마크 실행 (30초)	Run Built-in Benchmark (30 sec)	内蔵ベンチマークを実行（30秒）
설정	Settings	設定
Rearview 설정	Rearview Settings	Rearview設定
일반	General	一般
단축키	Shortcuts	ショートカット
화면 표시	Display	画面表示
캡처 및 OCR	Capture & OCR	キャプチャとOCR
개발자	Developer	開発者
시작 및 실행	Startup & Operation	起動と動作
macOS 시작 시 자동 실행	Launch at Login	ログイン時に起動
사용자 로그인 후 Rearview를 자동으로 실행합니다.	Automatically launches Rearview after you log in.	ログイン後にRearviewを自動的に起動します。
언어 및 번역	Language & Translation	言語と翻訳
표시 언어	Display Language	表示言語
앱의 메뉴, 설정 및 번역 UI에 사용할 언어를 선택합니다.	Choose the language used for app menus, settings, and translation UI.	アプリのメニュー、設定、翻訳UIで使用する言語を選択します。
번역 방향	Translation Direction	翻訳方向
화면에서 번역할 소스 언어와 결과 언어를 선택합니다.	Choose the source and output languages to translate on screen.	画面上で翻訳する原文言語と出力言語を選択します。
원문 외 텍스트 보호	Protect Non-Source Text	原文以外のテキストを保護
활성화하면 원문 언어 이외의 텍스트(영어·반대 언어·숫자)를 번역 대상에서 제외하고 원문 그대로 유지합니다. 번역은 분리된 텍스트 단위로 처리되므로 전체 문맥이 나뉠 수 있습니다. 비활성화하면 혼합된 텍스트 전체를 하나의 번역 단위로 처리해 문맥을 반영할 수 있지만, 영어·반대 언어·숫자도 번역되거나 변경될 수 있습니다.	When enabled, text outside the source language (English, the opposite language, and numbers) is excluded from translation and kept unchanged. Translation is performed in separate text units, so the overall context may be split. When disabled, the full mixed text is processed as one translation unit to preserve context, but English, the opposite language, and numbers may also be translated or changed.	有効にすると、原文言語以外のテキスト（英語・反対言語・数字）を翻訳対象から除外し、そのまま保持します。翻訳は分離されたテキスト単位で処理されるため、文全体の文脈が分かれる場合があります。無効にすると、混在したテキスト全体を1つの翻訳単位として処理し、文脈を反映しやすくなりますが、英語・反対言語・数字も翻訳または変更される場合があります。
설정 관리	Settings Management	設定管理
모든 설정 초기화	Reset All Settings	すべての設定をリセット
단축키, 표시 방식, 캡처 및 OCR 설정을 기본값으로 되돌립니다. macOS 시스템 권한은 변경하지 않습니다.	Restores shortcuts, display, capture, and OCR settings to defaults. macOS permissions are not changed.	ショートカット、表示、キャプチャ、OCR設定を初期値に戻します。macOSの権限は変更しません。
기본값으로 초기화…	Reset to Defaults…	初期値に戻す…
전역	Global	グローバル
전역 단축키	Global Shortcuts	グローバルショートカット
앱 단축키	App Shortcuts	アプリのショートカット
%@ 명령을 실행합니다.	Runs the %@ command.	%@コマンドを実行します。
앱 설정을 엽니다.	Opens the app settings.	アプリの設定を開きます。
현재 번역 세션과 화면 캡처를 종료합니다.	Ends the current translation session and screen capture.	現在の翻訳セッションと画面キャプチャを終了します。
현재 영역에서 캡처할 앱을 선택합니다.	Chooses the app to capture in the current area.	現在の範囲でキャプチャするアプリを選択します。
일→한과 한→일 번역 방향을 전환합니다.	Switches between Japanese-to-Korean and Korean-to-Japanese translation.	日本語→韓国語と韓国語→日本語の翻訳方向を切り替えます。
번역 결과를 별도 미러 창에 표시하거나 원래 영역 위에 오버레이로 표시합니다.	Shows translation results in a separate mirror window or as an overlay over the original area.	翻訳結果を別のミラーウィンドウに表示するか、元の範囲上にオーバーレイ表示します。
화면 변화를 감지해 자동으로 갱신하거나, 사용자가 직접 번역을 실행하는 방식으로 전환합니다.	Switches between automatic updates when the screen changes and user-triggered translation.	画面の変化を検知して自動更新するか、ユーザーが手動で翻訳を実行するかを切り替えます。
자동 갱신 모드에서는 번역을 일시정지하거나 재생하고, 수동 갱신 모드에서는 현재 영역을 즉시 번역합니다. 보조 키 없이 단일 키로 동작합니다.	In automatic refresh mode, pauses or resumes translation; in manual refresh mode, translates the current area immediately. Works as a single key without modifier keys.	自動更新モードでは翻訳を一時停止または再開し、手動更新モードでは現在の範囲をすぐに翻訳します。修飾キーなしの単一キーで動作します。
미러 모드에서는 항상 위를, 오버레이 모드에서는 선택 영역의 마우스 입력 통과/무시를 전환합니다.	In Mirror mode, toggles always-on-top; in Overlay mode, toggles passing or ignoring mouse input for the selected area.	ミラーモードでは常に手前に表示する設定を、オーバーレイモードでは選択範囲のマウス入力の通過／無視を切り替えます。
현재 인식된 텍스트와 번역문을 모두 선택합니다.	Selects all recognized text and translations.	認識されたテキストと翻訳文をすべて選択します。
선택한 텍스트를 클립보드에 복사합니다.	Copies the selected text to the clipboard.	選択したテキストをクリップボードにコピーします。
선택한 텍스트를 복사한 뒤 선택을 해제합니다.	Copies the selected text, then clears the selection.	選択したテキストをコピーしてから選択を解除します。
현재 결과의 텍스트와 번역문을 읽기 순서대로 모두 복사합니다.	Copies all current text and translations in reading order.	現在の結果のテキストと翻訳文を読み順にすべてコピーします。
현재 번역 영역의 이미지를 클립보드에 복사합니다.	Copies an image of the current translation area to the clipboard.	現在の翻訳範囲の画像をクリップボードにコピーします。
현재 인식된 텍스트와 번역문을 검색합니다.	Searches the currently recognized text and translations.	現在認識されているテキストと翻訳文を検索します。
번역 화면에서 인식된 텍스트를 선택할 수 있도록 선택 모드를 켜거나 끕니다.	Turns text selection mode on or off for recognized text in the translation display.	翻訳画面で認識されたテキストを選択できるよう、選択モードをオンまたはオフにします。
미러 창의 표시 배율을 낮춥니다.	Decreases the mirror window's display scale.	ミラーウィンドウの表示倍率を下げます。
미러 창의 표시 배율을 원본 크기 100%로 되돌립니다.	Restores the mirror window's display scale to 100% of the original size.	ミラーウィンドウの表示倍率を元のサイズの100%に戻します。
미러 창의 표시 배율을 높입니다.	Increases the mirror window's display scale.	ミラーウィンドウの表示倍率を上げます。
이미지 표시 크기는 유지한 채 미러 창의 남는 여백을 제거합니다.	Removes excess space from the mirror window while preserving the displayed image size.	表示画像のサイズを保ったまま、ミラーウィンドウの余白を取り除きます。
미러 창의 크기를 캡처 선택 영역의 크기에 맞춰 연동하거나 해제합니다.	Links or unlinks the mirror window size to the capture selection size.	ミラーウィンドウのサイズをキャプチャ範囲のサイズに連動または解除します。
OCR 인식 영역과 처리 상태를 화면에 표시하거나 숨깁니다.	Shows or hides OCR regions and processing status on screen.	OCR認識範囲と処理状態を画面に表示または非表示にします。
설정 열기	Open Settings	設定を開く
캡처 대상 선택	Choose Capture Target	キャプチャ対象を選択
표시 및 캡처	Display & Capture	表示とキャプチャ
번역 세션 제어	Translation Session Controls	翻訳セッションの操作
모드별 화면 동작 전환	Toggle Mode-Specific Display Action	モード別画面動作を切り替え
미러 모드에서는 항상 위를, 오버레이 모드에서는 선택 영역의 마우스 입력 통과/무시를 전환합니다.	In Mirror mode, toggles always-on-top; in Overlay mode, toggles passing or ignoring mouse input for the selected area.	ミラーモードでは常に手前に表示する設定を、オーバーレイモードでは選択範囲のマウス入力の通過／無視を切り替えます。
선택 복사	Copy Selection	選択範囲をコピー
복사 후 선택 해제	Copy and Deselect	コピーして選択解除
영역 선택	Select Area	範囲選択
새 번역 영역을 선택합니다.	Selects a new translation area.	新しい翻訳範囲を選択します。
즉시 번역	Translate Now	今すぐ翻訳
현재 영역을 즉시 캡처하고 번역합니다.	Immediately captures and translates the current area.	現在の範囲をすぐにキャプチャして翻訳します。
번역 표시 활성화	Activate Translation Display	翻訳表示をアクティブにする
현재 번역 표시를 활성화하고 조작 대상으로 만듭니다.	Activates the current translation display and makes it ready for interaction.	現在の翻訳表示をアクティブにして操作できるようにします。
제거	Remove	削除
단축키 제거	Remove Shortcut	ショートカットを削除
사용 안 함	Disabled	無効
새 단축키 입력…	Press New Shortcut…	新しいショートカットを入力…
사용 중 — 다시 입력	Already Used — Try Again	使用中 — もう一度入力
누른 뒤 새 키 조합을 입력합니다. Esc를 누르면 취소합니다.	Click, then press a new key combination. Press Esc to cancel.	クリックして新しいキーの組み合わせを入力します。Escでキャンセルします。
표시 방식	Display Mode	表示方式
번역 표시 모드	Translation Display Mode	翻訳表示モード
별도 미러창 또는 선택 영역 위 오버레이에 번역 결과를 표시합니다.	Show translations in a separate mirror window or as an overlay on the selected area.	翻訳結果を別のミラーウインドウまたは選択範囲上のオーバーレイに表示します。
미러	Mirror	ミラー
오버레이	Overlay	オーバーレイ
미러 창	Mirror Window	ミラーウインドウ
항상 위	Always on Top	常に手前に表示
항상 위 켜기	Enable Always on Top	常に手前に表示をオン
항상 위 끄기	Disable Always on Top	常に手前に表示をオフ
미러창을 항상 위에 두기	Keep Mirror Window on Top	ミラーウインドウを常に手前に表示
미러창을 항상 위에 두지 않기	Stop Keeping Mirror Window on Top	ミラーウインドウの常に手前表示を解除
미러창을 다른 창 위에 유지합니다. 설정값은 미러 모드에 적용됩니다.	Keeps the mirror window above other windows. This setting applies in mirror mode.	ミラーウインドウをほかのウインドウより手前に保ちます。この設定値はミラーモードに適用されます。
번역 배경 불투명도	Translation Background Opacity	翻訳背景の不透明度
번역 배경의 불투명도를 조절합니다. 설정값은 미러 모드에 적용됩니다.	Adjusts the translation background opacity. This setting applies in mirror mode.	翻訳背景の不透明度を調整します。この設定値はミラーモードに適用されます。
선택 영역 크기 연동	Follow Selection Size	選択範囲のサイズに追従
선택 영역 크기 연동 켜기	Enable Follow Selection Size	選択範囲のサイズ追従をオン
선택 영역 크기 연동 끄기	Disable Follow Selection Size	選択範囲のサイズ追従をオフ
영역 크기가 바뀌면 현재 확대 비율을 유지하여 미러창 크기를 맞춥니다. 설정값은 미러 모드에 적용됩니다.	Resizes the mirror window while preserving the current zoom when the selection changes. This setting applies in mirror mode.	選択範囲のサイズが変わると、現在の拡大率を保ったままミラーウインドウを調整します。この設定値はミラーモードに適用されます。
번역 표시 영역 불투명도	Translation Display Area Opacity	翻訳表示領域の不透明度
컨트롤 바 불투명도	Control Bar Opacity	コントロールバーの不透明度
컨트롤 바 배경의 불투명도를 조절합니다. 설정값은 오버레이 모드에 적용됩니다.	Adjusts the control bar background opacity. This setting applies in overlay mode.	コントロールバー背景の不透明度を調整します。この設定値はオーバーレイモードに適用されます。
비활성 번역 표시 영역 불투명도	Inactive Translation Display Area Opacity	非アクティブ時の翻訳表示領域の不透明度
활성 번역 표시 영역 불투명도	Active Translation Display Area Opacity	アクティブ時の翻訳表示領域の不透明度
비활성 컨트롤 바 불투명도	Inactive Control Bar Opacity	非アクティブ時のコントロールバーの不透明度
활성 컨트롤 바 불투명도	Active Control Bar Opacity	アクティブ時のコントロールバーの不透明度
Rearview가 비활성 상태일 때 캡처 이미지와 번역 결과가 표시되는 영역 전체의 불투명도입니다.	The opacity of the entire area displaying the captured image and translation results while Rearview is inactive.	Rearviewが非アクティブなときに、キャプチャ画像と翻訳結果が表示される領域全体の不透明度です。
Rearview가 활성 상태일 때 캡처 이미지와 번역 결과가 표시되는 영역 전체의 불투명도입니다.	The opacity of the entire area displaying the captured image and translation results while Rearview is active.	Rearviewがアクティブなときに、キャプチャ画像と翻訳結果が表示される領域全体の不透明度です。
Rearview가 비활성이고 마우스가 컨트롤 바 밖에 있을 때의 불투명도입니다.	The control bar opacity while Rearview is inactive and the pointer is outside the control bar.	Rearviewが非アクティブで、ポインタがコントロールバーの外にあるときの不透明度です。
Rearview가 활성 상태이거나 비활성 컨트롤 바에 마우스를 올렸을 때의 불투명도입니다.	The control bar opacity while Rearview is active or the pointer is over the inactive control bar.	Rearviewがアクティブなとき、または非アクティブなコントロールバーにポインタを重ねたときの不透明度です。
선택 영역 마우스 이벤트 무시	Ignore Mouse Events in Selection	選択範囲のマウスイベントを無視
마우스 입력을 가로채지 않고 아래 앱으로 전달합니다. 설정값은 오버레이 모드에 적용됩니다.	Passes mouse input to the app below instead of intercepting it. This setting applies in overlay mode.	マウス入力を遮らず、下のアプリへ渡します。この設定値はオーバーレイモードに適用されます。
선택 영역	Selection Area	選択範囲
영역 테두리 불투명도	Area Border Opacity	範囲枠線の不透明度
선택 영역 테두리와 이동 탭의 투명도를 조절합니다.	Adjusts the transparency of the selection border and move tab.	選択範囲の枠線と移動タブの透明度を調整します。
캡처	Capture	キャプチャ
화면 캡처 속도	Capture Frame Rate	画面キャプチャ速度
화면 변화를 확인할 초당 프레임 수입니다. 설정 범위는 1–30fps입니다.	Frames per second used to check for screen changes. Range: 1–30 fps.	画面の変化を確認する1秒あたりのフレーム数です。範囲は1～30fpsです。
타겟 앱 이동 추적	Track Target App Movement	対象アプリの移動を追跡
캡처 대상 앱 창이 이동하면 번역 영역도 함께 이동합니다.	Moves the translation area when the target app window moves.	キャプチャ対象アプリのウインドウが移動すると翻訳範囲も移動します。
갱신	Refresh	更新
OCR 최소 간격	Minimum OCR Interval	OCRの最小間隔
화면이 변해도 이 시간이 지난 뒤 다음 OCR을 시작합니다. 설정 범위는 100–2000ms입니다.	Waits this long before starting the next OCR after a screen change. Range: 100–2000 ms.	画面が変化しても、この時間が経過してから次のOCRを開始します。範囲は100～2000msです。
미러 갱신 방식	Mirror Update Style	ミラー更新方式
번역을 한 번에 표시하거나, 완료되는 줄부터 점진적으로 표시합니다.	Show translations all at once or progressively as lines complete.	翻訳を一度に表示するか、完了した行から順に表示します。
한 번에	All at Once	まとめて
점진 표시	Progressive	順次表示
OCR 실행 방식	OCR Execution	OCR実行方式
자동 모드	Automatic Mode	自動モード
수동 모드	Manual Mode	手動モード
자동 갱신에서 사용할 OCR 실행 흐름을 선택합니다.	Choose the OCR workflow for automatic refresh.	自動更新で使用するOCRの実行フローを選択します。
수동 실행에서 사용할 OCR 실행 흐름을 선택합니다.	Choose the OCR workflow for manual execution.	手動実行で使用するOCRの実行フローを選択します。
즉시 Refinement OCR	Refinement OCR Immediately	すぐにRefinement OCR
즉시 Realtime OCR	Realtime OCR Immediately	すぐにRealtime OCR
Refinement 실행 조건	Refinement Conditions	Refinement実行条件
항상 실행	Always Run	常に実行
일본어 줄의 신뢰도와 관계없이 보정 OCR을 실행합니다.	Run refinement OCR regardless of Japanese-line confidence.	日本語行の信頼度に関係なく補正OCRを実行します。
일본어 줄 신뢰도 <	Japanese Line Confidence <	日本語行の信頼度 <
일본어 줄이 이 값보다 낮은 경우 보정 OCR을 실행합니다.	Run refinement OCR when a Japanese line is below this value.	日本語行がこの値を下回る場合に補正OCRを実行します。
대기 시간	Wait Time	待機時間
화면 움직임이 멈춘 뒤 보정 OCR을 시작하기 전 대기 시간입니다.	Delay before refinement OCR starts after screen motion stops.	画面の動きが止まってから補正OCRを開始するまでの待機時間です。
OCR 언어 및 필터	OCR Language & Filtering	OCR言語とフィルター
인식 언어	Recognition Languages	認識言語
Vision OCR에 전달할 지원 언어 순서를 선택합니다.	Choose the supported language order passed to Vision OCR.	Vision OCRに渡す対応言語の順序を選択します。
일본어 → 한국어 → 영어	Japanese → Korean → English	日本語 → 韓国語 → 英語
한국어 → 일본어 → 영어	Korean → Japanese → English	韓国語 → 日本語 → 英語
설정 안 함	Not Set	設定しない
저신뢰도 라인 필터	Low-Confidence Line Filter	低信頼度行フィルター
일본어가 포함되지 않은 OCR 라인을 버릴 최소 confidence입니다. 0.00–1.00 범위이며 일본어 라인은 보호됩니다.	Minimum confidence for discarding OCR lines without Japanese. Range: 0.00–1.00; Japanese lines are preserved.	日本語を含まないOCR行を破棄する最小信頼度です。範囲は0.00～1.00で、日本語行は保護されます。
고급 OCR	Advanced OCR	詳細OCR
배율 1.0–3.0	Scale 1.0–3.0	倍率1.0～3.0
OCR 입력 이미지 확대 배율 (1.0–3.0배)	OCR input image scale (1.0–3.0×)	OCR入力画像の拡大倍率（1.0～3.0倍）
화면 움직임이 멈춘 뒤 refinement OCR을 시작할 때까지의 시간	Delay before refinement OCR starts after screen motion stops	画面の動きが止まってからrefinement OCRを開始するまでの時間
Text OCR · Accurate · Current. 실시간 입력 배율과 언어 보정 설정입니다.	Text OCR · Accurate · Current. Realtime input scale and language-correction settings.	Text OCR・Accurate・Current。リアルタイム入力倍率と言語補正の設定です。
Text OCR · Accurate · Current. 보정 입력 배율과 언어 보정 설정입니다.	Text OCR · Accurate · Current. Refinement input scale and language-correction settings.	Text OCR・Accurate・Current。補正入力倍率と言語補正の設定です。
진단 기능	Diagnostics	診断機能
디버그 기능	Debug Features	デバッグ機能
프로파일링·벤치마크 메뉴와 OCR Debug Overlay 버튼을 표시합니다.	Show profiling and benchmark menus and the OCR Debug Overlay button.	プロファイリングとベンチマークのメニュー、およびOCR Debug Overlayボタンを表示します。
설정을 초기화할까요?	Reset settings?	設定をリセットしますか？
단축키, 표시 방식, 캡처 및 OCR 설정이 모두 기본값으로 돌아갑니다.	All shortcuts, display, capture, and OCR settings will return to defaults.	ショートカット、表示、キャプチャ、OCR設定がすべて初期値に戻ります。
초기화	Reset	リセット
취소	Cancel	キャンセル
확인	OK	OK
일→한	JA→KO	日→韓
한→일	KO→JA	韓→日
번역 방향 전환	Switch Translation Direction	翻訳方向を切り替え
미러/오버레이 모드 전환	Switch Mirror/Overlay Mode	ミラー／オーバーレイモードを切り替え
자동/수동 갱신 전환	Switch Automatic/Manual Refresh	自動／手動更新を切り替え
일시정지/재생/즉시 번역	Pause/Resume/Translate Now	一時停止／再開／今すぐ翻訳
즉시 번역	Translate Now	今すぐ翻訳
전체 복사	Copy All	すべてコピー
이미지 복사	Copy Image	画像をコピー
선택 모드 전환	Toggle Selection Mode	選択モードを切り替え
마우스 통과/무시 전환	Toggle Mouse Pass-Through	マウス透過を切り替え
항상 위 전환	Toggle Always on Top	常に手前を切り替え
축소	Zoom Out	縮小
실제 크기	Actual Size	実際のサイズ
확대	Zoom In	拡大
여백 제거	Trim Empty Space	余白を削除
OCR 디버그 오버레이	OCR Debug Overlay	OCRデバッグオーバーレイ
번역 종료	Stop Translation	翻訳を終了
자동 실행 설정 실패	Could Not Change Launch Setting	自動起動設定を変更できませんでした
번역 영역을 사용한 뒤 메뉴에서 프로파일링을 종료하세요.	Use the translation area, then stop profiling from the menu.	翻訳範囲を使用した後、メニューからプロファイリングを終了してください。
활성 프로파일링 세션이 없습니다.	There is no active profiling session.	アクティブなプロファイリングセッションがありません。
아직 생성된 프로파일 결과가 없습니다.	No profile results have been created yet.	プロファイル結果はまだ作成されていません。
벤치마크 실행 중	Benchmark Running	ベンチマーク実行中
정적 화면, 스크롤, 장면 전환을 30초 동안 측정합니다.	Measuring static screens, scrolling, and scene changes for 30 seconds.	静止画面、スクロール、シーン切り替えを30秒間測定します。
실시간 번역을 시작할 수 없습니다	Could Not Start Live Translation	リアルタイム翻訳を開始できませんでした
화면 기록 권한이 필요합니다	Screen Recording Permission Required	画面収録の権限が必要です
Rearview는 선택한 화면 영역의 텍스트를 인식하고 번역합니다. 계속하려면 화면 기록 권한이 필요합니다.	Rearview recognizes and translates text in the selected screen area. Screen Recording permission is required to continue.	Rearviewは選択した画面範囲のテキストを認識して翻訳します。続けるには画面収録の権限が必要です。
계속	Continue	続ける
다시 확인	Check Again	もう一度確認
시스템 설정에서 Rearview의 화면 기록 권한을 켜 주세요.	Enable Screen Recording for Rearview in System Settings.	システム設定でRearviewの画面収録を有効にしてください。
시스템 설정 열기	Open System Settings	システム設定を開く
화면 기록 권한이 확인되었습니다	Screen Recording Access Confirmed	画面収録の権限を確認しました
%@을 눌러 번역할 화면 영역을 선택하세요. 메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작할 수도 있습니다.	Press %@ to select an area to translate. You can also choose “Select Area…” from the Rearview icon in the menu bar.	%@を押して、翻訳する画面範囲を選択してください。メニューバーのRearviewアイコンから「範囲を選択…」を選ぶこともできます。
메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작하세요.	Choose “Select Area…” from the Rearview icon in the menu bar to get started.	メニューバーのRearviewアイコンから「範囲を選択…」を選んで開始してください。
확인	OK	確認
BenchmarkFixture 실행 파일을 찾을 수 없습니다. 앱 번들을 다시 패키징하세요.	The BenchmarkFixture executable was not found. Package the app again.	BenchmarkFixture実行ファイルが見つかりません。アプリを再パッケージしてください。
드래그하여 영역 선택  ·  Esc로 취소	Drag to select an area  ·  Esc to cancel	ドラッグして範囲を選択・Escでキャンセル
화면 기록 권한이 필요합니다.	Screen Recording permission is required.	画面収録の権限が必要です。
캡처할 디스플레이를 찾을 수 없습니다.	No display is available to capture.	キャプチャするディスプレイが見つかりません。
캡처할 앱 ‘%@’을 찾을 수 없습니다. 앱이 실행 중인지 확인하세요.	The app “%@” is unavailable for capture. Make sure it is running.	キャプチャするアプリ「%@」が見つかりません。アプリが起動していることを確認してください。
일본어·한국어 번역 언어팩을 설치해야 합니다.	Install the Japanese–Korean translation language pack.	日本語・韓国語の翻訳言語パックをインストールしてください。
로컬 번역 세션을 준비하는 중입니다. 잠시 후 다시 시도하세요.	The local translation session is being prepared. Try again shortly.	ローカル翻訳セッションを準備しています。しばらくしてからもう一度お試しください。
한 모니터 안에서 충분한 크기의 영역을 선택하세요.	Select a sufficiently large area within one display.	1台のディスプレイ内で十分な大きさの範囲を選択してください。
벤치마크 성능 결과	Benchmark Performance Results	ベンチマーク性能結果
성능 프로파일 결과	Performance Profile Results	性能プロファイル結果
JSON 다른 이름으로 저장…	Save JSON As…	JSONを別名で保存…
CSV 다른 이름으로 저장…	Save CSV As…	CSVを別名で保存…
보고서 폴더 열기	Open Report Folder	レポートフォルダを開く
텍스트 인식 중	Recognizing Text	テキスト認識中
번역 중 %d/%d	Translating %d/%d	翻訳中 %d/%d
완료	Completed	完了
완료 · %d줄 실패	Completed · %d Lines Failed	完了・%d行失敗
텍스트 인식 실패	Text Recognition Failed	テキスト認識に失敗
일시정지	Paused	一時停止
자동 갱신 일시정지	Pause Automatic Refresh	自動更新を一時停止
대소문자	Case	大小文字
미러 텍스트 검색	Search Mirror Text	ミラーテキストを検索
검색 닫기	Close Search	検索を閉じる
텍스트 검색	Search Text	テキストを検索
번역 영역 이동	Move Translation Area	翻訳範囲を移動
캡처할 앱 선택	Choose Capture App	キャプチャするアプリを選択
미러 모드로 전환	Switch to Mirror Mode	ミラーモードに切り替え
오버레이 모드로 전환	Switch to Overlay Mode	オーバーレイモードに切り替え
갱신 모드 전환	Switch Refresh Mode	更新モードを切り替え
현재 영역 즉시 번역	Translate Current Area Now	現在の範囲を今すぐ翻訳
번역 영역 이미지 복사	Copy Translation Area Image	翻訳範囲の画像をコピー
텍스트 선택 모드	Text Selection Mode	テキスト選択モード
선택 영역 마우스 무시 안 하기	Accept Mouse Events in Selection	選択範囲でマウス操作を受け付ける
불투명도 조절	Adjust Opacity	不透明度を調整
모든 컨트롤	All Controls	すべてのコントロール
번역 방향: %@ (클릭하여 전환)	Translation Direction: %@ (Click to Switch)	翻訳方向：%@（クリックして切り替え）
번역 방향: %@	Translation Direction: %@	翻訳方向：%@
미러 모드	Mirror Mode	ミラーモード
오버레이 모드	Overlay Mode	オーバーレイモード
현재 오버레이 모드 · 미러로 전환	Overlay Mode · Switch to Mirror	現在オーバーレイモード・ミラーに切り替え
현재 미러 모드 · 오버레이로 전환	Mirror Mode · Switch to Overlay	現在ミラーモード・オーバーレイに切り替え
자동 갱신	Automatic Refresh	自動更新
수동 갱신	Manual Refresh	手動更新
자동	Auto	自動
수동	Manual	手動
자동 갱신 · 클릭하여 수동으로 전환	Automatic Refresh · Click for Manual	自動更新・クリックして手動に切り替え
수동 갱신 · 클릭하여 자동으로 전환	Manual Refresh · Click for Automatic	手動更新・クリックして自動に切り替え
자동 갱신 재개	Resume Automatic Refresh	自動更新を再開
텍스트 선택 모드 끄기	Turn Off Text Selection	テキスト選択モードをオフ
텍스트 선택 모드 켜기	Turn On Text Selection	テキスト選択モードをオン
마우스 무시 안 함 · 클릭하여 무시	Accepting Mouse Input · Click to Ignore	マウス操作を受付中・クリックして無視
마우스 무시 중 · 클릭하여 무시 안 함	Ignoring Mouse Input · Click to Accept	マウス操作を無視中・クリックして受け付ける
마우스 무시 안 하기 켜짐	Mouse Input Enabled	マウス操作の受付オン
마우스 무시 안 하기 꺼짐	Mouse Input Disabled	マウス操作の受付オフ
마우스 무시 안 하기	Accept Mouse Input	マウス操作を受け付ける
모든 앱	All Apps	すべてのアプリ
오버레이 컨트롤	Overlay Controls	オーバーレイコントロール
캡처 앱	Capture App	キャプチャアプリ
갱신 모드	Refresh Mode	更新モード
재개	Resume	再開
불투명도 조절…	Adjust Opacity…	不透明度を調整…
불투명도	Opacity	不透明度
번역 배경	Translation Background	翻訳背景
컨트롤 바	Control Bar	コントロールバー
비활성 번역 표시 영역	Inactive Translation Display Area	非アクティブ時の翻訳表示領域
활성 번역 표시 영역	Active Translation Display Area	アクティブ時の翻訳表示領域
비활성 컨트롤 바	Inactive Control Bar	非アクティブ時のコントロールバー
활성 컨트롤 바	Active Control Bar	アクティブ時のコントロールバー
선택 영역 테두리	Selection Border	選択範囲の枠線
복사됨	Copied	コピーしました
이미지 복사됨	Image Copied	画像をコピーしました
이미지 저장	Save Image	画像を保存
이미지 저장 실패	Image Save Failed	画像の保存に失敗しました
이미지 저장 폴더	Image Save Folder	画像の保存フォルダ
이미지 저장 시 사용할 폴더입니다.	The folder used when saving images.	画像の保存に使用するフォルダです。
이미지 파일명 규칙	Image Filename Template	画像ファイル名テンプレート
{yyyy}, {MM}, {dd}, {HH}, {mm}, {ss}, {counter} 토큰을 사용할 수 있습니다.	You can use the {yyyy}, {MM}, {dd}, {HH}, {mm}, {ss}, and {counter} tokens.	{yyyy}、{MM}、{dd}、{HH}、{mm}、{ss}、{counter}トークンを使用できます。
저장됨 · %@	Saved · %@	保存済み · %@
Finder에서 파일 보기	Show File in Finder	Finderでファイルを表示
이미지를 PNG로 변환할 수 없습니다.	Could not convert the image to PNG.	画像をPNGに変換できません。
저장 폴더를 만들 수 없습니다: %@	Could not create the save folder: %@	保存フォルダを作成できません：%@
파일명 규칙이 비어 있습니다.	The filename template is empty.	ファイル名テンプレートが空です。
번역 미러	Translation Mirror	翻訳ミラー
%d개	%d	%d件
번역 실행	Translation Actions	翻訳操作
결과	Results	結果
크기	Size	サイズ
표시 모드	Display Mode	表示モード
캡처 대상	Capture Target	キャプチャ対象
타깃 앱 캡처	Capture Target App	対象アプリをキャプチャ
미러 축소	Zoom Mirror Out	ミラーを縮小
미러를 원본 크기 100%로 복원	Restore Mirror to 100% Original Size	ミラーを元のサイズ100%に戻す
미러 확대	Zoom Mirror In	ミラーを拡大
현재 이미지 크기는 유지하고 창의 남는 여백 제거	Trim empty window space while keeping the current image size	現在の画像サイズを保ったままウインドウの余白を削除
현재 영역을 즉시 캡처하고 번역	Immediately capture and translate the current area	現在の範囲をすぐにキャプチャして翻訳
번역문과 OCR 원문 전체를 화면 순서대로 복사	Copy all translations and OCR source text in screen order	翻訳文とOCR原文を画面順にすべてコピー
번역 영역 이미지를 클립보드에 복사	Copy the translation area image to the clipboard	翻訳範囲の画像をクリップボードにコピー
번역 표시 영역 불투명도 조절	Adjust Translation Display Area Opacity	翻訳表示領域の不透明度を調整
현재 표시 모드의 불투명도 조절	Adjust opacity for the current display mode	現在の表示モードの不透明度を調整
OCR Debug Overlay 표시	Show OCR Debug Overlay	OCR Debug Overlayを表示
명령 구분	Command Separator	コマンド区切り
일시정지 · 최신 화면 갱신 재개	Paused · Resume Latest Screen Refresh	一時停止・最新画面の更新を再開
번역 방향: %@ · 클릭하여 전환	Translation Direction: %@ · Click to Switch	翻訳方向：%@・クリックして切り替え
현재 자동 갱신 · 수동으로 전환	Automatic Refresh · Switch to Manual	現在自動更新・手動に切り替え
현재 수동 갱신 · 자동으로 전환	Manual Refresh · Switch to Automatic	現在手動更新・自動に切り替え
영역에 보이는 앱이 없습니다	No Apps Visible in Area	範囲内に表示されているアプリはありません
영역에 보이는 앱 중 캡처 대상 선택	Choose a visible app in the area to capture	範囲内に表示されているアプリからキャプチャ対象を選択
항상 위 켜짐	Always on Top On	常に手前オン
항상 위 꺼짐	Always on Top Off	常に手前オフ
항상 위 켜짐 · 클릭하여 끄기	Always on Top On · Click to Turn Off	常に手前オン・クリックしてオフ
항상 위 꺼짐 · 클릭하여 켜기	Always on Top Off · Click to Turn On	常に手前オフ・クリックしてオン
선택 영역 크기 연동 켜짐	Follow Selection Size On	選択範囲サイズ追従オン
선택 영역 크기 연동 꺼짐	Follow Selection Size Off	選択範囲サイズ追従オフ
OCR Debug Overlay 켜짐	OCR Debug Overlay On	OCR Debug Overlayオン
OCR Debug Overlay 꺼짐	OCR Debug Overlay Off	OCR Debug Overlayオフ
선택 모드 켜짐	Selection Mode On	選択モードオン
선택 모드 꺼짐	Selection Mode Off	選択モードオフ
선택 모드 켜짐 · 클릭하여 끄기	Selection Mode On · Click to Turn Off	選択モードオン・クリックしてオフ
선택 모드 켜기	Turn On Selection Mode	選択モードをオン
선택 모드	Selection Mode	選択モード
미러 텍스트	Mirror Text	ミラーテキスト
전체 선택	Select All	すべて選択
복사	Copy	コピー
선택 해제	Clear Selection	選択を解除
인식 텍스트	Recognized Text	認識テキスト
최소 높이	Min Height	最小高さ
배율	Scale	倍率
언어 보정	Correction	言語補正
언어 자동 판별	Auto Language	言語を自動判定
후보 없음	No Candidate	候補なし
낮은 신뢰도	Low Confidence	低信頼度
비일본어	Non-Japanese	日本語以外
번역 대기 중	Translation Pending	翻訳待機中
번역 실패	Translation Failed	翻訳失敗
성공	Success	成功
상태              %@	Status              %@	状態                %@
원문              %@	Raw Text            %@	原文                %@
신뢰도            %@	Confidence          %@	信頼度              %@
후보              %@	Candidate           %@	候補                %@
언어              %@	Language            %@	言語                %@
Vision 인식 언어  %@	Vision Languages    %@	Vision認識言語      %@
번역              %@	Translation         %@	翻訳                %@
번역문            %@	Translated Text     %@	翻訳文              %@
측정 시간: %@초	Duration: %@ sec	測定時間：%@秒
선택 영역: %d × %d px	Selection: %d × %d px	選択範囲：%d × %d px
단계                         count    p50       p95       max       total	Stage                         count    p50       p95       max       total	ステージ                     count    p50       p95       max       total
프레임 수신: %d, 손실/교체: %d	Frames Received: %d, Dropped/Replaced: %d	受信フレーム：%d、損失／置換：%d
번역 캐시 적중률: %@%%	Translation Cache Hit Rate: %@%%	翻訳キャッシュヒット率：%@%%
단일 앱	Single App	単一アプリ
선택 영역 전체	Entire Selection	選択範囲全体
캡처 필터: %@	Capture Filter: %@	キャプチャフィルター：%@
개선 제안	Recommendations	改善提案
내장 벤치마크 보고서에는 고정 공개 샘플의 OCR 원문이 포함됩니다. 번역문과 캡처 이미지는 포함되지 않습니다.	Built-in benchmark reports include OCR source text from fixed public samples. Translations and captured images are not included.	内蔵ベンチマークレポートには固定公開サンプルのOCR原文が含まれます。翻訳文とキャプチャ画像は含まれません。
보고서에는 OCR 원문, 번역문 또는 캡처 이미지가 포함되지 않습니다.	The report does not include OCR source text, translations, or captured images.	レポートにはOCR原文、翻訳文、キャプチャ画像は含まれません。
화면 이미지 변환	Screen Image Conversion	画面画像変換
실시간 OCR	Realtime OCR	リアルタイムOCR
보정 OCR	Refinement OCR	補正OCR
일본어 판별	Japanese Detection	日本語判定
번역 큐 대기	Translation Queue Wait	翻訳キュー待機
번역 모델	Translation Model	翻訳モデル
미러 프레임 교체	Mirror Frame Replacement	ミラーフレーム更新
미러 텍스트 뷰 조정	Mirror Text View Reconcile	ミラーテキストビュー調整
미러 텍스트 배치	Mirror Text Layout	ミラーテキスト配置
미러 그리기	Mirror Drawing	ミラー描画
화면 변화→표시	Screen Change→Display	画面変化→表示
OCR이 가장 큰 비중을 차지합니다. 미러의 프레임 일관성을 유지하면서 OCR 주기와 번역 캐시 적중률을 조정하세요.	OCR is the largest cost. Adjust the OCR interval and translation-cache hit rate while preserving mirror frame consistency.	OCRが最大の負荷です。ミラーのフレーム整合性を保ちながら、OCR間隔と翻訳キャッシュのヒット率を調整してください。
번역 큐 대기가 큽니다. 원자적 미러 배치를 유지하면서 문장·segment 캐시 적중률을 확인하세요.	Translation queue wait is high. Check sentence and segment cache hit rates while preserving atomic mirror updates.	翻訳キューの待機が大きくなっています。ミラーの一括更新を保ちながら、文とsegmentキャッシュのヒット率を確認してください。
보정 OCR 비중이 높습니다. 안정 화면당 1회 제한과 저신뢰 ROI 조건을 확인하세요.	Refinement OCR cost is high. Check the once-per-stable-screen limit and low-confidence ROI conditions.	補正OCRの比率が高くなっています。安定画面ごとの1回制限と低信頼度ROI条件を確認してください。
화면 이미지 변환 비용이 높습니다. CVPixelBuffer 직접 처리와 저해상도 추적 버퍼를 검토하세요.	Screen-image conversion is expensive. Consider direct CVPixelBuffer processing and a low-resolution tracking buffer.	画面画像の変換コストが高くなっています。CVPixelBufferの直接処理と低解像度追跡バッファを検討してください。
미러 그리기가 프레임 예산을 넘습니다. 이미지 합성과 창 크기를 줄이는 것을 검토하세요.	Mirror drawing exceeds the frame budget. Consider reducing image composition work and window size.	ミラー描画がフレーム予算を超えています。画像合成処理とウインドウサイズの縮小を検討してください。
미러 텍스트 배치가 4ms를 넘습니다. 레이아웃 캐시와 충돌 후보 수를 확인하세요.	Mirror text layout exceeds 4 ms. Check the layout cache and number of collision candidates.	ミラーテキスト配置が4msを超えています。レイアウトキャッシュと衝突候補数を確認してください。
프레임 손실률이 15%를 넘습니다. 최신 프레임 처리량보다 캡처 해상도·빈도가 높습니다.	Frame loss exceeds 15%. Capture resolution or frequency is higher than the latest-frame processing capacity.	フレーム損失率が15%を超えています。キャプチャ解像度または頻度が最新フレームの処理能力を上回っています。
단일 지배 병목이 없습니다. end-to-end p95가 큰 세션을 더 길게 측정하세요.	There is no single dominant bottleneck. Measure longer sessions with high end-to-end p95.	単一の支配的なボトルネックはありません。end-to-end p95が高いセッションをより長く測定してください。
"""
}
