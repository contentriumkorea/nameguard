# NameGuard

맥의 분해된 한글 파일·폴더 이름을 NFC로 정리하는 작은 메뉴 막대 앱입니다. 파일 내용은 변경하지 않습니다. macOS 13 이상, Apple Silicon과 Intel Mac을 지원합니다.

## 사용하기

1. GitHub **Actions → NameGuard macOS → 성공한 실행 → NameGuard-macOS**에서 설치 ZIP을 받습니다. GitHub 로그인이 필요합니다.
2. 다운로드한 묶음 안의 `NameGuard-Desktop.zip`을 풀고 `설치.command`를 실행합니다.
3. 맥 상단 바의 **NameGuard** 아이콘을 누릅니다.

새 사용자는 바탕화면부터 감시합니다. **폴더 추가…**에서 여러 폴더를 고를 수 있고, 폴더 이름을 누르면 **감시에서 제거**할 수 있습니다. 하위 폴더도 포함합니다. 선택한 폴더와 일시중지 상태는 다음 로그인에도 유지됩니다.

메뉴에는 감시 중·검사 중·변경 보류·일시중지·감시 중단·오류 상태와 처리 건수가 표시됩니다. **다시 시작**은 감시기를 새로 시작하고, **종료**는 이번 로그인 세션의 앱을 닫습니다. 다음 로그인에는 다시 켜집니다. **자동실행해제.command**는 로그인 자동 실행을 해제합니다.

기존 NameGuard가 설치된 맥에는 같은 위치에 업데이트하며 기존 Desktop + Dropbox 설정, 제외 폴더와 대기 시간을 보존합니다. 재설치해도 선택한 폴더를 바탕화면으로 덮어쓰지 않습니다. 이름에 Desktop이 들어가는 ZIP과 앱은 기존 배포본과의 호환을 위한 파일명이며 감시 범위는 메뉴에서 변경할 수 있습니다.

## 주의할 점

- 이 앱은 개발자 ID 서명·Apple 공증이 없는 개인 공유용입니다. macOS가 실행을 차단할 수 있습니다. 시스템 설정 → 개인정보 보호 및 보안에서 메시지를 확인해 주세요. 접근 권한 오류는 로그 폴더에서 확인할 수 있습니다.
- 실제 NFD 한글 자모가 있는 이름만 처리합니다. `ㅎㅏㄴㄱㅡㄹ`처럼 호환 자모로 작성된 이름이나 글자 인코딩이 깨진 이름을 추측해서 복원하지 않습니다.
- 파일 내용과 편집 프로젝트 내부의 미디어 참조는 수정하지 않습니다. 경로를 고정해야 하는 프로젝트는 감시에서 빼거나 설정의 `excludedPaths`에 추가해 주세요.
- 열린 파일과 실행 중인 주요 편집 프로그램이 있으면 변경을 보류합니다. 숨김 파일, 앱·사진·편집 프로젝트 패키지, 심볼릭 링크는 제외하고 목적지 덮어쓰기를 금지합니다.
- APFS 기준입니다. Mac에서 이름 변경이 성공해도 Dropbox를 통해 Windows에 반영되는지는 별도 확인이 필요합니다.

설정과 로그는 `~/Library/Application Support/NameGuardDesktop/`에 보관합니다. 기존 설치를 업데이트한 경우에는 기존 `NameGuard/` 폴더를 계속 사용합니다. 자동 업데이트는 없습니다.

## 개발

최종 실행 환경은 macOS입니다. Windows에서는 소스 편집과 셸·Python 문법 검사만 할 수 있습니다.

```bash
bash build.sh                 # 로컬 실행 파일
.build/nameguard --menu       # 메뉴 앱
bash test.sh                  # 임시 폴더 기반 실제 맥 검사
bash build-desktop-release.sh # Apple Silicon + Intel 설치 ZIP
```

`swift test`로 Swift Package Manager 구성도 검사할 수 있습니다. GitHub Actions는 Universal 빌드, 코어 검사, 메뉴 상태 판정·설정 보존, 폴더 추가·제거·일시중지·재개, 배포 설치와 기존 설정 보존을 임시 폴더로 검사합니다. 실제 메뉴 클릭·폴더 선택 창·macOS 권한 승인과 실제 Dropbox 동기화는 사용자 맥에서 확인해야 합니다. `Tests/live_check.py`는 실제 사용자 폴더에 테스트 파일을 만들므로 CI에서 실행하지 않습니다.

구현은 [Apple의 폴더 선택 창](https://developer.apple.com/documentation/appkit/nsopenpanel)과 [프로세스 상태 API](https://developer.apple.com/documentation/foundation/process/isrunning)를 사용합니다. 감시기는 메뉴와 별도 프로세스에서 실행하며 폴더 변경 때 기존 감시기를 종료하고 새 설정으로 시작합니다.
