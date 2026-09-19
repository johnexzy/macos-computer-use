import { z } from "zod";
import {
  READ_ONLY_ANNOTATIONS,
  RESULT_CONTRACT_VERSION,
  UNSAFE_MODE,
} from "../core/config.js";
import { NativeBridge } from "../core/native-bridge.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const getCapabilitiesSchema = z.object({});

export const getCapabilitiesTool: ToolDefinition<Record<string, never>> = {
  name: "get_capabilities",
  description:
    "Inspect macOS permission readiness and the active safety policy without requesting any permission.",
  annotations: READ_ONLY_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {},
  },
  schema: getCapabilitiesSchema,
  execute: async () => {
    const capabilities = await NativeBridge.getCapabilities();
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ...capabilities,
              policy: {
                unsafeMode: UNSAFE_MODE,
                globalInputEnabled: UNSAFE_MODE,
                appleScriptEnabled: UNSAFE_MODE,
                foregroundActivationEnabled: UNSAFE_MODE,
              },
              resultContractVersion: RESULT_CONTRACT_VERSION,
            },
            null,
            2
          ),
        },
      ],
    };
  },
};
