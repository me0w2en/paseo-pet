import type { PluginHookAgent, PluginLifecycleEvents } from "@getpaseo/plugin/server";

// Derived from the hook payloads so the plugin only depends on host-provided modules.
type AgentPermissionRequest = PluginLifecycleEvents["agent.permission_requested"]["request"];
type AgentTimelineItem = PluginLifecycleEvents["agent.turn_ended"]["timeline"][number];

export type PetAgentStatus = "running" | "idle" | "waiting" | "error";

export interface PetPermission {
  requestId: string;
  kind: AgentPermissionRequest["kind"];
  title: string;
  detail: string | null;
}

export interface PetAgent {
  id: string;
  title: string;
  provider: string;
  cwd: string;
  workspaceId: string | null;
  parentAgentId: string | null;
  status: PetAgentStatus;
  updatedAt: string;
  pending: PetPermission[];
}

export type PetNotice =
  | { type: "turn_completed"; agent: PetAgent; summary: string }
  | { type: "turn_failed"; agent: PetAgent; message: string }
  | { type: "permission_requested"; agent: PetAgent; permission: PetPermission };

export const UNTITLED_AGENT = "이름 없는 에이전트";

const SUMMARY_CHARS = 160;
const DETAIL_CHARS = 240;

function truncate(text: string, limit: number): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > limit ? `${flat.slice(0, limit - 1)}…` : flat;
}

function stripMarkdown(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+/gm, "")
    .replace(/[*_~]/g, "");
}

export function finalAssistantText(timeline: readonly AgentTimelineItem[]): string {
  let latest = "";
  for (const item of timeline) {
    if (item.type === "user_message") {
      latest = "";
    } else if (item.type === "assistant_message") {
      latest += item.text;
    }
  }
  return truncate(stripMarkdown(latest), SUMMARY_CHARS);
}

function stringField(record: Record<string, unknown> | undefined, keys: readonly string[]): string | null {
  for (const key of keys) {
    const value = record?.[key];
    if (typeof value === "string" && value.trim()) {
      return value;
    }
  }
  return null;
}

export function describePermission(request: AgentPermissionRequest): PetPermission {
  const input = request.input as Record<string, unknown> | undefined;
  const detail =
    stringField(input, ["command", "cmd", "file_path", "path", "url", "question"]) ?? request.description ?? null;
  return {
    requestId: request.id,
    kind: request.kind,
    title: truncate(request.title ?? request.name, 80),
    detail: detail ? truncate(detail, DETAIL_CHARS) : null,
  };
}

export class AgentBoard {
  private readonly agents = new Map<string, PetAgent>();

  list(): PetAgent[] {
    return [...this.agents.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  get(id: string): PetAgent | undefined {
    return this.agents.get(id);
  }

  remove(id: string): boolean {
    return this.agents.delete(id);
  }

  /** Hook payloads often carry `title: null`; the daemon knows the real one, so fill it in afterwards. */
  needsTitle(id: string): boolean {
    const current = this.agents.get(id);
    return current !== undefined && current.title === UNTITLED_AGENT;
  }

  setTitle(id: string, title: string): boolean {
    const current = this.agents.get(id);
    if (!current || current.title === title) {
      return false;
    }
    this.agents.set(id, { ...current, title });
    return true;
  }

  upsert(agent: PluginHookAgent, patch: Partial<Pick<PetAgent, "status" | "pending">> = {}): PetAgent {
    const previous = this.agents.get(agent.id);
    const next: PetAgent = {
      id: agent.id,
      title: agent.title ?? previous?.title ?? UNTITLED_AGENT,
      provider: agent.provider,
      cwd: agent.cwd,
      workspaceId: agent.workspaceId,
      parentAgentId: agent.parentAgentId,
      status: patch.status ?? previous?.status ?? "idle",
      pending: patch.pending ?? previous?.pending ?? [],
      updatedAt: new Date().toISOString(),
    };
    this.agents.set(agent.id, next);
    return next;
  }
}
