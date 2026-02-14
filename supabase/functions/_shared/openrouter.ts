/// OpenRouter Provisioning API helpers
/// Docs: https://openrouter.ai/docs/api-reference/keys

const OPENROUTER_BASE = "https://openrouter.ai/api/v1/keys";

interface CreateKeyOptions {
  name: string;
  limit: number; // USD spending limit
  limitReset?: "daily" | "weekly" | "monthly";
}

interface OpenRouterKeyResponse {
  key: string; // Full API key (shown only once)
  data: {
    hash: string;
    name: string;
    label: string;
    limit: number | null;
    limit_reset: string | null;
    disabled: boolean;
    usage: number;
    created_at: string;
  };
}

interface OpenRouterKeyInfo {
  hash: string;
  name: string;
  limit: number | null;
  limit_reset: string | null;
  disabled: boolean;
  usage: number;
  usage_daily: number;
  usage_weekly: number;
  usage_monthly: number;
}

function getManagementKey(): string {
  const key = Deno.env.get("OPENROUTER_MANAGEMENT_KEY");
  if (!key) throw new Error("OPENROUTER_MANAGEMENT_KEY not set");
  return key;
}

/// Create a new OpenRouter API key with spending limit
export async function createKey(
  opts: CreateKeyOptions,
): Promise<OpenRouterKeyResponse> {
  const res = await fetch(OPENROUTER_BASE, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${getManagementKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: opts.name,
      limit: opts.limit,
      limit_reset: opts.limitReset ?? "monthly",
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenRouter createKey failed (${res.status}): ${text}`);
  }

  return await res.json();
}

/// Get key info by hash
export async function getKeyInfo(
  hash: string,
): Promise<OpenRouterKeyInfo> {
  const res = await fetch(`${OPENROUTER_BASE}/${hash}`, {
    headers: { Authorization: `Bearer ${getManagementKey()}` },
  });

  if (!res.ok) {
    throw new Error(`OpenRouter getKey failed (${res.status})`);
  }

  const data = await res.json();
  return data.data;
}

/// Update key (e.g. disable, change limit)
export async function updateKey(
  hash: string,
  updates: { disabled?: boolean; limit?: number; name?: string },
): Promise<void> {
  const res = await fetch(`${OPENROUTER_BASE}/${hash}`, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${getManagementKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(updates),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenRouter updateKey failed (${res.status}): ${text}`);
  }
}

/// Delete key
export async function deleteKey(hash: string): Promise<void> {
  const res = await fetch(`${OPENROUTER_BASE}/${hash}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${getManagementKey()}` },
  });

  if (!res.ok) {
    throw new Error(`OpenRouter deleteKey failed (${res.status})`);
  }
}
