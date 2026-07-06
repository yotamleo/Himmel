export declare const MAX_BUFFER: number;
export declare const MAX_LINES = 10;
export declare const MAX_LINE_LENGTH = 200;
export declare const TIMEOUT_MS = 3000;
export declare function shouldRunCustomLine(cmd: string | undefined, env?: NodeJS.ProcessEnv): boolean;
export declare function runCustomLineCommand(cmd: string, stdinJson: string, opts?: {
    cwd?: string;
    timeout?: number;
}): Promise<string[] | null>;
//# sourceMappingURL=custom-line-cmd.d.ts.map