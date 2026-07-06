// Shared debug logging utility
// Enable via: DEBUG=claude-hud or DEBUG=*

const DEBUG = process.env.DEBUG?.includes('claude-hud') || process.env.DEBUG === '*';

/**
 * Create a namespaced debug logger
 * @param namespace - Tag for log messages (e.g., 'config', 'usage')
 */
export function createDebug(namespace: string) {
  return function debug(msg: string, ...args: unknown[]): void {
    if (DEBUG) {
      console.error(`[claude-hud:${namespace}] ${msg}`, ...args);
    }
  };
}
