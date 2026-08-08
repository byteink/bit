import * as path from "path";
import * as fs from "fs";
import { execFile } from "child_process";
import * as vscode from "vscode";
import {
  ExecutableOptions,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

const BINARY_NAME = process.platform === "win32" ? "bit.exe" : "bit";

let client: LanguageClient | undefined;
let output: vscode.LogOutputChannel | undefined;

/**
 * Resolves the bit binary: an explicit `bit.serverPath` setting wins,
 * otherwise every directory on PATH is checked in order (PATH is a finite,
 * user-controlled list, so this loop is statically bounded). Returns
 * undefined — never throws — so activate() can surface one clear error
 * instead of an unhandled rejection.
 */
function resolveBitPath(): string | undefined {
  const configured = vscode.workspace.getConfiguration("bit").get<string>("serverPath", "").trim();
  if (configured.length > 0) return fs.existsSync(configured) ? configured : undefined;

  const dirs = (process.env.PATH ?? "").split(path.delimiter);
  for (const dir of dirs) {
    if (dir.length === 0) continue;
    const candidate = path.join(dir, BINARY_NAME);
    if (fs.existsSync(candidate)) return candidate;
  }
  return undefined;
}

function startClient(bitPath: string): LanguageClient {
  const serverOptions: ServerOptions = {
    command: bitPath,
    args: ["lsp"],
    transport: TransportKind.stdio,
    // argv0 reaches child_process.spawn verbatim and sets the child's
    // argv[0]. It does NOT set the kernel accounting name (`ps -o ucomm=`,
    // which macOS derives from the resolved executable's filename), so this
    // renames the server for `ps`, `pgrep -f`, `htop` and `lsof` but NOT for
    // Activity Monitor's Process Name column — measured: comm=bit-lsp,
    // ucomm=bit. A symlink named `bit-lsp` does not help either, because the
    // name comes from the resolved target. See CHANGELOG 0.1.1.
    //
    // It does not change the exec path, so stdRootPath()/resolveNearExe()
    // still resolve stdlib and libbitrt.a from bitPath as before.
    options: { argv0: "bit-lsp" } as ExecutableOptions & { argv0: string },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "bit" }],
    outputChannel: output,
    // vscode-languageclient's DefaultErrorHandler already restarts the
    // server on an unexpected exit (up to 5 times within 3 minutes), so a
    // crashed `bit lsp` process comes back without any custom retry logic.
  };
  const c = new LanguageClient("bit", "Bit Language Server", serverOptions, clientOptions);
  c.start();
  return c;
}

/** Runs `bit fmt <file>` on disk, then lets VS Code's file watcher pick up the rewrite. */
function formatOnSave(bitPath: string, doc: vscode.TextDocument): void {
  if (doc.languageId !== "bit") return;
  if (!vscode.workspace.getConfiguration("bit").get<boolean>("formatOnSave", true)) return;

  execFile(bitPath, ["fmt", doc.uri.fsPath], (err: Error | null, _stdout: string, stderr: string) => {
    if (err) output?.appendLine(`bit fmt failed for ${doc.uri.fsPath}: ${stderr || err.message}`);
  });
}

export function activate(context: vscode.ExtensionContext): void {
  output = vscode.window.createOutputChannel("Bit Language Server", { log: true });
  context.subscriptions.push(output);

  const bitPath = resolveBitPath();
  if (!bitPath) {
    vscode.window.showErrorMessage(
      'Bit: could not find "bit" on PATH. Install it or set "bit.serverPath".',
    );
    return;
  }

  client = startClient(bitPath);
  context.subscriptions.push({ dispose: () => void client?.stop() });

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => formatOnSave(bitPath, doc)),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("bit.restartServer", async () => {
      if (!client) return;
      await client.stop();
      client = startClient(bitPath);
    }),
  );
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}
