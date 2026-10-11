# Pet Bridge

Sends Paseo agent events to a desktop pet so you notice them even when the Paseo window is closed.

- Turn completed, failed, and permission requested/resolved
- Approve or deny permissions from the pet
- Local only: `127.0.0.1:6792`, token in `~/.paseo/pet-bridge/connection.json` (0600)

Pair it with the PaseoPet macOS app in the same repository, or connect your own client to the SSE API.

데스크톱 펫(PaseoPet)에 에이전트 완료·실패·승인 요청을 전달하는 브리지입니다.
