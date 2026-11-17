# 🚚 모일날 이사 안내서 (옛 PC → 새 PC)

> 2026-11-17 작성. ⚠️ 이 저장소는 **공개**(웹사이트용)라서 이 파일엔 개인 경로·비밀 정보를 적지 않음.
> 자세한 옛 경로 목록은 비공개 ai-os 저장소의 `MOVING.md`에 있음.

## 📦 짐은 어디 있나

| 무엇 | 어디 |
|---|---|
| 코드 전체 + 기록 | GitHub `moilnal/moilnal.github.io` (공개, 웹사이트 https://moilnal.github.io/ 가 여기서 돌아감) |
| 비상용 전체 백업 + Claude 대화 기록 | 옛 PC에서 만든 이사 백업 zip (`moilnal/`, `claude-대화기록/`) |

## 1️⃣ 새 PC에서 처음 할 일

1. Git, GitHub CLI(`gh`), Claude Code 설치 → `gh auth login` (moilnal 조직 관리자 계정)
2. `gh repo clone moilnal/moilnal.github.io moilnal` (또는 zip의 `moilnal/` 풀기)
3. 대화 기록: zip `claude-대화기록/` 안 moilnal 폴더를 `.claude\projects\`에 넣기
   - 폴더 이름이 경로를 따라감 → 새 PC 경로가 다르면 이름도 맞게 바꾸기

## 2️⃣ 새 PC에서 고칠 경로

- 이 저장소 파일 안에는 PC 경로가 없음 → 고칠 것 없음 ✅
- Claude 대화 기록 폴더 이름만 새 경로에 맞추기 (위 1-3)

## 3️⃣ 다시 연결할 것

| 무엇 | 어떻게 |
|---|---|
| GitHub push | `gh auth login` 후 수정 → 커밋 → push 되는지 확인 (1~2분 뒤 사이트 반영) |
| Supabase | 코드에 든 키는 공개용(publishable)이라 그대로 동작. 대시보드는 브라우저에서 다시 로그인 |
| 크롬 (Claude in Chrome) | 확장 프로그램 설치·로그인 → 사이트 확인할 때 사용 |
| 상태 표시줄 | ai-os 쪽 안내 따라 설정하면 모든 프로젝트에 같이 적용 |
| ai-os 작업실에서 같이 쓰기 | ai-os에서 `/add-dir <새 moilnal 경로>` |

## 4️⃣ 이사 후 할 일

- [ ] https://moilnal.github.io/ 접속 확인
- [ ] 아무 글자나 고쳐서 push → 사이트 반영되는지 확인 (확인 후 원래대로)
- [ ] 가상 오피스에 **'모일날 TF' 방** 추가 (ai-os에서 진행)
- [ ] `CLAUDE.md`의 "다음 할 일" 이어서 진행
