# AX evaluation prototype

2단계는 미완료다. 이번 도구는 두 줄바꿈 화면의 공개 AX 응답과 단순 후보 박스를 검토하는 첫 프로토타입이다. Rearview에 연결하지 않는다.

```sh
swift build --product NotionAXEvaluation
./notion-fixtures/fixture scenario apply layout-wrap-1024-closed --json
# 위 결과의 runId를 사용하고 Notion을 조작하지 않는다.
.build/debug/NotionAXEvaluation collect --root "$PWD/notion-fixtures" --run-id <run-id>
# 출력 경로의 index.html을 연다.
```

`layout-wrap-640-closed`도 같은 순서로 실행한다. 실행 주체의 손쉬운 사용 권한이 필요하다. 줌 unsupported만 있는 partial은 수용하며 실제 줌 수치를 검증했다고 간주하지 않는다.

출력은 evaluations/<run-id>/<evaluation-id>/에 누적된다. 원본 screen.png, rawAx.json(속성과 범위 API 응답), candidate.json(AXStaticText 후보), metadata.json, index.html을 로컬에 보존한다. Git에는 코드와 이 문서만 보존한다.

후보는 화면과 교차하는 AXStaticText 전체 값이다. 가시 문자 범위, 중복 제거, 읽기 순서는 아직 검증하지 않았다. 범위 API는 전체 UTF-16 범위의 bounds 응답만 조사한다. 3500노드/40깊이/15초 한도와 AX 호출 0.35초 제한을 사용한다. 전체 시간 제한은 호출 사이에서 검사한다.

현재는 페이지 ID와 수집 전후 창 프레임만 확인한다. 스크롤·토글·픽셀의 동일성을 입증하지 못하므로 **모든 비교는 comparison_unverified**다. 과거 캡처와 다른 상태일 수 있으며 사용자가 반드시 원본과 현재 화면을 대조해야 한다. 자동 정답/합격 판정 도구가 아니다.

사용자 검토 후 우선 개선할 사항: 현재 화면 캡처와 상태 동일성 검증, 문자 범위별 관측, 후보 중복/가시성, 독립 정답과 좌표 테스트. 이후 토글과 추가 시나리오를 도입한다.

## 실행 책임과 다음 검토 기준

개발 에이전트가 변경 후 빌드, 두 화면 재생, 수집과 보고서 생성을 직접 수행한다. 사용자에게 실행 명령을 넘기는 것으로 완료하지 않는다. 전체 실행은 `python3 notion-fixtures/tools/run_ax_prototype.py`이며 결과 진입점은 `evaluations/index.html`이다.

2단계 안에서 실제 추출 결과로 채택할 원문과 박스를 보고서로 확인한다. 관측 노드 전체와 추출 결과를 구분하고 제외 이유·불확실성도 표시하는 방향으로 개선한다. 현재 AXStaticText 후보는 최종 추출 결과 구현 완료로 간주하지 않는다. 3단계는 검증된 규칙의 앱 통합 단계다.

## 결정 기록: 1pt 이하 텍스트 조각 조기 제외

텍스트 값이 있고 프레임 너비 또는 높이가 **1pt 이하**이면 후보에서 제외하고 텍스트 범위 AX 추가 조회도 생략한다. 기존 프레임을 재사용하므로 이 필터 자체에 추가 프로세스 간 AX 호출이 없다. 자식 탐색은 유지한다.

근거: Chromium은 완전히 잘린 노드를 조상 경계로 이동시키며 너비 또는 높이를 1로 반환할 수 있다([공식 설명](https://github.com/chromium/chromium/blob/main/docs/accessibility/browser/offscreen.md)). 실제 1024 closed 관측에서도 보이지 않는 두 제목의 프레임 높이가 1pt였고 전체 문자열이 후보에 포함됐다. 이는 Notion 내부 동작을 확정하는 근거가 아니라 관측과 일치하는 설명이다.

제품 정책: 번역 입력으로 유용하지 않은 극소 경계 조각은 빠르게 버린다. 실제로 1pt 이하의 글자 일부가 보이는 경우도 의도적으로 제외한다. 비가시성을 증명하는 규칙이 아니다. 단위는 픽셀이 아닌 포인트이며 2배율에서는 1pt가 2px이다. 원본 관측 노드는 보존하고 `exclusionReason: text_extent_at_most_1pt`를 기록한다. 향후 작은 조각도 필요해지면 `minimumUsefulTextExtent`와 이 정책을 재검토한다. 더 큰 부분 잘림 문제는 이 필터로 해결되지 않는다.
