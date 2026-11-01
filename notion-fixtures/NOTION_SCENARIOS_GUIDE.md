# NotionScenarios 화면 사용법

NotionScenarios는 테스트용 Notion 문서의 **화면 상태**를 JSON으로 저장하고 다시 적용하는 macOS 앱입니다. 문서 본문을 만드는 도구는 아닙니다. 문서 생성·복구는 별도의 `./notion-fixtures/fixture ensure` / `reset` 명령이 맡습니다.

## 처음 사용할 때

1. 저장소 루트에서 `./notion-fixtures/fixture ensure`를 실행해 테스트 문서를 준비합니다. `ntn` 설치와 로그인이 필요합니다. 기존 문서가 준비되어 있다면 이 단계는 생략합니다.
2. 저장소 루트에서 앱을 빌드하고 엽니다.

   ```sh
   ./scripts/package_notion_scenarios.sh
   open dist/NotionScenarios.app --args --root "$PWD/notion-fixtures"
   ```

3. 앱 왼쪽 위에 `notion-fixtures` 경로가 표시되는지 확인합니다. 비어 있다면 **Choose fixture folder…**에서 이 저장소의 `notion-fixtures` 폴더를 선택합니다.
4. macOS가 요청하면 NotionScenarios에 **손쉬운 사용**과 **화면 및 시스템 오디오 녹음** 권한을 부여합니다. 터미널에서 CLI로 실행할 때는 터미널의 권한이 별도로 필요할 수 있습니다.

## 화면의 각 부분

| 위치 | 항목 | 기능 |
| --- | --- | --- |
| 왼쪽 | **Choose fixture folder…** | `fixture` 실행 파일과 정의가 있는 `notion-fixtures` 폴더를 선택합니다. 선택 경로는 앱의 macOS 사용자 기본 설정에 기억됩니다. |
| 왼쪽 | **Document** | 시나리오가 속할 테스트 문서(Fixture)를 고릅니다. 아래 목록은 해당 문서의 시나리오만 보여줍니다. |
| 왼쪽 | 시나리오 목록 | 저장된 시나리오를 선택해 JSON을 편집기에 불러옵니다. 이름, ID, 버전이 표시됩니다. |
| 왼쪽 | **New scenario ID** | 새 시나리오의 파일 이름이 될 ID를 입력합니다. 소문자 영문·숫자로 시작하고 이후 소문자 영문·숫자·하이픈을 쓸 수 있습니다. 전체 시나리오에서 고유해야 합니다. |
| 왼쪽 | **Create** | 선택한 문서용 기본 시나리오 JSON을 편집기에 만듭니다. 이때는 **초안만** 만들어지며 **Save**를 눌러야 파일이 생깁니다. |
| 왼쪽 | **Duplicate** | 현재 편집기에 보이는 JSON을 새 ID와 버전 1로 복사해 초안을 만듭니다. **Save**를 눌러야 파일이 생깁니다. |
| 왼쪽 | **Save current Notion screen** | 현재 열려 있는 해당 Notion 문서의 화면을 관측해 **새 ID**의 시나리오로 저장합니다. 실행 결과와 화면 캡처도 만듭니다. 기존 시나리오를 덮어쓰는 버튼이 아닙니다. |
| 왼쪽 | **Refresh** | 디스크의 문서·시나리오 목록을 다시 읽습니다. 편집 중인 JSON을 저장하지 않습니다. |
| 오른쪽 | **Scenario definition (JSON)** | 선택하거나 만든 시나리오의 요청 상태를 직접 편집합니다. 여기서 고친 내용은 **Save** 전까지 편집기에만 있습니다. |
| 오른쪽 | **Save** | 편집기 JSON을 검사하고 `scenarios/` 아래에 저장합니다. 같은 ID의 파일이 있으면 덮어쓰고 버전이 1 증가합니다. |
| 오른쪽 | **Delete** | 목록에서 선택한 시나리오 JSON 파일을 삭제합니다. 별도 확인 창이 없으므로 ID를 확인한 뒤 누르세요. 과거 실행 기록은 삭제하지 않습니다. |
| 오른쪽 | **Apply saved scenario** | 선택한 **저장본**을 현재 Notion 화면에 적용하고 결과를 기록합니다. 편집기에 저장하지 않은 변경이 있으면 버튼이 비활성화됩니다. |

**Create**나 **Duplicate**는 현재 편집기의 내용을 새 초안으로 바꿉니다. 작업 중이던 JSON을 유지하려면 먼저 **Save**하세요. **Save current Notion screen**은 편집기 내용 대신 실제 Notion 화면을 읽으며, 해당 문서가 Notion에서 열려 있어야 합니다.

## 가장 흔한 작업 순서

### 정해 둔 화면을 다시 만들기

1. **Document**에서 문서를 고르고 목록에서 시나리오를 선택합니다.
2. JSON을 바꿨다면 **Save**를 누릅니다.
3. Notion 데스크톱에서 대상 문서를 열고 **Apply saved scenario**를 누릅니다.
4. 아래 **Progress & item results**에서 각 단계와 오류를 확인하고 **Screenshot**에서 결과를 확인합니다.

### 지금 보이는 화면을 새 시나리오로 남기기

1. Notion 데스크톱에서 해당 테스트 문서를 열고 원하는 창 위치·크기, 사이드바, 스크롤, 토글 상태를 만듭니다.
2. 앱에서 **Document**를 맞추고 **New scenario ID**에 사용하지 않은 ID를 입력합니다.
3. **Save current Notion screen**을 누릅니다. 화면 관측과 캡처가 성공하고 저장 가능한 상태라면 시나리오 JSON이 자동으로 생성됩니다. 실패하면 결과 탭의 `status`와 `captureSaveError`를 확인합니다.
4. 목록에서 새 항목을 선택해 저장된 JSON을 확인합니다. 현재 화면 저장은 관측 가능한 값만 기록합니다. 줌 수치는 저장하지 않으며, 화면 밖 토글이나 여러 블록에 걸친 선택 상태는 추정하지 않습니다.

### 새 요청 상태를 직접 만들기

**Document**와 새 ID를 고른 뒤 **Create** → JSON 수정 → **Save** → **Apply saved scenario** 순서로 진행합니다. 기존 설정을 바탕으로 만들려면 목록에서 원본을 선택하고 새 ID를 입력한 뒤 **Duplicate** → **Save**를 사용합니다.

## JSON에서 자주 바꾸는 값

`state.window`는 창의 `x`, `y`, `width`, `height`를 macOS 화면 왼쪽 위 기준 **포인트(pt)**로 지정합니다. `sidebarOpen`은 사이드바 열림 여부입니다. `scroll`의 `{"mode":"top"}`은 문서 맨 위를 요청하고, `anchor` 모드는 문서 원문에서 고유한 문구를 찾아 화면 상단에서 지정한 `offset`만큼 떨어진 위치로 맞춥니다. `toggles`는 고유 문구로 찾은 토글의 `expanded` 상태를 지정합니다. `focus`는 `clear` 또는 한 텍스트 요소 안의 `selection`입니다. `required`는 성공 판정에 반드시 검증되어야 할 항목입니다.

`fixtureId`는 대상 문서, `fixtureVersion`은 문서 정의의 해시입니다. 문서 정의가 바뀌면 이전 시나리오가 자동으로 새 문서에 적용되지 않습니다. 문서와 시나리오를 검토한 뒤 갱신해야 합니다. 전체 형식과 좌표·제약은 [화면 시나리오 기술 문서](SCREEN_SCENARIOS.md#정의와-좌표)에 있습니다.

## 결과 탭과 저장 위치

| 데이터 | 저장 위치 | 의미 |
| --- | --- | --- |
| 시나리오 정의 | `notion-fixtures/scenarios/<문서-ID>/<시나리오-ID>.json` | **Save** 또는 성공한 현재 화면 저장으로 생성됩니다. Git으로 공유할 수 있는 요청 상태입니다. |
| 실행 기록 | `notion-fixtures/runs/<실행-ID>/` | **Apply saved scenario** 또는 **Save current Notion screen**을 실행할 때마다 새 폴더를 만듭니다. `result.json`은 상태·단계별 결과·관측값, `request.json`은 실행 요청, `screen.png`는 캡처 성공 시 실제 이미지입니다. `runs/`는 Git에서 제외됩니다. |
| Fixture의 Notion 페이지 ID·상태 | `notion-fixtures/state.json` | `fixture ensure`가 관리하는 개발자별 로컬 정보입니다. 시나리오 적용은 여기서 대상 페이지를 조회합니다. Git에서 제외됩니다. |
| 실제 테스트 문서 | 로그인한 Notion 워크스페이스의 **Notion AX Fixtures** 아래 | `fixture ensure`가 만들고 `reset`이 복구합니다. 시나리오 적용은 화면을 조작하며 문서 본문을 저장하거나 수정하지 않습니다. |
| 마지막 선택 폴더 | 이 Mac의 앱 사용자 기본 설정 | **Choose fixture folder…**로 선택한 경로입니다. 시나리오 JSON이나 실행 결과가 여기에 저장되는 것은 아닙니다. |

**Progress & item results**는 단계별 상태·오류·시간과 실행 로그를 보여줍니다. **Requested / observed JSON**은 요청값과 실제 관측값을 비교할 수 있는 전체 결과입니다. **Screenshot**은 `screen.png`를 보여주며 **Open run folder**로 해당 실행 폴더를 엽니다. 화면 캡처 단계가 실패하면 이미지가 없을 수 있습니다.

전체 상태 `verified`는 필수 항목을 모두 확인한 경우, `partial`은 일부만 확인된 경우, `failed`는 재현을 안전하게 마치지 못한 경우입니다. Notion의 숫자 줌 배율은 현재 검증할 수 없어 줌이 포함된 시나리오는 `partial`이 될 수 있습니다. 결과의 단계별 `detail`을 함께 확인하세요.

## 문제가 생기면

- **적용 버튼이 회색:** 저장하지 않은 JSON 변경이 있는지 확인하고 **Save**를 누릅니다. 목록에서 시나리오를 선택해야 합니다.
- **권한 오류:** 결과에 `accessibility_permission` 또는 `screen_capture_permission`이 표시되면 앱에 나타나는 **Accessibility settings…** / **Screen Recording settings…** 버튼으로 macOS 설정을 열어 권한을 켭니다.
- **Fixture가 준비되지 않았거나 문서가 바뀜:** 별도로 `./notion-fixtures/fixture ensure`를 실행합니다. 복구가 필요한 문서 수정 사실을 알고 있다면 `reset`을 사용합니다. 시나리오의 `fixtureVersion`도 현재 정의와 일치해야 합니다.
- **화면 저장은 실행됐지만 JSON이 없음:** 결과 JSON의 `captureSaveError`, `status`, `savedScenario`를 확인합니다. 실행 기록은 `runs/`에 남을 수 있습니다.
- **대상 창을 찾지 못함:** 해당 Fixture 페이지를 Notion 데스크톱에서 열고, 같은 페이지가 여러 창에 열려 있다면 하나만 남깁니다. 실행 중에는 다른 창으로 전환하지 않습니다.
