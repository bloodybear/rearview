# Notion 화면 시나리오

문서 Fixture와 화면 상태를 분리해 관리한다. 기존 `ensure`/`reset`/`list` 동작은 그대로다. 화면 재현은 문서 원문·서식을 수정하지 않으며, `ensure`를 자동 실행하지 않는다. 문서가 변경되었으면 별도로 복구한 뒤 시나리오를 적용한다.

## 실행

저장소 루트에서:

```sh
./scripts/package_notion_scenarios.sh
open dist/NotionScenarios.app --args --root "$PWD/notion-fixtures"
```

macOS 15 이상, Swift 6.2 이상, 기존 `ntn login`과 생성 완료된 Fixture가 필요하다. 패키징은 로컬 `Rearview Development` 인증서를 사용한다. 다른 인증서는 `NOTION_SCENARIOS_SIGNING_IDENTITY`로 지정한다. 앱 자체는 Rearview와 독립된 bundle ID를 사용하며, 개발용 로컬 서명이다.

시스템 설정 → 개인정보 보호 및 보안에서 실행 주체의 **손쉬운 사용**과 **화면 및 시스템 오디오 녹음** 권한이 필요하다. 권한을 자동으로 부여하거나 우회하지 않는다. CLI를 터미널에서 실행할 때는 macOS가 해당 터미널을 실행 주체로 표시할 수도 있다.

앱에서 `notion-fixtures` 폴더를 선택하고 문서별 시나리오를 고른다. 새 ID를 입력한 뒤 생성·복제하거나 현재 Notion 화면을 저장할 수 있다. JSON 편집기에서 값을 수정하고 저장한다. 저장하지 않은 수정이 있으면 적용 버튼이 비활성화된다. 저장할 때 시나리오 버전이 증가한다. 진행 탭은 항목별 상태·오류·시간, 결과 탭은 요청/관측 JSON, 스크린샷 탭은 실제 캡처를 보여준다.

```sh
./notion-fixtures/fixture scenario list
./notion-fixtures/fixture scenario apply layout-default --json
./notion-fixtures/fixture scenario capture layout-stress --id my-current-screen --json
./notion-fixtures/fixture scenario save /path/to/scenario.json
./notion-fixtures/fixture scenario delete my-current-screen
```

CLI 기본 실행 파일은 `dist/NotionScenarios.app/Contents/MacOS/NotionScenarios`다. 개발 중에는 `NOTION_SCENARIO_EXECUTABLE`로 다른 빌드를 지정할 수 있다. GUI와 CLI 모두 같은 Python 사전 검사와 Swift 실행 모듈을 사용한다.

## 정의와 좌표

`scenarios/<fixture-id>/<scenario-id>.json`은 Git으로 공유한다. 실제 페이지 ID는 기존 로컬 `state.json`에서 조회한다. `fixtureVersion`은 기존 문서 정의의 `source_hash` SHA-256이며, 변경되면 묵시적으로 재지정하지 않고 중단한다. 기존 시나리오를 검토하고 해당 해시를 갱신해 저장한다. 원격 문서가 baseline과 다르거나 관리 루트 밖으로 이동해도 재현하지 않는다.

```json
{
  "schemaVersion": 1,
  "id": "example",
  "name": "基準画面",
  "version": 1,
  "fixtureId": "layout-stress",
  "fixtureVersion": "<현재 Fixture source_hash, 64자리 hex>",
  "state": {
    "coordinateSystem": "screen-top-left-points",
    "window": {"x": 0, "y": 60, "width": 1024, "height": 700},
    "sidebarOpen": false,
    "scroll": {"mode": "top"},
    "focus": {"mode": "clear"},
    "required": ["target", "window", "sidebar", "scroll", "focus", "screenshot", "finalState"]
  }
}
```

화면 좌표는 주 디스플레이 왼쪽 위 원점, 오른쪽/아래쪽이 양수인 **points**다. 왼쪽 또는 위쪽의 보조 디스플레이는 음수 좌표를 가질 수 있다. 창 프레임에는 제목 표시줄을 포함한다. 요청 프레임이 디스플레이의 작업 영역에 들어가지 않으면 임의로 줄이지 않고 실패한다. 프레임과 스크롤 오프셋 허용 오차는 2pt다.

스크롤은 다음 두 모드다.

- `{"mode":"top"}`: 본문에 위쪽 스크롤을 보내고 실제 페이지 제목의 가시 위치가 더 이상 변하지 않는지 확인한다. 짧은 아래/위 이동도 관측해 스크롤 입력이 무시된 상태를 성공으로 오인하지 않는다. 스크롤할 여지가 없는 짧은 문서는 이 이동을 검증할 수 없어 미검증으로 남을 수 있다. 블록 식별이 필요하지 않다.
- `{"mode":"anchor","anchor":{"text":"고유한 원문"},"offset":80}`: 원본의 고유 문구를 현재 AX 트리 또는 Notion 찾기 UI로 찾아 viewport 상단에서 80pt 아래로 맞춘다. 절대 스크롤량은 이동 수단일 뿐 저장 기준이 아니다.

`anchor`는 `text`와 선택적인 `blockClass`, `ancestorText`를 받는다. v1은 보수적으로 원본 파일에서 문구가 정확히 한 번 나오는 경우만 허용한다. 동일 문구를 여러 번 쓰는 문서는 다른 고유 문구를 기준으로 선택한다. AX에서 여러 요소가 일치하면 임의로 하나를 고르지 않는다. 문구가 접힌 토글 안에 있으면 필요한 상위 토글을 시나리오에 먼저 명시한다.

부분 잘림은 음수 오프셋으로 요청한다. 먼저 동일 요소가 완전히 보이는 상태에서 높이를 측정하고, 잘린 상태의 하단과 측정 높이로 상단 오프셋을 계산한다. `observedGeometry`에 측정 당시 프레임, 최종 잘린 프레임과 viewport를 남긴다. 이는 실행 중 동일 요소의 기하 관측이며, 기대 텍스트 box 정답을 생성하는 기능이 아니다. 전체 높이를 측정하지 못하거나 목표 위치를 검증하지 못하면 성공 처리하지 않는다.

토글은 `toggles: [{"anchor":{"text":"開く前に見えている見出し","blockClass":"notion-toggle-block"},"expanded":true}]`로 요청한다. 공개 AX의 disclosure 버튼 `AXExpanded`를 읽고 목표 상태와 다를 때만 누른다. 원문을 교체하지 않는다.

포커스는 `clear` 또는 `selection`이다. `selection`은 `anchor`, `location`, `length`를 가지며 오프셋은 원본 한 텍스트 요소 안의 UTF-16 code units다. 여러 블록에 걸친 선택은 지원하지 않는다. 선택 적용 후 스크롤이 달라지면 최종 검증이 실패한다.

## 관측, 결과와 제약

대상 URL과 창을 확인한 후 창·줌·사이드바·토글을 적용하고, 레이아웃 안정화를 관측한 뒤 스크롤과 포커스를 맞춘다. 입력 직후 성공으로 기록하지 않고 상태를 연속 관측한다. 항목별 시도는 최대 10초, timeout 재시도는 최대 2회다. CLI 전체는 API 검사와 후처리를 포함해 120초 예산을 사용하며 native subprocess에도 남은 예산을 전달한다. 공개 AX 호출과 캡처가 반환하지 않으면 subprocess watchdog이 종료하고 실패를 기록한다.

- **verified**: 모든 필수 항목이 검증됐고 실행한 항목에 실패·미지원이 없다.
- **partial**: 일부 항목은 검증됐으나 실패·미지원·확인 불가능한 항목이 남았다.
- **failed**: 대상 확인·사전 검사·문서 무결성 검사 등이 실패해 안전한 재현을 완료하지 못했다.

시스템 입력 중 다른 앱/창으로 전환되거나 대상 페이지가 바뀌면 중단한다. 동시에 여러 화면 실행을 하지 않도록 기존 상태 파일 lock을 실행 동안 유지한다. 같은 문서가 여러 창에 열려 있으면 임의 선택하지 않는다. 문서 API의 404는 삭제로 단정하지 않고 `missing_or_inaccessible`로 기록한다.

Notion **7.27.0**에서 확인한 제약:

- `AXDOMIdentifier`의 `:rjc:` 같은 값은 스크롤로 요소가 사라졌다 돌아오면 바뀐다. 저장하지 않는다. Notion API 블록 UUID도 해당 AX 노드에 노출되지 않는다.
- 공개 메뉴에 Actual Size / Zoom In / Zoom Out은 있으나 현재 숫자 배율은 읽을 수 없다. 100% 요청은 Actual Size, 125% 요청은 Actual Size 후 Zoom In을 시도하지만 **실제 수치를 검증했다고 기록하지 않는다**. 125% 요청이 실제 125%라는 보장도 없다. 초기 줌 시나리오의 전체 결과는 `partial`이다. 후속 과제는 공개 UI가 숫자 배율을 노출하는지 새 Notion 버전에서 재확인하는 것이다.
- 메뉴·찾기·사이드바의 영문 접근성 라벨을 사용하는 버전에서 검증했다. 다른 언어/앱 버전에서 찾지 못하면 미지원 또는 timeout을 표시한다. 내부 DOM/CDP 연결이나 비공개 API는 쓰지 않는다.
- 현재 화면 저장은 창·사이드바·완전히 보이는 고유 원문 위치·관측 가능한 토글·clear 포커스만 저장한다. 줌 수치는 생략한다. 제목이 보인다는 이유만으로 맨 위라고 추정하지 않고, 현재 보이는 원문의 상대 위치를 저장한다. 화면 밖 토글 상태와 여러 블록 선택을 추정하지 않는다.
- 캡처는 ScreenCaptureKit의 대상 창 전용 캡처다. 다른 창에 의한 가려짐 재현은 포함하지 않는다. 결과에는 창 frame, 본문 viewport, 이미지 픽셀 크기·실측 배율을 기록한다. `environment`의 Cocoa 디스플레이 frame은 별도로 `cocoaFrame`이라 표시한다.
- API 수정 시각/객체 목록의 전후 일치는 가벼운 변경 감지다. 내용 전체의 동일성 증명이나 AX 추출 정확도 검증이 아니다.

실행은 `runs/<run-id>/`에 `request.json`, `result.json`, 가능한 경우 `screen.png`를 남긴다. 실행 중에도 완료한 단계까지 원자적으로 JSON을 갱신한다. 원본 해시·시나리오 버전, 요청/관측 상태, 항목별 오류·시도 횟수·시간, 환경 정보, 전후 API 관측값을 기록한다. `runs/`는 Git에서 제외한다.

## Rearview / 평가 실행기에서 호출

```python
import json
import subprocess

p = subprocess.run(
    ["/absolute/path/notion-fixtures/fixture", "scenario", "apply", "layout-default", "--json"],
    text=True, capture_output=True,
)
result = json.loads(p.stdout)
# exit 0: verified, 2: partial, 3: failed
if result["status"] == "verified":
    screenshot = result["runDirectory"] + "/" + result["screenshot"]["file"]
else:
    # 호출자가 미검증 상태를 수용할지 판단한다. 성공으로 간주하지 않는다.
    print(result["steps"])
```

잘못된 CLI 인자나 존재하지 않는 시나리오는 실행 시작 전 오류(exit 1)로 stderr에 출력한다. 유효한 시나리오 실행을 시작한 뒤 발생한 사전 검사 실패는 run JSON에 기록한다. `--json` stdout에는 최종 JSON만, stderr에는 단계별 JSON 진행 이벤트가 출력된다.

## 검증

```sh
python3 -m unittest discover -s notion-fixtures/tests -p 'test_scenarios.py'
swift test --filter NotionScenarioTests
python3 notion-fixtures/tests/live_scenarios.py
```

마지막 명령은 가짜 서버 없이 실제 Notion에서 초기 6개 시나리오를 각각 두 번 적용한다. 줌만 `unsupported`, 그 외 단계는 `verified`, 스크린샷 존재, 문서 상태 유지 및 반복 적용 수렴을 확인한다. 실행 중 Notion을 조작하지 않는다. 결과 요약은 로컬 `runs/live-scenarios-summary.json`에 저장한다.

### 실제 검증 기록 — 2026-10-28

macOS 26.4 / Notion 7.27.0 / 1280×960pt·2x 환경에서 확인했다.

| 검사 | 결과 |
| --- | --- |
| 초기 6개 시나리오를 각각 2회 적용 | 12회 통과. 줌만 미지원으로 `partial`, 나머지 항목 검증 |
| 현재 화면 저장 → 저장된 상태 재적용 | 읽지 못한 줌은 생략, 재적용 `verified` |
| 문서 API 상태 전후 확인 | 위 실행에서 변경 없음 |
| GUI 목록·생성·수정·복제·삭제·버전 증가 | 실제 앱 UI에서 확인 |
| GUI에서 Notion 조작 | 새 앱의 손쉬운 사용 권한 부족으로 중단, `accessibility_permission`과 `failed` 표시 확인. 권한 설정 후 재검증 필요 |
| Python 회귀/정의 검사 | 27개 통과 |
| Swift 결과 판정/좌표 검사 | 6개 통과 |

CLI 실행 환경의 권한과 독립 앱의 권한은 macOS에서 별도로 관리될 수 있다. 위 CLI 검증을 GUI의 권한 또는 GUI 전체 적용 검증으로 간주하지 않는다.

### GUI 재검증 — 2026-10-29

`layout-default`를 GUI에서 재실행한 결과, 손쉬운 사용 권한 문제가 해소되어 대상 창·창 크기·사이드바·맨 위 스크롤·포커스·최종 상태 검증이 통과했다. 문서 API의 전후 상태도 유지됐다.

실행 `20261028T173116Z-ca5453e53e51`은 화면 캡처 단계에서 `screen_capture_permission`으로 중단되어 전체 `partial`이다. macOS의 화면 및 시스템 오디오 녹음 목록에는 아직 `NotionScenarios`가 등록되지 않은 것을 직접 확인했다. 화면 캡처 권한 설정 후 스크린샷과 GUI 전체 적용을 다시 검증해야 한다. 줌 수치 미지원 제약은 동일하다.

### GUI 캡처 및 입력 재검증 — 2026-10-29 후속

앱을 Finder 환경에서 다시 실행했을 때 nvm 경로의 `ntn`을 찾지 못하는 문제가 발견되어, 패키징 시 CLI 설치 경로를 `NotionCLIPath`로 기록하고 GUI 실행 시 해당 디렉터리를 PATH에 포함하도록 수정했다. 다른 개발자는 자신의 CLI가 설치된 환경에서 앱을 패키징한다. CLI 설치 위치가 바뀌면 다시 패키징한다.

손쉬운 사용과 화면 캡처 권한이 모두 반영되어, GUI 실행에서 실제 `screen.png`(2048×1400px, 창 1024×700pt, 2x) 저장과 문서 상태 유지를 확인했다. 예: `runs/20261028T181056Z-1e0be5e1671a/result.json`.

반복 적용에서는 스크롤 이동 검사가 timeout으로 실패해 전체 `partial`로 기록됐다. 중앙 입력점이 `com.apple.UserNotificationCenter`의 알림창에 속하는 것을 AX hit test로 확인했다. 실행기는 이제 본문 viewport의 여러 지점을 hit test하고, 실제 Notion 본문에 속한 지점으로만 휠 입력을 보낸다. 노출된 본문 지점을 찾지 못하면 `target_occluded`로 중단한다. 선택한 입력점은 `environment.scrollInputPoint`에 기록한다.

알림을 피한 입력점에서도 이번 실행의 스크롤 검사는 통과하지 못했으므로, 알림이 유일한 원인이라고 확정하거나 재현을 완료했다고 간주하지 않는다. 컴퓨터 제어 도구가 시스템 알림 앱 접근을 차단하여 사용자가 알림을 확인하고 닫은 뒤 추가 검증이 필요하다. 줌 수치 미지원 제약도 유지된다.

### 이어서 검증 — 2026-10-29

2560×1440pt·2x 환경에서 실제 Notion을 다시 검증했다. GUI의 `layout-default` 실행 `20261028T220716Z-ee6464caea6b`에서도 스크롤 이동 확인이 timeout으로 실패했다. 입력점은 이번에는 본문 중앙으로 hit test됐으므로, 이전 알림창을 단독 원인으로 볼 수 없다. 같은 문제가 CLI에서도 재현됐지만 컴퓨터 제어 도구의 본문 스크롤은 정상 동작했다. 이벤트 소스 변경, 메뉴 닫기, 이동 검사 재입력, 초기 `AXScrollToVisible` 생략 실험은 해결하지 못해 되돌렸다. 원인은 아직 확정되지 않았다.

| 실제 실행 | 결과 |
| --- | --- |
| `layout-clipped`, `20261028T221421Z-11afc4e22c33` | 본문 상단 오프셋 −8pt, 포커스·캡처·최종 상태 검증. 실제 PNG에서 윗줄 잘림 확인 |
| `layout-toggle-open`, `20261028T221018Z-1f0ff8dce728` | 펼침 상태 및 본문 오프셋 80pt 검증 |
| `layout-toggle-closed`, `20261028T221432Z-85ad3a589027` | 접힘 상태 및 본문 오프셋 80pt 검증 |
| GUI `layout-toggle-open`, `20261028T221502Z-e4517f551e3c` | 줌 외 모든 단계 검증, UI의 항목별 결과와 Screenshot 탭 이미지 표시 확인 |

위 네 실행의 전체 결과는 읽을 수 없는 줌 수치 때문에 `partial`이며, 문서 API 전후 상태는 모두 유지됐다. 기본 맨 위 시나리오 실패와 줌 수치 미지원이 남아 있으므로 전체 시나리오 검증 완료로 간주하지 않는다. 후속 과제는 맨 위 경계에서 실행기의 휠 이동 검사가 반응하지 않는 조건을 찾아 반복 적용까지 통과시키는 것이다.

스크롤 단계가 실패한 경우, 최종 검증은 실제 이동을 관측한 것처럼 `state_drift`라고 보고하지 않고 `prerequisite_failed`로 구분하도록 수정했다. Python 회귀 검사 27개, Swift 검사 6개 및 `git diff --check`가 통과했다.

### 사용자 관찰 및 Notion 업데이트 — 2026-10-29

사용자가 직접 기본 → 확대 → 기본 동작을 화면에서 확인했다. 같은 실행의 제목 AX 높이는 48 → 53 → 48pt였다 (`20261028T225232Z-c3dfcb04956e`, `20261028T225310Z-dd47d91402b5`, `20261028T225349Z-bc1f081c167e`). 확대 및 기본 크기 복귀의 효과는 확인됐지만 숫자 배율은 메뉴에도 표시되지 않았다. 제목 크기 비율은 상대적 변화의 관측 근거이며 Notion의 숫자 배율을 직접 읽은 값이 아니다. `Actual Size` 후 한 번의 `Zoom In`을 정확한 125%로 간주하지 않는다. 사용자는 당시 맨 위 검사 도중 본문이 실제로 스크롤되지 않는 것도 확인했다.

Notion에 표시된 공식 `Update and restart` 버튼으로 7.27.0에서 7.41.1로 업데이트했다. 업데이트 안내 배너가 사라진 것을 확인했다. 실행기 코드를 바꾸지 않고 `layout-default`를 다시 적용한 `20261028T231129Z-4e8654c6b4bd`에서는 스크롤 이동·복귀·최종 상태 및 스크린샷 검증이 모두 통과했다. 제목은 맨 위 y=252pt·높이 48pt → 이동 후 y=140pt·높이 1pt → 복귀 후 y=252pt·높이 48pt로 관측됐다. 문서 API 전후 상태도 유지됐다. 업데이트와 앱 재시작을 함께 했으므로 이전 배너 자체, 구버전 앱 동작, 재시작으로 해소된 상태 중 무엇이 원인이었는지는 분리해서 확정하지 않는다.

업데이트 후 초기 6개 시나리오를 각각 두 번, 총 12회 실제 데스크톱에서 재검증했다. 전부 줌 단계만 `unsupported`, 나머지 단계는 `verified`였으며 스크린샷·문서 상태 유지·반복 적용 수렴 검사를 통과했다. 결과 목록은 로컬 `runs/live-scenarios-summary.json`에 저장했다. GUI에서도 `layout-default` 실행 `20261028T231324Z-3dfb91eccbfa`의 스크롤·포커스·캡처·최종 상태 및 문서 유지가 통과했고, GUI 항목별 결과에서 확인했다. 현재 환경에서는 이전 맨 위 스크롤 실패가 재현되지 않는다. 정확한 숫자 줌 배율의 검증은 여전히 미지원이며 전체 결과는 `partial`이다.
