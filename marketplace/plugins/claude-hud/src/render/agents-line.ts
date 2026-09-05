import type { RenderContext, AgentEntry } from '../types.js';
import { yellow, green, magenta, label } from './colors.js';
import { truncateString } from '../utils/truncate.js';
import { sanitizeDisplayText } from '../utils/sanitize.js';

const MAX_RECENT_COMPLETED = 2;
const MAX_AGENTS_SHOWN = 3;
const COMPLETED_RETENTION_MS = 60_000;
const AGENT_TYPE_MAX_LEN = 24;
const AGENT_DESCRIPTION_MAX_LEN = 40;

function takeLast<T>(entries: readonly T[], count: number): T[] {
  return count > 0 ? entries.slice(-count) : [];
}

export function renderAgentsLine(ctx: RenderContext): string | null {
  const { agents } = ctx.transcript;
  const colors = ctx.config?.colors;
  const now = Date.now();

  const seen = new Set<string>();
  const unique = (agent: AgentEntry): boolean => {
    if (seen.has(agent.id)) return false;
    seen.add(agent.id);
    return true;
  };

  // Running work is the primary signal. Fill the fixed three-agent budget with
  // running agents first so completed history can never evict active work.
  const runningAgents = takeLast(
    agents
      .filter((agent) => agent.status === 'running')
      .filter(unique),
    MAX_AGENTS_SHOWN,
  );

  const completedSlots = Math.min(
    MAX_RECENT_COMPLETED,
    MAX_AGENTS_SHOWN - runningAgents.length,
  );
  const recentCompleted = takeLast(
    agents
      .filter((agent) => agent.status === 'completed')
      .filter((agent) => {
        const completedAt = agent.endTime?.getTime();
        return completedAt !== undefined
          && Number.isFinite(completedAt)
          && completedAt <= now
          && now - completedAt <= COMPLETED_RETENTION_MS;
      })
      .filter(unique),
    completedSlots,
  );

  const toShow = [...runningAgents, ...recentCompleted];

  if (toShow.length === 0) {
    return null;
  }

  const lines: string[] = [];
  for (const agent of toShow) {
    lines.push(formatAgent(agent, colors, now));
  }
  return lines.join('\n');
}

/**
 * Compacts an agent model into a statusline-sized label.
 *
 * The transcript reports raw model IDs (e.g. "claude-opus-4-8[1m]",
 * "claude-haiku-4-5-20251001"), which are far too long to sit inside an agent
 * line. Family plus version is the part that carries meaning, so the wrapper
 * bits are dropped: the "claude-" prefix, the bracketed context-window variant,
 * and the trailing release date.
 *
 * Anything that does not look like a model ID — notably the short aliases a
 * caller can pass as `model` ("opus", "sonnet", "haiku") — is returned
 * unchanged, so explicit overrides keep rendering the way they always have.
 */
export function formatAgentModel(model: string | undefined): string | undefined {
  if (!model) return undefined;

  const cleaned = sanitizeDisplayText(model).trim();
  if (!cleaned) return undefined;

  const candidate = cleaned.replace(/\[[^\]]*\]$/, '');
  const current = candidate.match(
    /^claude-(opus|sonnet|haiku)-(\d+)(?:-(\d+))?(?:-\d{8})?$/i,
  );
  if (current) {
    const [, family, major, minor] = current;
    return `${family.toLowerCase()}-${major}${minor ? `.${minor}` : ''}`;
  }

  const legacy = candidate.match(
    /^claude-(\d+)(?:-(\d+))?-(opus|sonnet|haiku)(?:-\d{8})?$/i,
  );
  if (legacy) {
    const [, major, minor, family] = legacy;
    return `${family.toLowerCase()}-${major}${minor ? `.${minor}` : ''}`;
  }

  // Provider-qualified and custom model IDs carry routing information. Keep
  // unknown shapes intact rather than guessing which token is the family.
  return /^claude-$/i.test(candidate) ? undefined : cleaned;
}

function getStatusIcon(
  status: AgentEntry['status']
): string {
  switch (status) {
    case 'running':
      return yellow('◐');
    case 'completed':
    default:
      return green('✓');
  }
}

function formatAgent(
  agent: AgentEntry,
  colors: RenderContext['config']['colors'] | undefined,
  now: number,
): string {
  const statusIcon = getStatusIcon(agent.status);
  const typeLabel = sanitizeAgentText(agent.type, AGENT_TYPE_MAX_LEN) || 'agent';
  const type = magenta(typeLabel);
  const modelLabel = formatAgentModel(agent.model);
  const model = modelLabel ? label(`[${modelLabel}]`, colors) : '';
  const description = sanitizeAgentText(agent.description, AGENT_DESCRIPTION_MAX_LEN);
  const desc = description ? label(`: ${description}`, colors) : '';
  const elapsed = formatElapsed(agent, now);

  return `${statusIcon} ${type}${model ? ` ${model}` : ''}${desc} ${label(`(${elapsed})`, colors)}`;
}

function sanitizeAgentText(value: unknown, maxLen: number): string {
  if (typeof value !== 'string') return '';
  return truncateString(sanitizeDisplayText(value).trim(), maxLen);
}

function formatElapsed(agent: AgentEntry, now: number): string {
  const start = agent.startTime.getTime();
  const end = agent.endTime?.getTime() ?? now;
  const ms = Math.max(0, end - start);

  if (ms < 1000) return '<1s';
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;

  const totalSecs = Math.floor(ms / 1000);
  const mins = Math.floor(totalSecs / 60);
  const secs = totalSecs % 60;

  if (mins < 60) return `${mins}m ${secs}s`;

  const hours = Math.floor(mins / 60);
  const remainingMins = mins % 60;
  return `${hours}h ${remainingMins}m`;
}
