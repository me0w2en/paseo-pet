import type { PluginHookContext, PluginServerContext } from "@getpaseo/plugin/server";
import { startBridge, type Bridge } from "./server/http";
import { AgentBoard, describePermission, finalAssistantText, type PetNotice } from "./server/state";

const TITLE_LOOKUP_TIMEOUT_MS = 1500;

export default function contribute(server: PluginServerContext) {
  const board = new AgentBoard();
  let bridge: Bridge | null = null;
  // Hooks hand us a client bound to this daemon; keep the latest one for permission replies from the pet.
  let paseo: PluginHookContext["paseo"] | null = null;
  let stopped = false;

  const publish = (notice?: PetNotice) => {
    bridge?.broadcast("snapshot", { agents: board.list() });
    if (notice) {
      bridge?.broadcast("notice", notice);
    }
  };

  // Title lookups already in flight, so a burst of hooks asks the daemon once per agent.
  const titleLookups = new Map<string, Promise<void>>();

  // Hook payloads often carry `title: null`. Resolve the real title before a notice goes out so the bubble names the agent.
  const ensureTitle = (agentId: string, client: PluginHookContext["paseo"]): Promise<void> => {
    if (!board.needsTitle(agentId)) {
      return Promise.resolve();
    }
    const pending = titleLookups.get(agentId);
    if (pending) {
      return pending;
    }
    // Never hold a hook (and the daemon behind it) for long; the next hook retries the lookup.
    const timeout = new Promise<null>((resolve) => setTimeout(() => resolve(null), TITLE_LOOKUP_TIMEOUT_MS));
    const lookup = Promise.race([client.agents.ref(agentId).refresh(), timeout])
      .then((result) => {
        const title = result?.agent.title?.trim();
        if (title) {
          board.setTitle(agentId, title);
        }
      })
      .catch((error: unknown) => console.error("[pet-bridge] title lookup failed", error))
      .finally(() => titleLookups.delete(agentId));
    titleLookups.set(agentId, lookup);
    return lookup;
  };

  void startBridge({
    snapshot: () => ({ agents: board.list() }),
    async respond(agentId, requestId, behavior) {
      if (!paseo) {
        throw new Error("Paseo client is not ready yet");
      }
      await paseo.agents.ref(agentId).respondToPermission({
        requestId,
        response:
          behavior === "allow"
            ? { behavior: "allow" }
            : { behavior: "deny", message: "데스크톱 펫에서 거절했습니다." },
      });
    },
    test() {
      const agent = board.upsert({
        id: "pet-bridge-test",
        title: "테스트 에이전트",
        provider: "test",
        cwd: process.cwd(),
        workspaceId: null,
        parentAgentId: null,
      });
      publish({ type: "turn_completed", agent, summary: "펫 브리지 연결이 정상입니다." });
      board.remove(agent.id);
      publish();
    },
  })
    .then(async (started) => {
      if (stopped) {
        await started.close();
        return;
      }
      bridge = started;
      console.log(`[pet-bridge] listening on 127.0.0.1:${started.port}`);
    })
    .catch((error: unknown) => console.error("[pet-bridge] failed to start", error));

  server.on("agent.turn_started", async (event, context) => {
    paseo = context.paseo;
    board.upsert(event.agent, { status: "running" });
    publish();
    await ensureTitle(event.agent.id, context.paseo);
    publish();
  });

  server.on("agent.turn_ended", async (event, context) => {
    paseo = context.paseo;
    const { outcome } = event;
    if (outcome.kind === "failed") {
      board.upsert(event.agent, { status: "error", pending: [] });
      await ensureTitle(event.agent.id, context.paseo);
      const agent = board.get(event.agent.id);
      publish(agent ? { type: "turn_failed", agent, message: outcome.error.message } : undefined);
      return;
    }
    board.upsert(event.agent, { status: "idle", pending: [] });
    await ensureTitle(event.agent.id, context.paseo);
    const agent = board.get(event.agent.id);
    // Subagents finish constantly during orchestration; only the agent the user talks to gets a bubble.
    if (agent && outcome.kind === "completed" && event.agent.parentAgentId === null) {
      publish({ type: "turn_completed", agent, summary: finalAssistantText(event.timeline) });
      return;
    }
    publish();
  });

  server.on("agent.permission_requested", async (event, context) => {
    paseo = context.paseo;
    const permission = describePermission(event.request);
    const pending = [
      ...(board.get(event.agent.id)?.pending ?? []).filter((entry) => entry.requestId !== permission.requestId),
      permission,
    ];
    board.upsert(event.agent, { status: "waiting", pending });
    await ensureTitle(event.agent.id, context.paseo);
    const agent = board.get(event.agent.id);
    publish(agent ? { type: "permission_requested", agent, permission } : undefined);
  });

  server.on("agent.permission_resolved", (event, context) => {
    paseo = context.paseo;
    const pending = (board.get(event.agent.id)?.pending ?? []).filter(
      (entry) => entry.requestId !== event.requestId,
    );
    board.upsert(event.agent, { pending, status: pending.length > 0 ? "waiting" : "running" });
    publish();
  });

  for (const name of ["agent.closed", "agent.archived"] as const) {
    server.on(name, (event) => {
      if (board.remove(event.agent.id)) {
        publish();
      }
    });
  }

  return async () => {
    stopped = true;
    await bridge?.close();
  };
}
