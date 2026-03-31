#!/usr/bin/env bun
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "child_process";
import { writeFile } from "fs/promises";
import { resolve } from "path";

const KUBECONFIG = "/home/andrew/admin.conf";
const CONTROLLER_NAME = "sealed-secrets-controller";
const CONTROLLER_NAMESPACE = "kube-system";

const server = new Server(
  { name: "kubeseal-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "seal_secret",
      description:
        "Seal a Kubernetes secret using kubeseal. Accepts plaintext key-value pairs, seals them, and returns the SealedSecret YAML. Optionally writes to a file path.",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", description: "Secret name" },
          namespace: { type: "string", description: "Kubernetes namespace" },
          literals: {
            type: "object",
            description: "Key-value pairs to seal (plaintext values)",
            additionalProperties: { type: "string" },
          },
          outputPath: {
            type: "string",
            description:
              "Optional file path to write the sealed YAML (absolute, or relative to cwd)",
          },
        },
        required: ["name", "namespace", "literals"],
      },
    },
    {
      name: "list_sealed_secrets",
      description: "List SealedSecret resources in the cluster",
      inputSchema: {
        type: "object",
        properties: {
          namespace: {
            type: "string",
            description: "Namespace to filter by (omit for all namespaces)",
          },
        },
      },
    },
  ],
}));

function runCommand(
  cmd: string,
  args: string[],
  stdinData?: string
): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, {
      shell: false,
      env: { ...process.env, KUBECONFIG },
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));

    proc.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`${cmd} exited ${code}: ${stderr.trim()}`));
      } else {
        resolve(stdout);
      }
    });

    proc.on("error", (err) => reject(err));

    if (stdinData !== undefined) {
      proc.stdin.write(stdinData);
      proc.stdin.end();
    }
  });
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "seal_secret") {
    const {
      name: secretName,
      namespace,
      literals,
      outputPath,
    } = args as {
      name: string;
      namespace: string;
      literals: Record<string, string>;
      outputPath?: string;
    };

    // Encode all values as base64 — no shell interpolation ever touches these
    const data: Record<string, string> = {};
    for (const [key, value] of Object.entries(literals)) {
      data[key] = Buffer.from(value).toString("base64");
    }

    const secretManifest = JSON.stringify({
      apiVersion: "v1",
      kind: "Secret",
      metadata: { name: secretName, namespace },
      data,
    });

    const sealedYaml = await runCommand(
      "kubeseal",
      [
        `--controller-name=${CONTROLLER_NAME}`,
        `--controller-namespace=${CONTROLLER_NAMESPACE}`,
        "--format=yaml",
      ],
      secretManifest
    );

    if (outputPath) {
      const absPath = outputPath.startsWith("/")
        ? outputPath
        : resolve(process.cwd(), outputPath);
      await writeFile(absPath, sealedYaml, "utf8");
    }

    return { content: [{ type: "text", text: sealedYaml }] };
  }

  if (name === "list_sealed_secrets") {
    const { namespace } = (args ?? {}) as { namespace?: string };

    const kubectlArgs = namespace
      ? ["get", "sealedsecrets", "-n", namespace, "-o", "wide"]
      : ["get", "sealedsecrets", "--all-namespaces", "-o", "wide"];

    const output = await runCommand("kubectl", kubectlArgs);

    return { content: [{ type: "text", text: output }] };
  }

  throw new Error(`Unknown tool: ${name}`);
});

const transport = new StdioServerTransport();
await server.connect(transport);
