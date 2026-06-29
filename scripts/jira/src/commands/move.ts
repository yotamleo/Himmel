import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';

// HIMMEL-197: Jira Cloud REST API does NOT support direct project-change
// on an issue. The pattern here is close-and-recreate:
//   0. PRE-FLIGHT GET /project/<to-project> — fail fast if target invalid
//   1. GET source (summary, description, issuetype)
//   2. GET source comments (small race window: a comment added between 1 and
//      2 is dropped; documented, acceptable for current use)
//   3. CREATE target with prepended supersedes paragraph in description
//   4. COPY each comment (per-iteration try/catch; partial failures collected,
//      reported at the end, do NOT abort the move — target is more useful with
//      most comments than with none)
//   5. COMMENT on source: "Moved to <NEW-KEY>. Closing."
//   6. GET source transitions, find --target-status (default Done)
//   7. POST transition
//
// The action body is wrapped in a top-level try/catch that tags each step,
// surfaces step-specific stderr, and prints the partial-state breadcrumb
// (target key, comments copied/total, failed-comment IDs) so the operator can
// finish manually rather than re-running and double-creating the target.
//
// Out of scope (v2 follow-ups documented in HIMMEL-197):
// - attachments (binary upload + size limits)
// - custom fields (need per-field project mapping)
// - worklogs
// - linked-issue rewiring (links to source survive but point at a closed issue)

export interface AdfNode {
  type: string;
  version?: number;
  content?: AdfNode[];
  text?: string;
  marks?: Array<{ type: string }>;
  [key: string]: unknown;
}

export interface AdfDoc {
  type: 'doc';
  version: number;
  content: AdfNode[];
}

export interface JiraIssueDetailed {
  key: string;
  fields: {
    summary: string;
    issuetype: { name: string };
    description?: AdfDoc | null;
  };
}

export interface JiraComment {
  id: string;
  author: { displayName: string };
  created: string;
  body: AdfDoc;
}

export interface JiraCommentResp {
  comments: JiraComment[];
}

/**
 * Safely extract the content array from an ADF doc. Returns [] for null,
 * undefined, or malformed shapes (e.g. legacy issues where `content` is a
 * string, missing, or any non-array). Guards against the malformed-ADF
 * passthrough class — without this, prependSupersedesNote could produce a doc
 * Jira renders broken.
 */
export function safeContent(
  node: { content?: unknown } | null | undefined,
): AdfNode[] {
  if (!node || !Array.isArray(node.content)) return [];
  return node.content as AdfNode[];
}

/**
 * Prepend a "Originally filed as <srcKey> — moved <date>" italic paragraph to
 * the source ADF description. Exported for unit testing — the inner request()
 * orchestration is integration territory.
 *
 * When source description is null/undefined/malformed, returns a doc with only
 * the supersedes note (still well-formed for the Jira create payload).
 *
 * `now` is injected so tests can pin a deterministic timestamp.
 */
export function prependSupersedesNote(
  srcKey: string,
  originalDesc: AdfDoc | null | undefined,
  now: Date = new Date(),
): AdfDoc {
  const dateStr = now.toISOString().slice(0, 10);
  const note: AdfNode = {
    type: 'paragraph',
    content: [
      {
        type: 'text',
        text: `Originally filed as ${srcKey} — moved ${dateStr} via jira move.`,
        marks: [{ type: 'em' }],
      },
    ],
  };
  return { type: 'doc', version: 1, content: [note, ...safeContent(originalDesc)] };
}

/**
 * Wrap a source comment's ADF body with a "Original by <author> on <date>:"
 * italic prefix paragraph. Returns a fresh doc safe to POST to the target.
 */
export function wrapMovedComment(comment: JiraComment): AdfDoc {
  const prefix: AdfNode = {
    type: 'paragraph',
    content: [
      {
        type: 'text',
        text: `Original by ${comment.author.displayName} on ${comment.created.slice(0, 10)}:`,
        marks: [{ type: 'em' }],
      },
    ],
  };
  return { type: 'doc', version: 1, content: [prefix, ...safeContent(comment.body)] };
}

/**
 * Find a transition by name, case-insensitive. Defensively accepts the raw
 * response wrapper so missing/malformed `transitions` arrays do not crash on
 * the subsequent `.find()`.
 */
export function findTransitionByName(
  transitions: JiraTransition[] | undefined | null,
  targetName: string,
): JiraTransition | undefined {
  if (!Array.isArray(transitions)) return undefined;
  return transitions.find((t) => t.name.toLowerCase() === targetName.toLowerCase());
}

export function registerMove(program: Command): void {
  program
    .command('move <key>')
    .description(
      'Move a Jira issue to another project (close source + create target with content). ' +
        'Encapsulates the close-and-recreate pattern Jira Cloud requires for cross-project moves.',
    )
    .requiredOption('--to-project <key>', 'Target Jira project key')
    .option('--type <type>', 'Override issue type in target (default: same as source)')
    .option(
      '--target-status <name>',
      'Name of the terminal transition on the source after the move (default: Done). ' +
        'Use this when the source workflow has no Done — e.g. Closed, Resolved, Completed.',
      'Done',
    )
    .option('--dry-run', 'Print plan and exit; no mutations', false)
    .action(
      async (
        srcKey: string,
        options: {
          toProject: string;
          type?: string;
          targetStatus: string;
          dryRun: boolean;
        },
      ) => {
        // Partial-state tracking — used by the error-breadcrumb path so the
        // operator can finish the move manually instead of re-running and
        // double-creating the target.
        let stepLabel = 'pre-flight';
        let created: { key: string } | undefined;
        let copiedCount = 0;
        let totalComments = 0;
        const failedComments: string[] = [];

        const printPartialStateHint = (extraHint: string): void => {
          console.error('  PARTIAL MOVE STATE:');
          if (created) {
            const failedBit = failedComments.length
              ? ` (failed: ${failedComments.join(', ')})`
              : '';
            console.error(`    target ${created.key} CREATED`);
            console.error(`    comments copied: ${copiedCount}/${totalComments}${failedBit}`);
          } else {
            console.error('    no target created');
          }
          console.error(`  ${extraHint}`);
        };

        try {
          // 0. PRE-FLIGHT — validate --to-project exists + operator has perms.
          // Catching here means a typo'd target key fails BEFORE any GET of the
          // source, rather than at step 3 with a cryptic create-400.
          stepLabel = 'pre-flight (--to-project validation)';
          try {
            await request('GET', `/project/${options.toProject}`);
          } catch (e) {
            throw new Error(
              `target project ${options.toProject} not found or no permission: ${(e as Error).message}`,
            );
          }

          // 1. GET source
          stepLabel = 'GET source issue';
          const src = await request<JiraIssueDetailed>(
            'GET',
            `/issue/${srcKey}?fields=summary,issuetype,description`,
          );
          const srcType = options.type ?? src.fields.issuetype.name;
          const targetSummary = src.fields.summary;
          const targetDesc = prependSupersedesNote(srcKey, src.fields.description ?? null);

          // 2. GET comments. NOTE: small race window between step 1 and step 2 —
          // a comment added concurrently is dropped from the move. Acceptable
          // for current use; documented here so future readers know it's a known
          // window, not an oversight.
          stepLabel = 'GET source comments';
          const commentsResp = await request<JiraCommentResp>(
            'GET',
            `/issue/${srcKey}/comment`,
          );
          const comments = commentsResp?.comments ?? [];
          totalComments = comments.length;

          if (options.dryRun) {
            console.log(`DRY-RUN jira move: ${srcKey} → ${options.toProject}`);
            console.log(`  create: type=${srcType} summary="${targetSummary}"`);
            console.log(`  copy ${totalComments} comment(s)`);
            console.log(`  comment + transition ${srcKey} → ${options.targetStatus}`);
            return;
          }

          // 3. CREATE target
          stepLabel = 'CREATE target issue';
          created = await request<{ key: string }>('POST', '/issue', {
            fields: {
              project: { key: options.toProject },
              summary: targetSummary,
              issuetype: { name: srcType },
              description: targetDesc,
            },
          });
          // Match the create command's output line so existing
          // "Created (HIMMEL|LUNA)-N" verifier scripts keep working.
          console.log(`Created ${created.key}`);
          // Breadcrumb on the source ticket: the move has mutated Jira (target
          // created) even if a later step (comment copy / transition) partially
          // fails, so the SessionEnd nudge must not fire (HIMMEL-618 F5/F11).
          writeJiraBreadcrumb(srcKey);

          // 4. Copy comments — per-iteration try/catch so a single failure does
          // NOT abandon the rest. Target is much more useful with most comments
          // than with none. Failed IDs are listed at the end.
          stepLabel = 'COPY comments';
          for (const c of comments) {
            try {
              await request('POST', `/issue/${created.key}/comment`, {
                body: wrapMovedComment(c),
              });
              copiedCount += 1;
            } catch (e) {
              failedComments.push(c.id);
              console.error(`  comment ${c.id} copy failed: ${(e as Error).message}`);
            }
          }
          if (totalComments > 0) {
            console.log(`Copied ${copiedCount}/${totalComments} comment(s) to ${created.key}`);
          }

          // 5. Comment on source
          stepLabel = 'COMMENT source (Moved-to note)';
          const movedNote: AdfDoc = {
            type: 'doc',
            version: 1,
            content: [
              {
                type: 'paragraph',
                content: [{ type: 'text', text: `Moved to ${created.key}. Closing.` }],
              },
            ],
          };
          await request('POST', `/issue/${srcKey}/comment`, { body: movedNote });
          console.log(`Comment added to ${srcKey}`);

          // 6. GET transitions + match against --target-status
          stepLabel = 'GET source transitions';
          const transResp = await request<{ transitions?: JiraTransition[] }>(
            'GET',
            `/issue/${srcKey}/transitions`,
          );
          const transitions = transResp?.transitions ?? [];
          const targetT = findTransitionByName(transitions, options.targetStatus);
          if (!targetT) {
            const avail = transitions.length
              ? transitions.map((t) => t.name).join(', ')
              : '(none)';
            console.error(
              `jira move: source ${srcKey} has no '${options.targetStatus}' transition. Available: ${avail}`,
            );
            printPartialStateHint(
              `Finish manually: jira transition ${srcKey} <available-status>`,
            );
            process.exit(2);
          }

          // 7. POST transition
          stepLabel = 'POST source transition';
          await request('POST', `/issue/${srcKey}/transitions`, {
            transition: { id: targetT.id },
          });
          console.log(`${srcKey} → ${targetT.name}`);

          // Final report. If any comments failed to copy, exit non-zero so
          // scripted callers see the partial state.
          if (failedComments.length > 0) {
            console.error(
              `jira move: PARTIAL SUCCESS — ${failedComments.length} comment(s) failed to copy: ${failedComments.join(', ')}`,
            );
            console.error(
              `  Retry failed comments manually with: jira comment ${created.key} '<text>'`,
            );
            process.exit(2);
          }
          console.log(`Moved ${srcKey} → ${created.key}`);
        } catch (e) {
          // Top-level catch: any unhandled rejection from request() at any step
          // lands here. Tag with the step that was running, surface the
          // partial-state breadcrumb so the operator knows what to clean up.
          console.error(`jira move: step '${stepLabel}' failed: ${(e as Error).message}`);
          printPartialStateHint(
            'Re-run after fixing the underlying cause; do NOT re-run the full move (target may exist).',
          );
          process.exit(2);
        }
      },
    );
}
