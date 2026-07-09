import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(_context: vscode.ExtensionContext): void {
  const command = vscode.workspace.getConfiguration("lingua").get<string>("path", "lingua");
  const serverOptions: ServerOptions = { command, args: ["lsp"] };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { language: "markdown" },
      { language: "plaintext" },
      { language: "git-commit" },
    ],
  };
  client = new LanguageClient("lingua", "lingua", serverOptions, clientOptions);
  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
