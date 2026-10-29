# Notion AX Fixtures

Notion 데스크톱 앱의 AX 테스트에 사용할 문서를 생성하고 복구하는 독립 도구입니다. Python 3.9 이상과 공식 `ntn` CLI가 필요합니다. Python 외부 패키지와 Swift 앱 빌드는 필요하지 않습니다.

## 시작하기

[공식 설치 안내](https://developers.notion.com/cli/get-started/overview)에 따라 `ntn`을 설치한 뒤 로그인합니다.

```sh
npm install --global ntn
ntn login
cd notion-fixtures
./fixture ensure
./fixture list
```

첫 실행은 워크스페이스 최상위에 비공개 **Notion AX Fixtures** 페이지를 자동 생성합니다. 그 아래 여섯 Fixture 페이지를 만들고 ID를 로컬 `state.json`에 저장합니다. 다음 실행은 같은 페이지를 재사용합니다. 개발자마다 별도의 로컬 상태와 실제 페이지를 사용합니다. 자동 생성된 루트에는 개발자 본인의 테스트 데이터만 넣으세요.

직접 만든 **전용 테스트 페이지**를 사용하려면 최초 실행에만 지정합니다.

```sh
./fixture ensure --parent 'https://www.notion.so/your-test-page-id'
```

이 페이지는 도구의 관리 범위가 됩니다. 업무 페이지를 지정하지 마세요. 저장된 루트와 다른 `--parent`는 거부합니다. `ntn login`은 정규 워크스페이스 멤버 계정이 필요하며 게스트·제한된 멤버는 지원하지 않습니다. internal integration 토큰을 `NOTION_API_TOKEN`으로 사용하는 경우 최상위 비공개 페이지 생성이 불가능하므로 `--parent`가 필수입니다.

`NOTION_API_TOKEN`은 키체인 로그인보다 우선합니다. 키체인 인증은 `ntn`에 맡기며 도구가 토큰을 읽어 저장하지 않습니다. `NOTION_WORKSPACE_ID`로 로그인 워크스페이스를 선택할 수 있습니다. 최초 인증 사용자와 반환된 workspace ID를 로컬 상태에 기록하고 이후 다른 인증 대상에서는 중단합니다. 상태 파일에는 비밀 토큰이 없습니다.

## 일본어 중심의 테스트 문서

기본 목적은 **일본어→한국어 번역**이다. 한국어·영어 원문은 혼합 언어 대조군에 한정하고, 다른 문서와 DB는 일본어 원문을 사용한다. [사례별 원문·의미 기준과 화면 재현 절차](SCENARIOS.md)를 함께 확인한다.

| Fixture | 주요 내용 |
| --- | --- |
| `rich-document` | 부정·예외·행위자·수량, 서식 run, 불릿·이모지·계층, 표·탭·컬럼 |
| `layout-stress` | 명시적/자연 개행, 불균등 3열, 반복 문구, 가로 넘침·8열 표, 가림·경계·스크롤 |
| `mixed-language` | 일·한 병기, 문장 내 언어 전환, 영문 키, 한자 단독, 반각·결합문자·ZWJ |
| `long-reading` | 일본어 보고서 16절, 1,000자 이상 큰 문단, 긴 문맥과 화면 밖 콘텐츠 |
| `media-diagrams` | 고정 PNG 3개, 이미지 내 글자·가림·잘림, 그래프, Mermaid 2개, 등폭 그림 |
| `project-database` | 일본어 18개 레코드, 짧고 긴/동일한 제목, 여러 줄 비고, 표 2개·보드·갤러리·타임라인 |

잘림·가려짐·화면 밖 노출은 창 크기·선택 영역·스크롤·다른 창의 위치에 따라 실제 UI에서 만들어야 한다. API 생성 성공은 원문 좌표나 번역 품질이 올바르다는 증거가 아니다. 이미지 글자는 일반적으로 AX 텍스트가 아니므로 화면의 모든 글자를 다루는 경우 OCR 경로도 함께 확인한다.

## 명령

```sh
./fixture ensure                       # 모든 Fixture 생성 / 재사용 / 복구
./fixture ensure rich-document         # 하나만 처리
./fixture reset                        # 모든 Fixture 강제 복구
./fixture reset project-database       # 하나만 강제 복구
./fixture list                         # 로컬 ID, URL, 마지막 완료 상태
```

`list`는 원격 상태를 검사하지 않으며 로그인 없이 사용할 수 있습니다. `ready`는 마지막 성공 시점의 상태입니다. 오류는 stderr와 종료 코드 1로 반환합니다. 정상은 0, 사용자 인터럽트는 130입니다. 명령은 현재 작업 디렉터리와 관계없이 실행 파일 옆의 정의와 상태를 사용합니다.

## 정의 파일

- `fixtures/rich-document/fixture.json`: `kind: "document"`, `page` 생성 속성, `content` Markdown 파일명.
- `fixtures/media-diagrams/fixture.json`: `images` 배열에 로컬 PNG의 `file`, 삽입할 고유 문단 `after`, 선택적 `caption`을 지정한다. 파일 바이트도 원본 해시에 포함한다.
- `fixtures/project-database/fixture.json`: `kind: "database"`, `page` 생성 속성, `databaseTitle`, `schema`·`rows`·`views` 파일명.
- `schema.json`: Database 생성 요청의 `initial_data_source` 객체입니다.
- `rows.json`: Page 생성 요청 객체의 배열입니다. `properties`, 선택적 `markdown`·`markdown_version`·`icon`·`cover`를 사용합니다. `parent`는 도구가 주입합니다.
- `views.json`: View 생성 요청 객체의 배열입니다. `database_id`와 `data_source_id`는 도구가 주입합니다. `property_id`, `date_property_id`, `end_date_property_id` 위치에 스키마 속성 이름을 쓰면 생성된 ID로 바꿉니다. 필터·정렬의 `property`는 공식 API의 이름 참조를 그대로 사용합니다.

`page`에는 `properties`, `icon`, `cover`만 지정합니다. Fixture 디렉터리 이름이 로컬 식별자이며 이름 변경은 새 Fixture를 생성합니다. 참조 파일은 해당 Fixture 디렉터리 안에 있어야 합니다. 원본 해시는 모든 참조 파일의 경로와 바이트를 포함합니다. 원본·Python 코드·테스트는 Git으로 공유하고 `state.json`, 잠금 파일, 임시 파일은 공유하지 않습니다.

정의 로더는 Notion 접근 코드와 분리되어 있습니다. 향후 추출기는 이 파일 형식을 출력하면 됩니다. 현재 추출 기능은 없습니다.

## 지원 범위와 복구 방식

API 버전은 `2026-03-11`로 고정합니다. 일반 문서는 `markdown_version: "v2"`를 명시하고 `replace_content`로 전체 콘텐츠를 교체합니다. 페이지 ID는 유지합니다. 제목 등 정의된 페이지 속성도 다시 적용합니다. Markdown 블록 ID는 복구 과정에서 바뀔 수 있습니다.

Markdown v2는 **opt-in preview**입니다. rich-document에는 일본어 실무 문단, 서식·색상·링크, 중첩 목록과 문단, 체크박스, 콜아웃, 토글, 표, 컬럼, 탭, 코드, 수식을 넣었습니다. 파서 경고가 있으면 완료로 처리하지 않습니다. Preview나 Notion 데스크톱 버전에 따라 표시가 달라질 수 있으며 UI/AX 지원까지 API가 보장하지는 않습니다.

DB Fixture는 관리 페이지 안의 inline Database와 초기 Data Source, 18개 레코드, Table 2개·Board·Gallery·Timeline의 5개 뷰로 구성됩니다. Timeline 샘플 날짜는 **2026년 10~11월**로 고정되어 있으며 뷰의 중심 날짜도 고정합니다. 외부 파일이나 특정 계정의 사용자 ID에 의존하지 않습니다. DB 생성 시 자동 추가된 기본 뷰는 요청한 다섯 뷰가 모두 생성된 뒤 제거합니다.

로컬 PNG는 공식 `v1/file_uploads`의 `single_part` 생성 후 `ntn api .../send --file`로 전송하고, 공식 이미지 블록 API의 `position.after_block`으로 지정한 문단 직후에 삽입한다. `ntn files create`는 multipart 업로드를 사용해 무료 플랜에서 거부되므로 사용하지 않는다. 각 PNG는 5 MB 이하만 허용한다. 성공한 원격 이미지/업로드 ID를 상태에 기록하며, 복구는 본문 전체 교체 뒤 이미지를 다시 삽입하므로 중간 실패 후 재실행에서 이미지가 중복되지 않는다. PNG와 `.labels.json`은 커밋하며, 재생성은 다음 선택적 macOS 명령으로 수행한다. CLI 실행 자체에는 Swift가 필요하지 않다.

```sh
swift fixtures/media-diagrams/assets/render.swift fixtures/media-diagrams/assets
```

재사용 판단에는 원본 SHA-256, 페이지·DB·Data Source의 수정 시각과 휴지통 상태, Data Source 목록, 전체 레코드 및 뷰의 ID·수정 시각을 사용합니다. 목록은 끝까지 페이지네이션하고 뷰 참조는 개별 조회합니다. DB에서 기록된 레코드가 보이지 않으면 직접 조회해 접근 불가 상태를 삭제로 오인하지 않도록 합니다. 전체 블록 트리 비교·Markdown 비교·동기화 엔진은 없습니다. 실제 서버 응답에서 `last_edited_time`이 분 단위로 관찰되었습니다. 같은 분 안의 수정이나 하위 블록 수정이 상위 페이지 수정 시각에 반영되지 않는 경우 등은 감지하지 못할 수 있습니다. AX 테스트에서 수정한 사실을 알고 있다면 `reset`을 사용하세요.

조회 가능한 휴지통의 관리 페이지와 DB는 복원합니다. DB 변경 시에는 관리 페이지 ID를 유지하며 내부 DB·Data Source·레코드·뷰를 재생성합니다. 새 구성이 완료된 뒤 이전 DB를 휴지통으로 이동합니다. 이전 DB는 영구 삭제하지 않습니다. 관리 페이지의 추가 일반 블록은 복구 과정에서 제거하지만 예상하지 않은 자식 페이지·DB가 있으면 중단합니다. 일반 문서에서도 자식 페이지·DB 삭제 보호를 해제하지 않습니다. 해당 콘텐츠를 수동으로 옮긴 뒤 다시 실행하세요.

관리 루트의 위치, Fixture 페이지의 parent, DB·Data Source·레코드·뷰의 소속을 확인합니다. 밖으로 이동한 객체는 수정하지 않습니다. API 조회와 쓰기 사이의 동시 이동까지 원자적으로 방지할 수는 없으므로 명령 실행 중 UI에서 구조를 옮기지 마세요.

## 오류와 중단 후 복구

`401`·`403`은 인증·권한을 해결한 뒤 다시 실행합니다. **`404`는 삭제와 접근 권한 상실을 구분할 수 없어 `reset`에서도 자동 재생성하지 않습니다.** 로그인 워크스페이스와 공유 권한을 먼저 확인하세요. 이는 공식 API의 제약입니다.

영구 삭제를 사람이 확인한 경우에만 `state.json`을 백업하고 해당 `fixtures` 항목을 제거한 뒤 `ensure`를 실행해 새 ID를 받습니다. 관리 루트가 영구 삭제됐다면 모든 하위 객체의 상태도 검토한 뒤 상태 파일을 백업·분리하고 새 루트를 만듭니다. 단순한 권한 오류나 CLI 오류 해결 목적으로 상태를 삭제하지 마세요.

상태는 파일 잠금과 원자적 교체로 저장합니다. 생성된 ID와 DB 생성 진행 단계를 즉시 기록하므로, 명확하게 거부된 요청 뒤에는 기존 ID를 활용해 이어서 실행합니다. DB 생성 중에는 정의 파일을 바꾸지 마세요. 바꿨다면 이전 파일로 되돌려 복구를 완료한 다음 새 정의를 적용합니다.

생성 직전 `inFlightCreate`를 저장합니다. 타임아웃, 서버 오류, 프로세스 강제 종료 등으로 성공 여부가 불분명하면 다음 실행은 자동 재전송을 막습니다. 이 경우:

1. `state.json`을 백업하고 `inFlightCreate.path`·`target`과 관리 페이지를 확인합니다.
2. 생성이 안 된 것을 확인했다면 `inFlightCreate`만 제거하고 재실행합니다.
3. 생성됐다면 반환받지 못한 ID를 해당 진행 항목에 기록하고 `inFlightCreate`를 제거합니다. 루트는 `root.pageId`·`parent`·`url`, Fixture 셸은 `fixtures.<이름>.pageId`·`url`, DB는 `pending.databaseId`, 레코드·뷰는 `pending.rows`·`pending.views`의 해당 인덱스가 대상입니다. 확신할 수 없다면 상태를 수정하지 말고 먼저 Notion 객체를 조사하세요.

`createWarnings`가 있으면 생성된 객체의 ID와 파서 경고를 확인하고 내용을 수정하거나 해당 객체를 휴지통으로 옮긴 뒤 해당 진행 ID를 제거하세요. 경고 원인을 해결한 뒤 `createWarnings`를 제거하고 재실행합니다. 경고가 있는 생성 결과를 다음 실행에서 조용히 정상으로 확정하지 않습니다.

불명확한 생성 요청은 재시도하지 않으며, 속도 제한 `429`만 제한적으로 재시도합니다. API의 전역 트랜잭션은 없으므로 중간 실패 시 이미 완료된 원격 작업은 남을 수 있습니다. `list`와 상태 파일로 진행 상황을 확인합니다.

## 검증

```sh
python3 -m unittest discover -s notion-fixtures/tests -v
```

디스크 기반 가짜 `ntn` 실행 파일로 실제 subprocess 입출력을 테스트합니다. 생성·재사용, 페이지와 DB 복구, 레코드·뷰 변경, 페이지네이션, 접근 권한, 범위 이탈, 중간 실패·재시작, 상태 잠금과 오류를 확인합니다.

실환경 확인 순서:

1. 로그인 후 `ensure`를 두 번 실행해 두 번째가 `reused`이며 ID가 같은지 확인합니다.
2. Notion 데스크톱에서 rich-document의 탭·컬럼·토글·표를 확인하고 문단을 수정한 뒤 `ensure`로 복구합니다.
3. DB의 다섯 뷰, 상태별 그룹, 갤러리 카드, 날짜 범위를 확인합니다.
4. 레코드나 뷰를 수정한 뒤 `ensure`에서 관리 페이지 ID 유지와 DB ID 교체를 확인합니다.
5. 일반 문서와 DB를 휴지통으로 이동하고 복원을 확인합니다. `reset`도 확인합니다.

일본어 corpus와 이미지·DB의 실제 서버 readback을 확인하려면 다음 명령을 사용한다. 로컬 정의를 반영하고, PNG 원본 해시·삽입 순서·캡션, 명시적 개행·큰 문단, 18개 행의 원문·다섯 뷰, 여섯 Fixture의 쓰기 없는 재사용을 확인한다.

```sh
python3 -u notion-fixtures/tests/live_content.py
```

생성·수정·복구 생명주기를 검증하는 실제 서버 스크립트도 제공합니다. 이 스크립트는 로컬 상태에 기록된 Fixture만 의도적으로 수정·휴지통 이동한 뒤 원본으로 복구합니다. 실행 중 실패하면 오류를 해결한 뒤 `./fixture reset`으로 복구할 수 있습니다. 이전 DB는 휴지통에 남습니다.

```sh
python3 -u notion-fixtures/tests/live_smoke.py
```

API 서버 검증 성공은 실제 Notion 화면이나 AX 트리 검증을 대신하지 않습니다.

## 실제 서버 검증 기록

2026-10-27, 공식 `ntn 0.23.25`와 실제 Notion API(`2026-03-11`)에서 확인했습니다.

- 상위 페이지 미지정 상태에서 전용 비공개 루트와 두 Fixture 최초 생성.
- 두 Fixture 반복 실행 시 ID 유지 및 쓰기 요청 없이 재사용.
- Markdown v2 읽기와 실제 `tab`, `column_list`, `table`, `toggle`, `callout` 블록 생성.
- 실제 Table·Board·Gallery·Timeline 뷰 생성 및 조회.
- 일반 문서 수정·휴지통 이동 후 같은 페이지 ID로 복구, 강제 reset.
- DB 레코드 수정·삭제 및 뷰 이름 변경 감지 후 내부 DB 교체와 관리 페이지 ID 유지.
- DB 휴지통 복구, 강제 reset, 최종 원본 상태 재사용.
- 실제 관리 로직에서 존재하지 않는 페이지의 404를 받고 추가 쓰기 없이 중단. 이 검증에서 상태 파일이 변경되지 않음도 확인.

최종 CLI `ensure` 결과는 두 Fixture 모두 `reused`입니다. 데스크톱 화면과 AX 트리 자체의 검증은 별도로 필요합니다. 생성된 객체 ID와 URL은 개발자별 `state.json`에만 보관합니다.

2026-10-28에는 일본어 중심의 여섯 Fixture로 확장하고 실제 서버에서 다음을 추가 확인했습니다.

- 모든 사례 ID의 Markdown readback, 명시적 개행, 1,000자 이상의 단일 문단.
- local PNG 3개의 single-part 업로드, 원본 파일과 원격 파일의 SHA-256 일치, 캡션과 삽입 순서, Mermaid 블록 2개.
- 이미지 Fixture 강제 reset 후 중복 없이 3개 이미지 유지 및 쓰기 없는 재사용.
- 반각·결합 탁점·ZWJ·피부색 이모지·부호·영문 키의 원문 보존.
- 일본어 레코드 18개 전체 원문, 여러 줄 비고, 한 줄 생략/여러 줄 접기 설정을 포함한 5개 보기.
- 여섯 Fixture의 쓰기 없는 재사용. 일반 문서의 추가 대화·레시피·소식·정중한 요청·기술 설명도 반영 후 재사용 확인.

원문 박스의 화면 좌표 정확성과 번역 품질은 [화면 시나리오](SCENARIOS.md)를 통해 별도 평가해야 합니다.

## 공식 근거

- [CLI 설치와 로그인](https://developers.notion.com/cli/get-started/overview)
- [CLI 인증·키체인·멤버 제한](https://developers.notion.com/cli/get-started/authentication)
- [CLI stdin JSON과 API 버전](https://developers.notion.com/cli/guides/api-requests)
- [페이지 생성과 workspace parent 제한](https://developers.notion.com/reference/post-page)
- [Markdown v2 문법과 preview 상태](https://developers.notion.com/guides/data-apis/notion-flavored-markdown)
- [Markdown 교체와 자식 콘텐츠 삭제 보호](https://developers.notion.com/reference/update-page-markdown)
- [Database와 초기 Data Source 생성](https://developers.notion.com/reference/create-database)
- [파일 업로드 API](https://developers.notion.com/reference/create-file)
- [이미지 블록과 업로드 파일](https://developers.notion.com/reference/block#image)
- [뷰 생성·수정·설정](https://developers.notion.com/guides/data-apis/working-with-views)

## 화면 시나리오

독립 macOS 앱과 `fixture scenario` CLI로 창·스크롤·토글 등의 상태를 저장하고 재현한다. 사용법과 실제 지원 범위는 [SCREEN_SCENARIOS.md](SCREEN_SCENARIOS.md)를 참고한다. 기존 문서 생성·복구와 별도로 실행되며 원문을 수정하지 않는다.
