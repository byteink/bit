import * as path from "path";
import * as fs from "fs";
import { execFile } from "child_process";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

const BINARY_NAME = process.platform === "win32" ? "bitc.exe" : "bitc";

let client: LanguageClient | undefined;
let output: vscode.LogOutputChannel | undefined;

/**
 * Resolves the bitc binary: an explicit `bit.serverPath` setting wins,
 * otherwise every directory on PATH is checked in order (PATH is a finite,
 * user-controlled list, so this loop is statically bounded). Returns
 * undefined — never throws — so activate() can surface one clear error
 * instead of an unhandled rejection.
 */
function resolveBitcPath(): string | undefined {
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

function startClient(bitcPath: string): LanguageClient {
  const serverOptions: ServerOptions = {
    command: bitcPath,
    args: ["lsp"],
    transport: TransportKind.stdio,
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "bit" }],
    outputChannel: output,
    // vscode-languageclient's DefaultErrorHandler already restarts the
    // server on an unexpected exit (up to 5 times within 3 minutes), so a
    // crashed `bitc lsp` process comes back without any custom retry logic.
  };
  const c = new LanguageClient("bit", "Bit Language Server", serverOptions, clientOptions);
  c.start();
  return c;
}

/** Runs `bitc fmt <file>` on disk, then lets VS Code's file watcher pick up the rewrite. */
function formatOnSave(bitcPath: string, doc: vscode.TextDocument): void {
  if (doc.languageId !== "bit") return;
  if (!vscode.workspace.getConfiguration("bit").get<boolean>("formatOnSave", true)) return;

  execFile(bitcPath, ["fmt", doc.uri.fsPath], (err: Error | null, _stdout: string, stderr: string) => {
    if (err) output?.appendLine(`bitc fmt failed for ${doc.uri.fsPath}: ${stderr || err.message}`);
  });
}

export function activate(context: vscode.ExtensionContext): void {
  output = vscode.window.createOutputChannel("Bit Language Server", { log: true });
  context.subscriptions.push(output);

  const bitcPath = resolveBitcPath();
  if (!bitcPath) {
    vscode.window.showErrorMessage(
      'Bit: could not find "bitc" on PATH. Install it or set "bit.serverPath".',
    );
    return;
  }

  client = startClient(bitcPath);
  context.subscriptions.push({ dispose: () => void client?.stop() });

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => formatOnSave(bitcPath, doc)),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("bit.restartServer", async () => {
      if (!client) return;
      await client.stop();
      client = startClient(bitcPath);
    }),
  );
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}
